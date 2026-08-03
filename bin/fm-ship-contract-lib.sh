#!/usr/bin/env bash
# Single owner of the mode-shaped ship contract a crewmate is held to: the extra
# Setup steps, Rule 1, and the whole `# Definition of done` section, generated
# per delivery mode (no-mistakes, direct-PR, local-only).
#
# Two entry points share this text so each mode's contract has exactly one home:
#   bin/fm-brief.sh    scaffolds a fresh ship brief around these blocks
#   bin/fm-promote.sh  rewrites a promoted scout's brief onto the same blocks, so
#                      a promotion produces one coherent ship contract instead of
#                      a scout charter with ship text stapled onto the end
#
# Each PR-producing DOD embeds the generated PR-description contract owned by
# bin/fm-pr-contract-lib.sh, ordered ahead of that mode's terminal `done:` gate so
# a worker executing the section in order cannot report done before applying it.
# local-only raises no PR and carries no such block.

FM_SHIP_CONTRACT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-contract-lib.sh
. "$FM_SHIP_CONTRACT_LIB_DIR/fm-pr-contract-lib.sh"

# Print the extra numbered Setup steps this mode adds after the branch step, or
# nothing. The leading newline is part of the value so it splices directly onto
# the end of the branch-step line.
fm_ship_setup_steps() {  # <mode>
  case "$1" in
    no-mistakes)
      # shellcheck disable=SC2016  # single quotes are deliberate: this is literal brief text whose backticked commands must reach the reading agent verbatim.
      printf '\n%s' '2. Run `no-mistakes doctor`; if it reports the repo is not initialized here, run `no-mistakes init`.'
      ;;
  esac
}

# Print this mode's Rule 1: the push/PR authority the worker operates under.
fm_ship_rule1() {  # <mode> <task-id>
  case "$1" in
    direct-PR)
      printf '%s\n' '1. Never push to the default branch (push only your `fm/'"$2"'` branch). Never merge a PR.'
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`fm/$2\` branch; firstmate handles the merge into local \`main\`."
      ;;
    *)
      printf '%s\n' '1. Never push to the default branch. Never merge a PR.'
      ;;
  esac
}

# Print Rule 2: a ship task keeps nothing outside its worktree but the status
# file, where a scout also writes the report it no longer produces.
fm_ship_rule2() {
  printf '%s\n' '2. Stay inside this worktree; modify nothing outside it.'
}

# Print the complete `# Definition of done` section for this mode. It opens with
# the fixed "Delivery contract: mode=<mode>" line bin/fm-spawn.sh checks against
# its own explicit --mode, and closes with the mode's terminal `done:` gate.
fm_ship_dod() {  # <mode> <task-id> <fm-root> <fm-home>
  local mode=$1 id=$2 root=$3 home=$4 contract
  case "$mode" in
    direct-PR)
      contract=$(fm_pr_description_contract "$root" "$home")
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.

$contract

When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    *)
      contract=$(fm_pr_description_contract "$root" "$home")
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its \`AGENTS.md\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

$contract

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
  esac
}

# Print the Setup framing that replaces a promoted scout's report-deliverable
# framing. A promoted task keeps the worktree it scouted in, so its first step is
# to reconcile that scratch state rather than to branch from a pristine checkout.
fm_promoted_setup_framing() {  # <mode> <task-id>
  local mode=$1 id=$2 deliverable
  case "$mode" in
    direct-PR) deliverable='a PR you raise yourself, not a report' ;;
    local-only) deliverable="a ready branch \`fm/$id\`, not a report" ;;
    *) deliverable='a PR shipped through the no-mistakes pipeline, not a report' ;;
  esac
  cat <<EOF
This task was promoted from scout to a SHIP task: the deliverable is $deliverable.
The worktree is no longer a throwaway laboratory. It still holds your scout scratch state, so anything this task ships must land as real commits on your own branch.

1. First action: inventory the scratch state with \`git status\` and \`git log\`, reset to a clean default-branch base, carry over only the changes this task intends to ship, then create your branch: \`git checkout -b fm/$id\`$(fm_ship_setup_steps "$mode")
EOF
}
