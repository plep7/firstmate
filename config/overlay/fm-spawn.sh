# shellcheck shell=bash
# Overlay for bin/fm-spawn.sh: a tracked, code-root-sourced file (loaded from
# $FM_ROOT, not a per-home config dir) that ships with the code, so it is
# present wherever bin/fm-spawn.sh runs - every home, CI, and every test that
# runs the real script from the worktree. Sourced only when present, after
# upstream defines validate_spawn_worktree but before its first call site, so
# the redefinition below shadows it for every call in the rest of the script.
# `config/overlay/` is a path the upstream repo does not have, so this file is
# purely additive and never conflicts on rebase - the same reason
# bin/nm-pr-format never conflicts. See
# data/fm-fork-extension-design/report.md section 3 for the design and
# section 4 for the migration this file is step 2 of.

# Resolve one of `git rev-parse --git-dir`/`--git-common-dir` (run with <base-dir>
# as cwd, so a relative result is relative to it) to a canonical absolute path.
# Echoes nothing and returns 1 if the raw value is empty or unresolvable.
resolve_git_meta_dir() {  # <base-dir> <raw-git-dir-output>
  local base=$1 raw=$2
  [ -n "$raw" ] || return 1
  case "$raw" in
    /*) : ;;
    *) raw="$base/$raw" ;;
  esac
  (cd "$raw" 2>/dev/null && pwd -P)
}

# A pool spawn (treehouse or Orca) must yield a genuinely isolated, untouched
# lease: distinct from the primary checkout (the original check), detached HEAD
# (ship briefs create the task branch afterward, so an already-named branch
# means this is somebody's in-progress checkout, not a fresh lease), clean (no
# uncommitted or untracked changes), and not itself a repo's main worktree (a
# main worktree can anchor linked worktrees of its own; a pooled lease is
# always a linked worktree). The incident this hardens against: treehouse's
# atelier pool exhausted and `treehouse get` fell back to returning the
# captain's live `~/Developer/hde/atelier` checkout - a checkout on a named
# feature branch, with uncommitted changes, that itself owns nine linked
# worktrees. It was distinct from PROJ_ABS, so the original check alone passed
# it straight to a crewmate.
validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2
  local wt_real proj_real wt_top wt_top_real reason
  local wt_branch wt_dirty wt_git_dir_raw wt_common_dir_raw wt_git_dir wt_common_dir
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=$PROJ_ABS_REAL
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  reason=
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    # shellcheck disable=SC2153 # WT/PROJ_ABS are globals set by bin/fm-spawn.sh before sourcing this file
    reason="resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'"
  fi
  if [ -z "$reason" ]; then
    wt_branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$wt_branch" ]; then
      reason="HEAD is on named branch '$wt_branch', not a fresh detached pooled lease"
    fi
  fi
  if [ -z "$reason" ]; then
    wt_dirty=$(git -C "$WT" status --porcelain 2>/dev/null || true)
    if [ -n "$wt_dirty" ]; then
      reason="worktree has uncommitted or untracked changes, not a fresh pooled lease"
    fi
  fi
  if [ -z "$reason" ]; then
    wt_git_dir_raw=$( (cd "$WT" 2>/dev/null && git rev-parse --git-dir 2>/dev/null) || true )
    wt_common_dir_raw=$( (cd "$WT" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || true )
    wt_git_dir=$(resolve_git_meta_dir "$WT" "$wt_git_dir_raw" || true)
    wt_common_dir=$(resolve_git_meta_dir "$WT" "$wt_common_dir_raw" || true)
    if [ -n "$wt_git_dir" ] && [ -n "$wt_common_dir" ] && [ "$wt_git_dir" = "$wt_common_dir" ]; then
      reason="worktree is a repo's own main checkout (git-dir equals git-common-dir), so it can anchor linked worktrees of its own, not a linked pooled lease"
    fi
  fi
  if [ -n "$reason" ]; then
    echo "error: $source did not yield an isolated worktree ($reason); refusing to launch to avoid tangling a live checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

# Non-interactive, durable lease: run `treehouse get --lease` ourselves (cwd in
# proj_abs, since treehouse resolves the pool from the working directory - same
# rule fm-teardown.sh's `treehouse return` already follows) and capture the
# printed worktree path directly, instead of sending interactive `treehouse
# get` into the pane and polling the pane's cwd for its subshell to move. This
# is the fix for the incident that motivated the isolation guard above: the
# interactive form opens a subshell and, when the pool cannot cleanly produce
# a worktree, silently falls back to the CALLER'S OWN DIRECTORY - fine for a
# human at a terminal, dangerous for an unattended spawn, and how a pane once
# landed in a captain's own live checkout. `--lease` never opens a subshell and
# never falls back: it either prints a leased worktree's absolute path on
# stdout, or it fails loudly.
fm_overlay_spawn_acquire_worktree() {  # <proj-abs> <id> <wt-target> <t>
  local proj_abs=$1 id=$2 wt
  command -v treehouse >/dev/null 2>&1 || { echo "error: treehouse command not found; cannot acquire a worktree for $id in $proj_abs" >&2; return 1; }
  wt=$(cd "$proj_abs" && treehouse get --lease --lease-holder "$id") || {
    echo "error: treehouse get --lease failed to acquire a worktree for $id in $proj_abs; inspect the pool with 'treehouse status'" >&2
    return 1
  }
  [ -n "$wt" ] || { echo "error: treehouse get --lease printed no worktree path for $id in $proj_abs" >&2; return 1; }
  printf '%s\n' "$wt"
}

# Lease-refusal cleanup: a lease acquired above but rejected by
# validate_spawn_worktree (an unpooled/dirty/named-branch fallback, the same
# atelier shape the guard hardens against) must go back to the pool, not sit
# leased forever under $id with nobody using it. validate_spawn_worktree exits
# the whole script directly on refusal, so the caller arms this EXIT trap right
# after acquiring the lease and disarms it right after validation passes -
# the trap only ever fires inside that narrow window.
FM_OVERLAY_LEASE_PROJ=
FM_OVERLAY_LEASE_WT=
fm_overlay_spawn_lease_guard_arm() {  # <proj-abs> <wt>
  FM_OVERLAY_LEASE_PROJ=$1
  FM_OVERLAY_LEASE_WT=$2
  trap fm_overlay_spawn_lease_guard_release EXIT
}
fm_overlay_spawn_lease_guard_disarm() {
  FM_OVERLAY_LEASE_WT=
  trap orca_spawn_abort_cleanup EXIT
}
fm_overlay_spawn_lease_guard_release() {
  local status=$?
  if [ -n "$FM_OVERLAY_LEASE_WT" ]; then
    (cd "$FM_OVERLAY_LEASE_PROJ" 2>/dev/null && treehouse return --force "$FM_OVERLAY_LEASE_WT") >/dev/null 2>&1 \
      || echo "warning: could not return refused lease $FM_OVERLAY_LEASE_WT; inspect 'treehouse status'" >&2
  fi
  return "$status"
}
