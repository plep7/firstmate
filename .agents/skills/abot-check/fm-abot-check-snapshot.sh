#!/usr/bin/env bash
# fm-abot-check-snapshot.sh - single bounded, deterministic gather for the
# abot-check skill. Talks to the live abot stack over two independent
# channels - plain HTTP to the dashboard API, and SSH to the docker host for
# container health and read-only psql - and prints one line-oriented report.
#
# Each channel degrades independently: an unreachable HTTP endpoint or SSH
# command is recorded as `unreachable: <label>` and the affected section's
# fields read `n/a`, but every other section still gathers normally. Nothing
# here ever restarts, prunes, or mutates the target host; every command is a
# GET, `docker ps`, or a read-only `psql` SELECT.
#
# A source counts as unreachable, never as a clean zero, when: the transport
# fails, the HTTP status is not 2xx, the body is not JSON, a debug surface
# answers `available:false` or a non-null `error`, or a local prerequisite for
# reading it is absent (`missing:jq`, `missing:date-cutoff`). Every such label
# also forces its section's `needs_attention` to true, so a gap is always
# reported as a gap rather than rendering as a quiet section.
#
# Output contract: `fm-abot-check.v1`, plain `key: value` lines grouped under
# `[section]` headers, plus repeated `<label>_line: ...` lines for per-row
# detail (alerts, silent-drop trades). Every section ends with its own
# `needs_attention: true|false`; `[verdict]` closes with the fleet-wide
# `overall_needs_attention` and a `sections_needing_attention` list built from
# those same per-section values. This is the single owner of that logic -
# SKILL.md renders captain-facing prose from these facts and never recomputes a
# verdict of its own.
#
# Container health reads `docker ps -a`, so a stopped or never-started abot-
# container stays visible instead of vanishing from the count. A container is
# unhealthy when it is not in an `Up` state, or when it has a HEALTHCHECK
# reporting anything other than healthy; a running container with no
# HEALTHCHECK configured is counted separately and is not by itself a problem.
#
# Env overrides (all optional):
#   FM_ABOT_HOST              docker/API host                  (default 192.168.1.215)
#   FM_ABOT_API_PORT          dashboard-api port                (default 18030)
#   FM_ABOT_SSH_TIMEOUT       ssh ConnectTimeout, seconds        (default 8)
#   FM_ABOT_CURL_TIMEOUT      curl max-time, seconds             (default 10)
#   FM_ABOT_GRACE_MINUTES     age before a non-terminal trade counts as stuck (default 60)
#   FM_ABOT_ALERT_WINDOW_HOURS ops-alerts/event-stream lookback  (default 24)
#   FM_ABOT_HYGIENE_DAYS      DB-hygiene lookback window          (default 30)
#   FM_ABOT_BASELINE_DAYS     analysis-cadence baseline window    (default 7)
#
# Usage:
#   fm-abot-check-snapshot.sh          gather and print the report
#   fm-abot-check-snapshot.sh -h|--help  usage
set -u

fm_abot_usage() {  # the whole header block, however long it grows
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help)
    fm_abot_usage
    exit 0
    ;;
  '') ;;
  *)
    printf 'fm-abot-check-snapshot.sh: unknown argument: %s\n' "$1" >&2
    fm_abot_usage >&2
    exit 2
    ;;
esac

HOST=${FM_ABOT_HOST:-192.168.1.215}
API_PORT=${FM_ABOT_API_PORT:-18030}
SSH_TIMEOUT=${FM_ABOT_SSH_TIMEOUT:-8}
CURL_TIMEOUT=${FM_ABOT_CURL_TIMEOUT:-10}
GRACE_MINUTES=${FM_ABOT_GRACE_MINUTES:-60}
ALERT_WINDOW_HOURS=${FM_ABOT_ALERT_WINDOW_HOURS:-24}
HYGIENE_DAYS=${FM_ABOT_HYGIENE_DAYS:-30}
BASELINE_DAYS=${FM_ABOT_BASELINE_DAYS:-7}

UNREACHABLE=()

have_jq=1
command -v jq >/dev/null 2>&1 || { have_jq=0; UNREACHABLE+=("missing:jq"); }

curl_get() {  # <path> -> body on stdout; returns 1 on transport, status, or parse failure
  local path=$1 raw body code
  raw=$(curl -sS -m "$CURL_TIMEOUT" -w '\n%{http_code}' \
    "http://$HOST:$API_PORT$path" 2>/dev/null) || return 1
  case "$raw" in *$'\n'*) ;; *) return 1 ;; esac
  code=${raw##*$'\n'}
  body=${raw%$'\n'*}
  case "$code" in 2??) ;; *) return 1 ;; esac
  [ -n "$body" ] || return 1
  if [ "$have_jq" -eq 1 ] && ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "$body"
}

debug_off() {  # <json> -> 0 when the debug surface reported itself unavailable or errored
  [ "$have_jq" -eq 1 ] || return 1
  printf '%s' "$1" \
    | jq -e '(.available == false) or ((.error // null) != null)' >/dev/null 2>&1
}

jqf() {  # <json> <filter> -> value, or "n/a" on any failure
  local json=$1 filter=$2 val
  [ "$have_jq" -eq 1 ] || { printf 'n/a'; return; }
  val=$(printf '%s' "$json" | jq -r "$filter" 2>/dev/null)
  [ -n "$val" ] && [ "$val" != "null" ] || val='n/a'
  printf '%s' "$val"
}

# shellcheck disable=SC2016 # single-quoted on purpose: $POSTGRES_USER/$POSTGRES_DB
# expand inside the container's own shell, not this one.
PSQL_REMOTE='docker exec -i abot-postgres-1 sh -c "psql -X -A -t -F\"|\" -U \$POSTGRES_USER -d \$POSTGRES_DB"'

ssh_run() {  # <remote-command> -> stdout; returns ssh's exit code
  ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" -o ConnectionAttempts=1 \
    "root@$HOST" "$1" 2>/dev/null
}

ssh_psql() {  # SQL on stdin -> pipe-delimited rows; returns ssh's exit code
  ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" -o ConnectionAttempts=1 \
    "root@$HOST" "$PSQL_REMOTE" 2>/dev/null
}

echo 'schema: fm-abot-check.v1'
echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host: $HOST"
echo

# ---- version + container health --------------------------------------------
version_json=$(curl_get /api/v1/version) || { UNREACHABLE+=("http:version"); version_json=''; }
docker_ps=$(ssh_run "docker ps -a --filter 'name=abot-' --format '{{.Names}}\t{{.Status}}'")
docker_ps_rc=$?
[ "$docker_ps_rc" -eq 0 ] || UNREACHABLE+=("ssh:docker_ps")

containers_total=0
containers_healthy=0
containers_no_healthcheck=0
unhealthy_names=()
if [ "$docker_ps_rc" -eq 0 ] && [ -n "$docker_ps" ]; then
  while IFS=$'\t' read -r name status; do
    [ -n "$name" ] || continue
    containers_total=$((containers_total + 1))
    case "$status" in
      Up*"(healthy)"*) containers_healthy=$((containers_healthy + 1)) ;;
      Up*"(unhealthy)"*|Up*"(health:"*) unhealthy_names+=("$name") ;;
      Up*) containers_no_healthcheck=$((containers_no_healthcheck + 1)) ;;
      *) unhealthy_names+=("$name") ;;
    esac
  done <<< "$docker_ps"
fi

echo '[version]'
if [ -n "$version_json" ]; then
  echo "version: $(jqf "$version_json" '.version')"
  echo "sha: $(jqf "$version_json" '.sha')"
  echo "deployed_at: $(jqf "$version_json" '.deployed_at')"
else
  echo 'version: n/a'
  echo 'sha: n/a'
  echo 'deployed_at: n/a'
fi
if [ "$docker_ps_rc" -eq 0 ]; then
  echo "containers_total: $containers_total"
  echo "containers_healthy: $containers_healthy"
  echo "containers_no_healthcheck: $containers_no_healthcheck"
  echo "containers_unhealthy_names: ${unhealthy_names[*]:-}"
else
  echo 'containers_total: n/a'
  echo 'containers_healthy: n/a'
  echo 'containers_no_healthcheck: n/a'
  echo 'containers_unhealthy_names: n/a'
fi
version_attention=false
[ -z "$version_json" ] && version_attention=true
[ "$have_jq" -eq 1 ] || version_attention=true
[ "$docker_ps_rc" -ne 0 ] && version_attention=true
[ "${#unhealthy_names[@]}" -gt 0 ] && version_attention=true
echo "needs_attention: $version_attention"
echo

# ---- P&L --------------------------------------------------------------------
pnl_json=$(curl_get /api/v1/live/pnl) || { UNREACHABLE+=("http:pnl"); pnl_json=''; }
pnl_attention=false
echo '[pnl]'
if [ -n "$pnl_json" ] && [ "$have_jq" -eq 1 ]; then
  echo "realized_today: $(jqf "$pnl_json" '.realized_today')"
  echo "realized_all_time: $(jqf "$pnl_json" '.realized_all_time')"
  echo "unrealized: $(jqf "$pnl_json" '.unrealized')"
  echo "total: $(jqf "$pnl_json" '.total')"
  echo "day_change: $(jqf "$pnl_json" '.day_change')"
else
  pnl_attention=true
  echo 'realized_today: n/a'
  echo 'realized_all_time: n/a'
  echo 'unrealized: n/a'
  echo 'total: n/a'
  echo 'day_change: n/a'
fi
echo "needs_attention: $pnl_attention"
echo

# ---- trade placement audit ---------------------------------------------------
# Silent-drop bug signal: a TRADE/EXIT decision that reached `submitted` with
# no order_intent at all, or has an intent but no terminal order_event
# (FILLED/CANCELLED/REJECTED) after $GRACE_MINUTES. Intentional non-placements
# (skipped_*, shadow PASS/HOLD) are excluded - they are not bugs.
#
# Column order is load-bearing: every fixed-width field, including both
# decisive booleans, is selected before the free-text status_reason, and
# status_reason itself has its own field separator and newlines translated to
# spaces. A broker rejection string can contain either, and without both
# guards one such character would shift every later field left and silently
# reclassify a real drop as clean.
trade_audit=$(ssh_psql <<SQL
WITH trade_decisions AS (
  SELECT ad.ticker, ad.action, ad.status, ad.status_reason, ad.created_at,
    (ad.intent_id IS NOT NULL) AS has_intent,
    (SELECT oe.event_type FROM order_event oe
       WHERE oe.intent_id = ad.intent_id AND oe.event_type IN ('FILLED','CANCELLED','REJECTED')
       ORDER BY oe.as_of_ts DESC LIMIT 1) AS terminal_event
  FROM analyst_decision ad
  WHERE ad.action IN ('TRADE','EXIT')
    AND ad.status NOT LIKE 'skipped_%'
    AND ad.status <> 'shadow'
    AND ad.created_at >= CURRENT_DATE
)
SELECT ticker, action, status, has_intent, coalesce(terminal_event,''),
  (status = 'submitted' AND NOT has_intent) AS drop_no_intent,
  (has_intent AND terminal_event IS NULL AND created_at < now() - interval '$GRACE_MINUTES minutes') AS drop_no_terminal,
  translate(coalesce(status_reason,''), E'|\n\r', '   ')
FROM trade_decisions
ORDER BY created_at DESC;
SQL
)
trade_audit_rc=$?
[ "$trade_audit_rc" -eq 0 ] || UNREACHABLE+=("ssh:trade_audit")

echo '[trades]'
trades_attention=true
if [ "$trade_audit_rc" -eq 0 ]; then
  decisions_checked=0
  silent_drops=0
  if [ -n "$trade_audit" ]; then
    while IFS='|' read -r ticker action status has_intent terminal drop_no_intent drop_no_terminal reason; do
      [ -n "$ticker" ] || continue
      decisions_checked=$((decisions_checked + 1))
      if [ "$drop_no_intent" = t ] || [ "$drop_no_terminal" = t ]; then
        silent_drops=$((silent_drops + 1))
        why="no order_intent recorded (has_intent=$has_intent)"
        [ "$drop_no_terminal" = t ] && why="intent has no terminal broker event after ${GRACE_MINUTES}m (last_event=${terminal:-none})"
        [ -n "$reason" ] && why="$why; status_reason=$reason"
        echo "drop_line: $ticker|$action|$status|$why"
      fi
    done <<< "$trade_audit"
  fi
  echo "decisions_checked: $decisions_checked"
  echo "silent_drops: $silent_drops"
  trades_attention=false
  [ "$silent_drops" -gt 0 ] && trades_attention=true
else
  echo 'decisions_checked: n/a'
  echo 'silent_drops: n/a'
fi
echo "needs_attention: $trades_attention"
echo

# ---- analysis cadence ---------------------------------------------------------
cadence=$(ssh_psql <<SQL
SELECT
  (SELECT count(*) FROM analyst_decision WHERE created_at >= CURRENT_DATE),
  (SELECT round(count(*)::numeric/$BASELINE_DAYS,1) FROM analyst_decision WHERE created_at >= now() - interval '$BASELINE_DAYS days'),
  (SELECT count(*) FROM analyst_decision WHERE action='PASS' AND error IS NOT NULL AND created_at >= CURRENT_DATE),
  (SELECT count(*) FROM analyst_decision WHERE status='pending' AND created_at < now() - interval '15 minutes' AND created_at >= CURRENT_DATE);
SQL
)
cadence_rc=$?
[ "$cadence_rc" -eq 0 ] || UNREACHABLE+=("ssh:cadence")

echo '[analysis]'
analysis_attention=true
if [ "$cadence_rc" -eq 0 ] && [ -n "$cadence" ]; then
  IFS='|' read -r decisions_today decisions_per_day_baseline errored_pass_today stuck_pending <<< "$cadence"
  echo "decisions_today: $decisions_today"
  echo "decisions_per_day_${BASELINE_DAYS}d_baseline: $decisions_per_day_baseline"
  echo "errored_pass_today: $errored_pass_today"
  echo "stuck_pending: $stuck_pending"
  analysis_attention=false
  { [ "${errored_pass_today:-0}" -gt 0 ] || [ "${stuck_pending:-0}" -gt 0 ]; } && analysis_attention=true
else
  echo 'decisions_today: n/a'
  echo "decisions_per_day_${BASELINE_DAYS}d_baseline: n/a"
  echo 'errored_pass_today: n/a'
  echo 'stuck_pending: n/a'
fi
echo "needs_attention: $analysis_attention"
echo

# ---- ops alerts / event stream / diagnoses -------------------------------------
cutoff=$(date -u -v-"${ALERT_WINDOW_HOURS}"H +%Y-%m-%dT%H:%M:%S 2>/dev/null \
  || date -u -d "-${ALERT_WINDOW_HOURS} hours" +%Y-%m-%dT%H:%M:%S 2>/dev/null)
[ -n "$cutoff" ] || UNREACHABLE+=("missing:date-cutoff")

ops_json=$(curl_get /api/v1/debug/ops-alerts) || { UNREACHABLE+=("http:ops-alerts"); ops_json=''; }
event_json=$(curl_get /api/v1/debug/event-stream) || { UNREACHABLE+=("http:event-stream"); event_json=''; }
diag_json=$(curl_get /api/v1/debug/diagnoses) || { UNREACHABLE+=("http:diagnoses"); diag_json=''; }

# A debug surface that answers `available:false` or carries an error is a
# switched-off source, not a quiet one; drop its body so the section reads n/a
# and the label lands in [sources] rather than rendering as zero alerts.
if [ -n "$ops_json" ] && debug_off "$ops_json"; then
  UNREACHABLE+=("debug:ops-alerts"); ops_json=''
fi
if [ -n "$event_json" ] && debug_off "$event_json"; then
  UNREACHABLE+=("debug:event-stream"); event_json=''
fi
if [ -n "$diag_json" ] && debug_off "$diag_json"; then
  UNREACHABLE+=("debug:diagnoses"); diag_json=''
fi

echo '[alerts]'
alert_count=0
recovery_count=0
alerts_readable=0
if [ -n "$ops_json" ] && [ "$have_jq" -eq 1 ] && [ -n "$cutoff" ]; then
  alerts_readable=1
  while IFS=$'\t' read -r severity event_type headline; do
    [ -n "$severity" ] || continue
    if [ "$severity" = alert ]; then
      alert_count=$((alert_count + 1))
      echo "alert_line: $severity|$event_type|$headline"
    fi
    case "$event_type" in
      *RECOVERED*)
        recovery_count=$((recovery_count + 1))
        echo "recovery_line: $event_type|$headline"
        ;;
    esac
  done < <(printf '%s' "$ops_json" | jq -r --arg cutoff "$cutoff" \
    '.rows[]? | select(.created_at >= $cutoff) | [.severity,.event_type,.headline] | @tsv')
  echo "alert_count_${ALERT_WINDOW_HOURS}h: $alert_count"
  echo "recovery_count_${ALERT_WINDOW_HOURS}h: $recovery_count"
else
  echo "alert_count_${ALERT_WINDOW_HOURS}h: n/a"
  echo "recovery_count_${ALERT_WINDOW_HOURS}h: n/a"
fi
if [ -n "$event_json" ] && [ "$have_jq" -eq 1 ]; then
  echo "event_stream_head_count: $(jqf "$event_json" '.rows | length')"
else
  echo 'event_stream_head_count: n/a'
fi
if [ -n "$diag_json" ] && [ "$have_jq" -eq 1 ]; then
  echo "diagnoses_count: $(jqf "$diag_json" '.rows | length')"
else
  echo 'diagnoses_count: n/a'
fi
alerts_attention=false
[ "$alerts_readable" -eq 1 ] || alerts_attention=true
if [ -z "$event_json" ] || [ -z "$diag_json" ] || [ "$have_jq" -ne 1 ]; then
  alerts_attention=true
fi
[ "$alert_count" -gt 0 ] && alerts_attention=true
echo "needs_attention: $alerts_attention"
echo

# ---- DB hygiene -----------------------------------------------------------------
# "Orphaned" here means the genuine lineage break the v28 forensics fix
# defined: a TRADE/EXIT decision that reached `submitted` with no matching
# order_intent, or `submitted` with an intent that never reached a terminal
# broker event. A decision with intent_id NULL for any other status (skipped,
# shadow) is expected and excluded - it is raw pipeline noise, not a defect.
hygiene=$(ssh_psql <<SQL
SELECT
  (SELECT count(*) FROM analyst_decision WHERE action IN ('TRADE','EXIT') AND status='submitted' AND intent_id IS NULL AND created_at >= now() - interval '$HYGIENE_DAYS days'),
  (SELECT count(*) FROM analyst_decision ad WHERE ad.action IN ('TRADE','EXIT') AND ad.status='submitted' AND ad.intent_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM order_event oe WHERE oe.intent_id=ad.intent_id AND oe.event_type IN ('FILLED','CANCELLED','REJECTED'))
     AND ad.created_at < now() - interval '$GRACE_MINUTES minutes' AND ad.created_at >= now() - interval '$HYGIENE_DAYS days'),
  (SELECT count(*) FROM (
      SELECT tl.lot_id FROM tax_lot tl LEFT JOIN tax_lot_close tc ON tc.lot_id=tl.lot_id
      GROUP BY tl.lot_id, tl.qty HAVING COALESCE(SUM(tc.qty_closed),0) > tl.qty
   ) over_closed),
  (SELECT count(*) FROM tax_lot_close tc WHERE NOT EXISTS (SELECT 1 FROM order_event oe WHERE oe.intent_id=tc.close_intent_id AND oe.event_type='FILLED'));
SQL
)
hygiene_rc=$?
[ "$hygiene_rc" -eq 0 ] || UNREACHABLE+=("ssh:hygiene")

echo '[hygiene]'
hygiene_attention=true
if [ "$hygiene_rc" -eq 0 ] && [ -n "$hygiene" ]; then
  IFS='|' read -r orphan_no_intent orphan_stuck over_closed_lots close_without_fill <<< "$hygiene"
  echo "orphan_no_intent_${HYGIENE_DAYS}d: $orphan_no_intent"
  echo "orphan_stuck_${HYGIENE_DAYS}d: $orphan_stuck"
  echo "over_closed_lots: $over_closed_lots"
  echo "close_without_fill: $close_without_fill"
  hygiene_attention=false
  { [ "${orphan_no_intent:-0}" -gt 0 ] || [ "${orphan_stuck:-0}" -gt 0 ] \
    || [ "${over_closed_lots:-0}" -gt 0 ] || [ "${close_without_fill:-0}" -gt 0 ]; } && hygiene_attention=true
else
  echo "orphan_no_intent_${HYGIENE_DAYS}d: n/a"
  echo "orphan_stuck_${HYGIENE_DAYS}d: n/a"
  echo 'over_closed_lots: n/a'
  echo 'close_without_fill: n/a'
fi
echo "needs_attention: $hygiene_attention"
echo

# ---- verdict ----------------------------------------------------------------
# Each section already decided and printed its own needs_attention above; the
# rollup only reads those variables, so a threshold can never be expressed
# twice and drift between a section line and this list.
sections_attention=()
[ "$version_attention" = true ] && sections_attention+=(version)
[ "$pnl_attention" = true ] && sections_attention+=(pnl)
[ "$trades_attention" = true ] && sections_attention+=(trades)
[ "$analysis_attention" = true ] && sections_attention+=(analysis)
[ "$alerts_attention" = true ] && sections_attention+=(alerts)
[ "$hygiene_attention" = true ] && sections_attention+=(hygiene)

overall_attention=false
[ "${#sections_attention[@]}" -gt 0 ] && overall_attention=true

echo '[sources]'
echo "unreachable: ${UNREACHABLE[*]:-none}"
echo

echo '[verdict]'
echo "sections_needing_attention: ${sections_attention[*]:-none}"
echo "overall_needs_attention: $overall_attention"
