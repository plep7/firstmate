# shellcheck shell=bash
# Overlay for bin/fm-brief.sh: a tracked, code-root-sourced file (loaded from
# $FM_ROOT, not a per-home config dir) that ships with the code, so it is
# present wherever bin/fm-brief.sh runs - every home, CI, and every test that
# runs the real script from the worktree. Sourced only when present, at the
# case/esac boundary right after the mode-specific DOD text is assembled.
# `config/overlay/` is a path the upstream repo does not have, so this file is
# purely additive and never conflicts on rebase - the same reason
# bin/nm-pr-format never conflicts. See
# data/fm-fork-extension-design/report.md section 3 for the design and
# section 4 for the migration this file is step 2 of.
#
# fm_overlay_brief_dod <mode> <dod> prints the final DOD text on stdout. For
# the no-mistakes mode it layers the born-formatted PR flow (drive the gate
# with --skip push,pr,ci, then compose and open the PR itself) and the
# pre-gate visual-evidence trigger onto upstream's plain DOD text by anchored
# substitution, so upstream wording it doesn't touch keeps flowing through
# unmodified. Every other mode (direct-PR, local-only) passes its DOD through
# unchanged - the born-formatted flow is no-mistakes-specific.
fm_overlay_brief_dod() {  # <mode> <dod>
  local mode=$1 dod=$2
  case "$mode" in
    no-mistakes) fm_overlay_brief_dod_no_mistakes "$dod" ;;
    *) printf '%s' "$dod" ;;
  esac
}

# An anchor substitution that finds nothing means upstream's DOD text no
# longer reads the way this overlay expects (upstream reworded the paragraph
# this hooks into). Fail loudly rather than silently ship a brief missing the
# born-formatted flow - the mismatch needs a human to reconcile this file.
fm_overlay_brief_dod_apply() {  # <dod-var-name> <anchor> <replacement>
  local dod_var=$1 anchor=$2 replacement=$3 before after
  before=${!dod_var}
  after=${before/"$anchor"/$replacement}
  if [ "$after" = "$before" ]; then
    echo "error: fm_overlay_brief_dod: anchor no longer found in upstream DOD text; update config/overlay/fm-brief-dod.sh. Anchor was: $anchor" >&2
    exit 1
  fi
  printf -v "$dod_var" '%s' "$after"
}

fm_overlay_brief_dod_no_mistakes() {  # <dod>
  local dod=$1 pr_visual_format visual_paragraph tail_replacement

  pr_visual_format=$(shell_quote "$FM_HOME/config/pr-visual-format.md")

  visual_paragraph="The task is complete only when committed on your branch.

Before you ever invoke \`no-mistakes axi run\`, check whether the fleet visual-evidence config exists at $pr_visual_format.
If it exists, read it, classify your own diff as backend, frontend, or bug-fix per the heuristics in that file, then generate the type-appropriate visual evidence: a mermaid diagram drafted as text for backend, screenshot(s) or a GIF captured and committed to the branch for frontend, or a before/after pair of whichever evidence type fits for a bug fix.
Commit that evidence as part of your normal implementation commits, before calling \`no-mistakes axi run\`, so it rides through validation and review with the rest of the change.
If that file does not exist in this home, skip this step silently and continue as before; this fleet is not yet configured for it.

When you believe it is complete"
  fm_overlay_brief_dod_apply dod \
    "The task is complete only when committed on your branch.
When you believe it is complete" \
    "$visual_paragraph"

  fm_overlay_brief_dod_apply dod \
    "Two firstmate-specific rules layer on top of that guidance:" \
    "Two firstmate-specific rules layer on top of that guidance, in either flow below:"

  tail_replacement="## Born-formatted PR flow (default)
Take this flow when the fleet visual-evidence config exists at $pr_visual_format and \`no-mistakes axi run --help\` on the installed gate lists a \`--skip\` flag covering the \`push\`, \`pr\`, and \`ci\` steps.

1. Invoke the gate with those three steps skipped, so it runs the full quality pipeline (review, test, document, lint) and stops before pushing anything: \`no-mistakes axi run --intent \"<one-line intent>\" --skip push,pr,ci\`.
2. Once that run passes, compose the PR body yourself using the fleet config rules: the voice rules it specifies, a \`## Summary\`, a \`## Changes\` section with file:line anchors for every change, a type-appropriate \`## Evidence\` or \`## Before/After\` section built from the evidence you committed pre-gate, and a \`## Testing\` section distilled from the review and test evidence the run produced.
3. Push your branch to \`origin\` and open the PR yourself with \`gh-axi\` as a **draft**, titled with the Jira key firstmate gave you in the Task section above, using the body from step 2.
4. Watch the checks on that PR with \`gh-axi\` until they settle.

## Full-pipeline flow (fallback)
Fall back to this flow verbatim, and do not attempt the flow above, when the fleet visual-evidence config is absent from this home, or \`no-mistakes axi run --help\` on the installed gate does not list a \`--skip\` flag covering \`push\`, \`pr\`, and \`ci\` (an older gate version).

Invoke \`no-mistakes axi run\` for the full pipeline; it pushes and opens the PR itself.
Once the gate reaches checks-passed, reformat the PR it opened into the shared PR template with \`bin/nm-pr-format <pr#> --summary \"<why>\" --repo <owner/name> --apply\` (omit \`--apply\` first to preview), as documented at the top of that script.

After either flow reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished."
  fm_overlay_brief_dod_apply dod \
    "After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished." \
    "$tail_replacement"

  printf '%s' "$dod"
}
