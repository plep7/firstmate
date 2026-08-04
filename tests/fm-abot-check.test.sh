#!/usr/bin/env bash
# Behavior tests for the abot-check gather script's parsing and verdict logic.
# Every case runs the real script against fake ssh/curl on PATH - fixture JSON
# and pipe-delimited psql rows in, the script's own labeled output out - so no
# test depends on the live host. Covers: a fully healthy run, a silent-drop
# trade flagged as the bug signal, a DB-hygiene inconsistency flagged, and a
# fully unreachable host degrading to a labeled partial report instead of a
# crash.
#
# The degradation cases are the point of this file: a non-2xx HTTP status, a
# debug surface answering `available:false`, and a stopped container each have
# to render as a labeled gap that flags its section, never as a clean zero.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/.agents/skills/abot-check/fm-abot-check-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-abot-check)

VERSION_JSON='{"version":28,"sha":"9b97ed7","deployed_at":"2026-08-04T14:55:36Z"}'
PNL_JSON='{"realized_today":-211.41,"realized_all_time":-855.96,"unrealized":124.09,"total":-87.33,"day_change":-12.82}'
DOCKER_PS_HEALTHY=$'abot-postgres-1\tUp 3 hours (healthy)\nabot-executor-1\tUp 3 hours (healthy)'
DOCKER_PS_UNHEALTHY=$'abot-postgres-1\tUp 3 hours (healthy)\nabot-executor-1\tRestarting (1) 4 seconds ago'
DOCKER_PS_EXITED=$'abot-postgres-1\tUp 3 hours (healthy)\nabot-executor-1\tExited (137) 2 hours ago'
DOCKER_PS_NO_HEALTHCHECK=$'abot-postgres-1\tUp 3 hours (healthy)\nabot-web-1\tUp 3 hours'

# make_fakebin <dir> <ops_alerts_json> <docker_ps_output> <trade_audit_rows> <cadence_row> <hygiene_row>
# Each ssh psql call is tagged by its first SQL line (SC-2016-quoted markers in
# the real script's heredocs), so the fake ssh reads stdin once and switches on
# whichever table name appears first to decide which fixture row(s) to print.
# The fake curl reproduces the real `-w '\n%{http_code}'` contract: body, then a
# newline, then the status code, so status handling is exercised for real.
make_fakebin() {
  local dir=$1 fb ops_json=$2 docker_ps=$3 trade_rows=$4 cadence_row=$5 hygiene_row=$6
  fb=$(fm_fakebin "$dir")

  cat > "$fb/curl" <<CURL
#!/usr/bin/env bash
url="\${!#}"
code=200
case "\$url" in
  *fail-http*) exit 1 ;;
  *live/pnl*) body='$PNL_JSON' ;;
  *debug/ops-alerts*) body='$ops_json' ;;
  *debug/event-stream*) body='{"available":true,"rows":[{"a":1}]}' ;;
  *debug/diagnoses*) body='{"available":true,"rows":[],"error":null}' ;;
  *version*)
    code=\${FM_TEST_VERSION_HTTP_CODE:-200}
    if [ "\$code" = 200 ]; then
      body='$VERSION_JSON'
    else
      body='{"detail":"Not Found"}'
    fi
    ;;
  *) exit 1 ;;
esac
printf '%s\n%s' "\$body" "\$code"
CURL
  chmod +x "$fb/curl"

  cat > "$fb/ssh" <<SSH
#!/usr/bin/env bash
[ "\${FM_TEST_SSH_FAIL:-0}" = 1 ] && exit 255
case "\$*" in
  *"docker ps"*)
    printf '%s\n' "$docker_ps"
    exit 0
    ;;
esac
sql=\$(cat)
case "\$sql" in
  *"FROM trade_decisions"*)
    printf '%s\n' "$trade_rows"
    ;;
  *"round(count(*)"*)
    printf '%s\n' "$cadence_row"
    ;;
  *"tax_lot_close"*)
    printf '%s\n' "$hygiene_row"
    ;;
  *)
    exit 1
    ;;
esac
SSH
  chmod +x "$fb/ssh"

  printf '%s\n' "$fb"
}

run_snapshot() {  # <fakebin-dir> [env assignments...]
  local fb=$1
  shift
  env "$@" PATH="$fb:$PATH" FM_ABOT_SSH_TIMEOUT=2 FM_ABOT_CURL_TIMEOUT=2 "$SCRIPT"
}

# --- healthy end-to-end run --------------------------------------------------
healthy_ops='{"available":true,"rows":[]}'
fb1=$(make_fakebin "$TMP_ROOT/healthy" "$healthy_ops" "$DOCKER_PS_HEALTHY" '' '21|38.9|0|0' '0|0|0|0')
out1=$(run_snapshot "$fb1")
expect_code 0 "$?" "healthy run exits 0"
assert_contains "$out1" 'schema: fm-abot-check.v1' "prints the output-contract header"
assert_contains "$out1" 'containers_healthy: 2' "counts healthy containers from docker ps"
assert_contains "$out1" 'realized_today: -211.41' "P&L keeps the realized_today scope label"
assert_contains "$out1" 'silent_drops: 0' "trade audit finds zero drops on clean fixture rows"
assert_contains "$out1" 'unreachable: none' "a fully healthy run names no unreachable source"
assert_contains "$out1" 'sections_needing_attention: none' "verdict is clean end to end"
assert_contains "$out1" 'overall_needs_attention: false' "overall verdict is clean end to end"
pass "fully healthy fixture run renders a clean six-section report"

# --- silent-drop trade is the flagged bug signal -----------------------------
drop_rows='AAPL|TRADE|submitted|f||t|f|'
fb2=$(make_fakebin "$TMP_ROOT/drop" "$healthy_ops" "$DOCKER_PS_HEALTHY" "$drop_rows" '21|38.9|0|0' '0|0|0|0')
out2=$(run_snapshot "$fb2")
assert_contains "$out2" 'silent_drops: 1' "a submitted decision with no intent counts as one silent drop"
assert_contains "$out2" 'drop_line: AAPL|TRADE|submitted|no order_intent recorded' "the drop line names the ticker and the no-intent reason"
assert_contains "$out2" 'decisions_checked: 1' "trades section counts the one decision it checked"
assert_contains "$out2" 'sections_needing_attention: trades' "verdict surfaces trades as the section needing attention"
pass "a decision with no order_intent is counted and named as a silent drop"

# --- a decision with an intent but no terminal event is also a drop ---------
stuck_rows='MSFT|EXIT|submitted|t|SENT|f|t|'
fb3=$(make_fakebin "$TMP_ROOT/stuck" "$healthy_ops" "$DOCKER_PS_HEALTHY" "$stuck_rows" '21|38.9|0|0' '0|0|0|0')
out3=$(run_snapshot "$fb3")
assert_contains "$out3" 'silent_drops: 1' "an intent stuck past the grace window also counts as a silent drop"
assert_contains "$out3" 'intent has no terminal broker event after' "the drop line explains the stuck-intent reason, not the no-intent reason"
pass "an intent with no terminal broker event after the grace window is flagged distinctly"

# --- a separator inside the free-text reason cannot hide a drop --------------
# Every fixed-width field, including both decisive booleans, precedes the
# free-text reason, so a broker string carrying the field separator can only
# widen the trailing reason - it can never shift a boolean out of position and
# reclassify a real drop as clean.
piped_rows='NVDA|TRADE|submitted|t||f|t|rejected: qty|price mismatch'
fb4=$(make_fakebin "$TMP_ROOT/piped" "$healthy_ops" "$DOCKER_PS_HEALTHY" "$piped_rows" '21|38.9|0|0' '0|0|0|0')
out4=$(run_snapshot "$fb4")
assert_contains "$out4" 'silent_drops: 1' "a reason containing the field separator still counts its drop"
assert_contains "$out4" 'intent has no terminal broker event after' "the stuck-intent classification survives a separator in the reason"
assert_contains "$out4" 'status_reason=rejected: qty|price mismatch' "the full reason text is carried through, separator included"
pass "a field separator inside status_reason cannot silently reclassify a drop as clean"

# --- DB hygiene inconsistency is flagged -------------------------------------
fb5=$(make_fakebin "$TMP_ROOT/hygiene" "$healthy_ops" "$DOCKER_PS_HEALTHY" '' '21|38.9|0|0' '0|1|0|0')
out5=$(run_snapshot "$fb5")
assert_contains "$out5" 'orphan_stuck_30d: 1' "hygiene surfaces the orphaned-intent count"
assert_contains "$out5" '[hygiene]
orphan_no_intent_30d: 0
orphan_stuck_30d: 1
over_closed_lots: 0
close_without_fill: 0
needs_attention: true' "hygiene section flags needs_attention when any count is nonzero"
assert_contains "$out5" 'sections_needing_attention: hygiene' "verdict surfaces hygiene as the section needing attention"
pass "a nonzero DB hygiene count is flagged in both its section and the verdict"

# --- alert-severity ops events are flagged, recoveries noted separately -----
alert_ops='{"available":true,"rows":[{"created_at":"2026-08-04T12:00:00+00:00","severity":"alert","event_type":"RESEARCH_HOST_HALTED","headline":"halted"},{"created_at":"2026-08-04T12:05:00+00:00","severity":"info","event_type":"SOURCE_HEALTH_RECOVERED","headline":"recovered"}]}'
fb6=$(make_fakebin "$TMP_ROOT/alerts" "$alert_ops" "$DOCKER_PS_HEALTHY" '' '21|38.9|0|0' '0|0|0|0')
out6=$(run_snapshot "$fb6" FM_ABOT_ALERT_WINDOW_HOURS=8760)
assert_contains "$out6" 'alert_line: alert|RESEARCH_HOST_HALTED|halted' "an alert-severity row is emitted as an alert_line"
assert_contains "$out6" 'recovery_line: SOURCE_HEALTH_RECOVERED|recovered' "a RECOVERED row is noted separately as a recovery_line"
assert_contains "$out6" 'alert_count_8760h: 1' "the alert count matches only the alert-severity row"
assert_contains "$out6" 'recovery_count_8760h: 1' "the recovery count matches only the RECOVERED row"
assert_contains "$out6" 'sections_needing_attention: alerts' "an alert-severity row flags the alerts section"
pass "alert-severity ops events and recoveries are classified and counted separately"

# --- a switched-off debug surface is a gap, never a quiet zero ---------------
off_ops='{"available":false,"rows":[]}'
fb7=$(make_fakebin "$TMP_ROOT/debug-off" "$off_ops" "$DOCKER_PS_HEALTHY" '' '21|38.9|0|0' '0|0|0|0')
out7=$(run_snapshot "$fb7")
assert_contains "$out7" 'alert_count_24h: n/a' "an unavailable alert surface reads n/a, not a zero alert count"
assert_contains "$out7" 'unreachable: debug:ops-alerts' "the sources section names the switched-off debug surface"
assert_contains "$out7" 'sections_needing_attention: alerts' "a switched-off alert surface flags the alerts section"
assert_not_contains "$out7" 'alert_count_24h: 0' "a switched-off surface never renders as zero alerts"
pass "a debug surface reporting available:false is labeled unreachable instead of reading clean"

# --- a non-2xx HTTP status is a gap, never a successful fetch ----------------
fb8=$(make_fakebin "$TMP_ROOT/http-500" "$healthy_ops" "$DOCKER_PS_HEALTHY" '' '21|38.9|0|0' '0|0|0|0')
out8=$(run_snapshot "$fb8" FM_TEST_VERSION_HTTP_CODE=500)
assert_contains "$out8" 'unreachable: http:version' "a 500 with a JSON error body is recorded as an unreachable source"
assert_contains "$out8" 'version: n/a' "a non-2xx response degrades the version field to n/a"
assert_contains "$out8" 'sections_needing_attention: version' "a non-2xx response flags its own section"
pass "a non-2xx HTTP response is labeled unreachable rather than read as a successful fetch"

# --- unreachable host degrades to a labeled partial report, never a crash ---
fb9=$(make_fakebin "$TMP_ROOT/unreachable" "$healthy_ops" "$DOCKER_PS_HEALTHY" '' '21|38.9|0|0' '0|0|0|0')
out9=$(run_snapshot "$fb9" FM_TEST_SSH_FAIL=1 FM_ABOT_HOST=fail-http)
code9=$?
expect_code 0 "$code9" "a fully unreachable host still exits 0, never a crash"
assert_contains "$out9" 'version: n/a' "an unreachable http source degrades that field to n/a"
assert_contains "$out9" 'containers_total: n/a' "an unreachable ssh source degrades that field to n/a"
assert_contains "$out9" 'unreachable: http:version ssh:docker_ps' "the sources section names each unreachable channel"
assert_contains "$out9" 'overall_needs_attention: true' "a fully unreachable host reports the overall verdict as needing attention"
assert_not_contains "$out9" 'Traceback' "no crash trace leaks into the report"
pass "an unreachable host produces a labeled partial report instead of failing the whole check"

# --- an unhealthy container is flagged even though the host answered --------
fb10=$(make_fakebin "$TMP_ROOT/unhealthy" "$healthy_ops" "$DOCKER_PS_UNHEALTHY" '' '21|38.9|0|0' '0|0|0|0')
out10=$(run_snapshot "$fb10")
assert_contains "$out10" 'containers_healthy: 1' "only the genuinely healthy container is counted"
assert_contains "$out10" 'containers_unhealthy_names: abot-executor-1' "the unhealthy container is named"
assert_contains "$out10" '[version]
version: 28
sha: 9b97ed7
deployed_at: 2026-08-04T14:55:36Z
containers_total: 2
containers_healthy: 1
containers_no_healthcheck: 0
containers_unhealthy_names: abot-executor-1
needs_attention: true' "version section flags needs_attention on an unhealthy container even though every source answered"
pass "a restarting container is flagged by name even when both channels are reachable"

# --- a stopped container stays visible instead of vanishing from the count ---
fb11=$(make_fakebin "$TMP_ROOT/exited" "$healthy_ops" "$DOCKER_PS_EXITED" '' '21|38.9|0|0' '0|0|0|0')
out11=$(run_snapshot "$fb11")
assert_contains "$out11" 'containers_total: 2' "a stopped container is still counted in the total"
assert_contains "$out11" 'containers_unhealthy_names: abot-executor-1' "a stopped container is named rather than silently missing"
assert_contains "$out11" 'sections_needing_attention: version' "a stopped container flags the version/health section"
pass "a stopped abot container is visible and flagged, not silently absent from the count"

# --- a running container with no HEALTHCHECK is not by itself a problem ------
fb12=$(make_fakebin "$TMP_ROOT/no-healthcheck" "$healthy_ops" "$DOCKER_PS_NO_HEALTHCHECK" '' '21|38.9|0|0' '0|0|0|0')
out12=$(run_snapshot "$fb12")
assert_contains "$out12" 'containers_no_healthcheck: 1' "a running container with no HEALTHCHECK gets its own count"
assert_contains "$out12" 'containers_unhealthy_names: ' "a container with no HEALTHCHECK is not named as unhealthy"
assert_contains "$out12" 'sections_needing_attention: none' "a running container with no HEALTHCHECK does not pin the report to needs_attention"
pass "a running container with no HEALTHCHECK is counted separately, not treated as unhealthy"

# --- --help prints the whole header, and a bad argument is refused -----------
help_out=$("$SCRIPT" --help)
expect_code 0 "$?" "--help exits 0"
assert_contains "$help_out" 'Env overrides' "--help reaches the env-override block"
assert_contains "$help_out" 'fm-abot-check-snapshot.sh -h|--help' "--help reaches the Usage block that owns invocation mechanics"
assert_not_contains "$help_out" 'set -u' "--help stops at the first non-comment line"
bad_out=$("$SCRIPT" --halp 2>&1)
expect_code 2 "$?" "an unknown argument exits 2 instead of silently running a live gather"
assert_contains "$bad_out" 'unknown argument: --halp' "an unknown argument is named in the error"
pass "--help prints the complete header and an unknown argument is refused"
