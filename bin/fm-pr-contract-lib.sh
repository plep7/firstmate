#!/usr/bin/env bash
# Single owner of the generated PR-DESCRIPTION CONTRACT block: the captain's
# PR-description standard, emitted verbatim into every PR-producing task
# contract so it is enforced structurally instead of depending on a supervisor
# restating it.
#
# The block reaches a brief through bin/fm-ship-contract-lib.sh, which splices it
# into the no-mistakes and direct-PR definitions of done. Both entry points get
# it from there, so the wording has exactly one home:
#   bin/fm-brief.sh    scaffolds a ship brief around that definition of done
#   bin/fm-promote.sh  rewrites a scout's brief onto it when promotion moves that
#                      task to a PR-producing mode
# local-only produces no PR and never carries the block.
#
# The block is emitted as an H2 so it nests inside the brief's `# Definition of
# done` section rather than terminating it; the terminal `done:` gate stays part
# of the same section the brief's status protocol points at.
#
# The visual-format doc is named by ABSOLUTE path because a crewmate operates
# from a project worktree and cannot resolve a relative firstmate path. The
# tracked default at <fm-root>/docs/pr-visual-format.md travels with every
# checkout, so the pointer is always reachable; an optional captain-private
# override at ${FM_CONFIG_OVERRIDE:-<fm-home>/config}/pr-visual-format.md wins
# when it exists on disk. Exactly one concrete path is written into the brief,
# resolved at generation time.

# The block's section heading is part of this file's public interface: callers
# locate an already-generated block by it, so re-leveling or renaming the
# section stays a one-file edit here.
FM_PR_CONTRACT_HEADING='## PR-description contract'

# Print the absolute path of the visual-format doc this home should cite.
fm_pr_visual_format_doc() {  # <fm-root> <fm-home>
  local root=$1 home=$2 override
  override="${FM_CONFIG_OVERRIDE:-$home/config}/pr-visual-format.md"
  if [ -f "$override" ]; then
    printf '%s\n' "$override"
  else
    printf '%s\n' "$root/docs/pr-visual-format.md"
  fi
}

# Print the contract block, with no trailing blank line.
fm_pr_description_contract() {  # <fm-root> <fm-home>
  local doc
  doc=$(fm_pr_visual_format_doc "$1" "$2")
  cat <<EOF
$FM_PR_CONTRACT_HEADING
Before reporting any PR ready, and again after ANY pipeline round or tool regenerates the body, rewrite the PR description to this structure (full detail and per-type evidence recipes: \`$doc\`):
- Purpose-first line naming this change's role (epic/incident context first when the change belongs to one).
- Terse reviewer-facing Changes bullets, not an essay.
- Type-appropriate visual evidence per the format doc: backend = mermaid diagram, bug fix = labeled Before/After, frontend = screenshots.
- One-line known limitations.
- One-line test evidence.
- Delete any machine-generated Intent/Risk sections.
BANNED, verbatim: first-person implementation diaries, fix-round archaeology, restated finding histories, individual teammate names, em-dashes, and ticket/Jira-key citations anywhere in committed content, documentation prose and code comments alike - the key lives in the PR title only. Comments must be terse and self-contained, with every fact a reader needs in the comment itself rather than leaning on a ticket for context. The one exception to the citation ban is an explicit TODO marker pointing at tracked future work, formulated exactly as \`TODO(ADC-123)\`.
Verify the PR title convention and this body structure together in the same pre-ready check, and re-verify both after every subsequent push or pipeline round up to your own stop point. A regeneration that lands after that stop point (a post-checks-green rebase, for example) is firstmate's merge-time gate, not yours: do not stay resident waiting for one.
EOF
}
