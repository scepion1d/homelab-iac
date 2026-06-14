#!/bin/bash
# homelab-reconcile.sh — single entrypoint for the GitOps reconcile loop.
#
# Two modes:
#   (default)                 run ansible-playbook ansible/reconcile.yml
#                             (used by com.homelab.ansible-reconcile, the
#                             safety-net timer that fires every M seconds
#                             whether or not git HEAD moved).
#   --pull-from=<branch|auto> fetch origin/<branch>; if HEAD moved, fast-
#                             forward and reconcile. If HEAD is unchanged,
#                             exit 0 without running ansible-playbook.
#                             (used by com.homelab.git-pull every N seconds.)
#
# Both modes acquire the same lock (LOCK_DIR below). Lock spans the entire
# critical section — fetch + pull + ansible — so a safety-net reconcile
# cannot read files while git-pull is rewriting them, and two reconciles
# can never overlap.
#
# Locking uses mkdir (POSIX-atomic, no external `flock`/`lockf` needed).
# Stale-lock recovery: on contention, we re-check whether the recorded PID
# is still alive; if not, we reclaim. This handles hard crashes / SIGKILL.
#
# Operators can also invoke this directly from a checkout:
#   ./ansible/scripts/homelab-reconcile.sh                  # plain reconcile
#   ./ansible/scripts/homelab-reconcile.sh --pull-from=auto # pull-then-reconcile
# The same lock guards the daemons, so manual runs won't race them either.

set -euo pipefail

REPO="${HOME:-/Users/homelab-admin}/src/homelab-iac"
LOCK_DIR=/tmp/com.homelab.reconcile.lock.d
ANSIBLE_PLAYBOOK=/usr/local/bin/ansible-playbook

ts() { date '+%F %T %Z'; }

# --- Argument parsing ------------------------------------------------------
mode="reconcile"   # or "pull-then-reconcile"
branch_arg=""
for a in "$@"; do
  case "$a" in
    --pull-from=*) mode="pull-then-reconcile"; branch_arg="${a#--pull-from=}" ;;
    -h|--help)
      cat <<EOF
usage: $0 [--pull-from=<branch|auto>]

  (no args)             reconcile only (safety-net mode)
  --pull-from=auto      pull current branch; reconcile if HEAD moved
  --pull-from=v2        pull explicit branch; reconcile if HEAD moved
EOF
      exit 0
      ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# --- Lock acquisition (mkdir is atomic) -----------------------------------
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
    echo "[$(ts)] reconcile: lock held by pid $holder_pid, skipping"
    exit 0
  fi
  # Stale lock — reclaim. Loud, because this means a previous run died.
  echo "[$(ts)] reconcile: stale lock (pid=${holder_pid:-?} no longer alive), reclaiming" >&2
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || { echo "[$(ts)] reconcile: failed to reclaim lock" >&2; exit 1; }
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM HUP

# --- Environment -----------------------------------------------------------
cd "$REPO"
export ANSIBLE_CONFIG="$REPO/ansible.cfg"
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
export HOME="${HOME:-/Users/homelab-admin}"
# Git: never prompt, never hang on a dead origin.
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT=1024
export GIT_HTTP_LOW_SPEED_TIME=30
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15"

# --- Optional pull stage ---------------------------------------------------
if [[ "$mode" == "pull-then-reconcile" ]]; then
  current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ -z "$current_branch" ]]; then
    echo "[$(ts)] git-pull: HEAD detached, skipping" >&2
    exit 0
  fi

  if [[ -z "$branch_arg" || "$branch_arg" == "auto" ]]; then
    branch="$current_branch"
  else
    branch="$branch_arg"
    if [[ "$current_branch" != "$branch" ]]; then
      echo "[$(ts)] git-pull: checked-out '$current_branch' != configured '$branch', skipping" >&2
      exit 0
    fi
  fi

  # Never blast operator changes. `git diff --quiet HEAD` covers tracked
  # files (staged + unstaged); untracked files don't matter for a FF merge
  # unless a pulled path collides, in which case `git merge --ff-only`
  # fails loudly below.
  if ! git diff --quiet HEAD 2>/dev/null; then
    echo "[$(ts)] git-pull: working tree dirty on $branch, skipping"
    exit 0
  fi

  if ! git fetch --quiet origin "$branch"; then
    echo "[$(ts)] git-pull: fetch failed for origin/$branch" >&2
    exit 1
  fi

  local_sha=$(git rev-parse HEAD)
  remote_sha=$(git rev-parse "origin/$branch")
  if [[ "$local_sha" == "$remote_sha" ]]; then
    # No new commits — exit before touching ansible.
    exit 0
  fi

  # Guard against local-ahead/diverged: only proceed if local is an
  # ancestor of remote (true fast-forward case).
  if ! git merge-base --is-ancestor "$local_sha" "$remote_sha"; then
    echo "[$(ts)] git-pull: $branch local ${local_sha:0:7} is ahead of or diverged from origin ${remote_sha:0:7}; manual intervention needed" >&2
    exit 1
  fi

  echo "[$(ts)] git-pull: $branch ${local_sha:0:7} -> ${remote_sha:0:7}"
  if ! git merge --ff-only --quiet "$remote_sha"; then
    echo "[$(ts)] git-pull: fast-forward merge failed" >&2
    exit 1
  fi
fi

# --- Reconcile -------------------------------------------------------------
head_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
echo "[$(ts)] reconcile: starting at $head_sha (mode=$mode)"
set +e
"$ANSIBLE_PLAYBOOK" ansible/reconcile.yml
rc=$?
set -e
echo "[$(ts)] reconcile: finished rc=$rc"
exit $rc
