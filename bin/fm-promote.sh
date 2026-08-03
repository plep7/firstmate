#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Promotion into a PR-producing mode (no-mistakes, direct-PR) reconciles this
# task's brief to its new mode: the scout framing (report deliverable, throwaway
# laboratory), Rule 1's no-push/no-PR authority, and the report.md Definition of
# done are replaced by the same blocks a freshly scaffolded ship brief carries,
# including the generated PR-description contract ahead of the mode's terminal
# `done:` gate. A promoted brief therefore reads as one ship contract rather than
# a scout charter with ship text stapled onto the end, and the captain's
# PR-description standard holds without the supervisor pasting it into the
# free-text ship instructions.
# bin/fm-ship-contract-lib.sh owns the mode-shaped contract and
# bin/fm-pr-contract-lib.sh the PR-description block; local-only raises no PR and
# a local-only promotion leaves the brief untouched.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-ship-contract-lib.sh
. "$SCRIPT_DIR/fm-ship-contract-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

"$FM_ROOT/bin/fm-guard.sh" || true
ID=${POS[0]}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP="$META.tmp"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$TMP"
mv "$TMP" "$META"

# Rewrite the brief this task already has onto the ship contract its new mode
# defines. The scout framing states the deliverable is a report, Rule 1 forbids
# pushing and opening a PR at all, and the Definition of done terminates on
# writing report.md; left in place, a worker could satisfy every one of them and
# stop without producing the PR this promotion just committed it to. The
# replacement blocks come from bin/fm-ship-contract-lib.sh, so a promoted brief
# and a scaffolded one state the same contract, with the PR-description block
# ordered ahead of the terminal `done:` gate exactly as it is scaffolded.
#
# Rewriting is idempotent by construction: the whole Definition of done is
# regenerated and the scout lines it replaces are matched exactly, so a second
# promotion reproduces the same file rather than layering a second contract onto
# it.
# The blocks are multi-line, which rules out passing them through `awk -v`: BSD
# awk refuses a newline inside a -v value, so the rewrite is done in the shell.
# The Setup framing is matched against bin/fm-ship-contract-lib.sh's copy rather
# than a literal, so the scaffold and this rewrite cannot drift. A brief written
# by an older release still will not match, and that case is reported rather than
# passed off as a full reconciliation: RECONCILE_SETUP_APPLIED tells the caller
# whether the promoted brief actually gained its branch-creation step.
RECONCILE_SETUP_APPLIED=0
reconcile_brief_to_ship_mode() {  # <brief> <mode> <task-id>
  local brief=$1 mode=$2 id=$3 tmp setup rule1 rule2 dod line last=
  local scout_framing scout_lead
  local in_rules=0 rule1_done=0 rule2_done=0 dod_done=0
  RECONCILE_SETUP_APPLIED=0
  tmp="$brief.promote.tmp"
  [ -w "$brief" ] || return 1
  setup=$(fm_promoted_setup_framing "$mode" "$id")
  rule1=$(fm_ship_rule1 "$mode" "$id")
  rule2=$(fm_ship_rule2)
  dod=$(fm_ship_dod "$mode" "$id" "$FM_ROOT" "$FM_HOME")
  scout_framing=$(fm_scout_setup_framing)
  scout_lead=${scout_framing%%$'\n'*}
  {
    while IFS= read -r line || [ -n "$line" ]; do
      if [ -n "$line" ]; then
        if [ "$line" = "$scout_lead" ]; then
          printf '%s\n' "$setup"; last=$setup; RECONCILE_SETUP_APPLIED=1; continue
        fi
        case $'\n'"$scout_framing"$'\n' in
          *$'\n'"$line"$'\n'*) continue ;;
        esac
      fi
      case "$line" in
        '# Rules') in_rules=1 ;;
        '# Definition of done')
          printf '%s\n' "$dod"; dod_done=1; break ;;
      esac
      if [ "$in_rules" -eq 1 ]; then
        case "$line" in
          '1. '*)
            if [ "$rule1_done" -eq 0 ]; then
              printf '%s\n' "$rule1"; rule1_done=1; last=$rule1; continue
            fi ;;
          '2. '*)
            if [ "$rule2_done" -eq 0 ]; then
              printf '%s\n' "$rule2"; rule2_done=1; last=$rule2; continue
            fi ;;
        esac
      fi
      printf '%s\n' "$line"
      last=$line
    done < "$brief"
    if [ "$dod_done" -eq 0 ]; then
      [ -z "$last" ] || printf '\n'
      printf '%s\n' "$dod"
    fi
  } 2>/dev/null > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$brief" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Report whether this brief already ends in the ship contract this promotion
# would write. Only the last `# Definition of done` counts, and only when the
# delivery line opens it and the contract heading sits inside it: reconciliation
# always terminates a brief that way, so free-text quoting the same lines in the
# `# Task` section a supervisor writes cannot pass for a reconciled brief.
brief_states_ship_contract() {  # <brief> <mode>
  awk -v want="Delivery contract: mode=$2" -v heading="$FM_PR_CONTRACT_HEADING" '
    $0 == "# Definition of done" { dod = NR; delivery = 0; contract = 0; next }
    dod && NR == dod + 1 { delivery = ($0 == want) }
    dod && $0 == heading { contract = 1 }
    END { exit((dod && delivery && contract) ? 0 : 1) }
  ' "$1"
}

# The meta rewrite above has already landed, so no failure here may abort the
# run: an unreachable or unwritable brief is reported loudly on both stderr and
# the confirmation line, so a caller reading only stdout still learns the brief
# was not reconciled and the supervisor must restate the contract inline. The
# "next:" template points the worker back at its brief only when a brief is
# actually there to re-read.
BRIEF="$DATA/$ID/brief.md"
CONTRACT_NOTE=
BRIEF_CLAUSE=
if [ -f "$BRIEF" ]; then
  BRIEF_CLAUSE="re-read your brief at $BRIEF; "
fi
NO_CONTRACT_NOTE=" (PR-description contract NOT appended - restate it and the mode=$MODE ship contract inline)"
case "$MODE" in
  no-mistakes|direct-PR)
    if [ ! -f "$BRIEF" ]; then
      CONTRACT_NOTE="$NO_CONTRACT_NOTE"
      echo "warning: no brief at $BRIEF; restate the PR-description contract from $(fm_pr_visual_format_doc "$FM_ROOT" "$FM_HOME") in the ship instructions" >&2
    elif brief_states_ship_contract "$BRIEF" "$MODE"; then
      CONTRACT_NOTE=" (brief already carries the PR-description contract and the mode=$MODE ship contract)"
    elif reconcile_brief_to_ship_mode "$BRIEF" "$MODE" "$ID"; then
      if [ "$RECONCILE_SETUP_APPLIED" -eq 1 ]; then
        CONTRACT_NOTE=" (brief reconciled to the mode=$MODE ship contract; PR-description contract appended to $BRIEF)"
      else
        CONTRACT_NOTE=" (PR-description contract appended to $BRIEF with the mode=$MODE definition of done, but its Setup section matched no scout framing this release knows and still states no branch-creation step)"
        echo "warning: $BRIEF carries no scout setup framing this release recognizes, so its Setup section was left as written and the reconciled brief names no branch step; restate the ship setup in the ship instructions (inventory the scratch state, reset to a clean default-branch base, create branch fm/$ID) and correct the Setup section by hand" >&2
      fi
    else
      CONTRACT_NOTE="$NO_CONTRACT_NOTE"
      echo "warning: could not append the PR-description contract to $BRIEF; restate it from $(fm_pr_visual_format_doc "$FM_ROOT" "$FM_HOME") in the ship instructions, along with the mode=$MODE definition of done - the brief still states a scout contract" >&2
    fi
    ;;
esac

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)$CONTRACT_NOTE"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: ${BRIEF_CLAUSE}review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
