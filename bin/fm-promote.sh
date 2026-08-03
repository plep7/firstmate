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
# Promotion into a PR-producing mode (no-mistakes, direct-PR) appends the same
# generated PR-description contract a fresh ship brief carries to this task's
# brief, so a promoted scout's PR is held to the captain's standard without the
# supervisor pasting it into the free-text ship instructions.
# bin/fm-pr-contract-lib.sh owns that text; local-only raises no PR and is unaffected.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-contract-lib.sh
. "$SCRIPT_DIR/fm-pr-contract-lib.sh"
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

# A promoted PR-producing task must carry the same PR-description contract a
# fresh ship brief is scaffolded with. Appending it to the brief keeps the
# obligation durable and structural; the contract is an H2, so it nests under
# the brief's final `# Definition of done` section. Idempotent by section
# heading.
# The meta rewrite above has already landed, so no failure here may abort the
# run: an unreachable or unwritable brief is reported loudly and the supervisor
# is told to restate the contract inline, while the promotion still confirms
# itself. The "next:" template points the worker back at its brief only when a
# brief is actually there to re-read.
BRIEF="$DATA/$ID/brief.md"
CONTRACT_NOTE=
BRIEF_CLAUSE=
if [ -f "$BRIEF" ]; then
  BRIEF_CLAUSE="re-read your brief at $BRIEF; "
fi
case "$MODE" in
  no-mistakes|direct-PR)
    if [ ! -f "$BRIEF" ]; then
      echo "warning: no brief at $BRIEF; restate the PR-description contract from $(fm_pr_visual_format_doc "$FM_ROOT" "$FM_HOME") in the ship instructions" >&2
    elif grep -qx '## PR-description contract' "$BRIEF"; then
      CONTRACT_NOTE=" (brief already carries the PR-description contract)"
    elif printf '\n%s\n' "$(fm_pr_description_contract "$FM_ROOT" "$FM_HOME")" 2>/dev/null >> "$BRIEF"; then
      CONTRACT_NOTE=" (PR-description contract appended to $BRIEF)"
    else
      echo "warning: could not append the PR-description contract to $BRIEF; restate it from $(fm_pr_visual_format_doc "$FM_ROOT" "$FM_HOME") in the ship instructions" >&2
    fi
    ;;
esac

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)$CONTRACT_NOTE"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: ${BRIEF_CLAUSE}review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
