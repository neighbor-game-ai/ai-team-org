#!/usr/bin/env bash
# human-ok.sh — the human's unlock switch for hooks/human-gate.sh.
#
# Usage (in your own terminal, inside the checkout you looked at):
#   hooks/human-ok.sh [<folder>]            unlock this repository + its current branch for HUMAN_OK_TTL_HOURS (default 6)
#   hooks/human-ok.sh --revoke [<folder>]   lock it again now
# <folder> defaults to the current folder. The hook's refusal message prints the exact line to run.
#
# Why repository + branch (not just the branch name): an OK is for one change in one repository.
# A branch called "main" or "fix/login" exists in many repositories; the OK must not leak into them.
# Any worktree of the same repository on the same branch counts as the same thing.
#
# Why a time limit: an OK is for the change you looked at. Hours later the branch has moved on.
# The commit you were looking at is written into the unlock file, so you can check it later.
set -e
# Only an interactive terminal is accepted. Claude Code's Bash tool and subagents have no TTY,
# so they are refused here even if they get past the hook.
if ! [ -t 0 ] || ! [ -t 1 ]; then
  echo "human-ok.sh must be run by the human in an interactive terminal." >&2
  exit 1
fi
revoke=0; [ "${1:-}" = "--revoke" ] && { revoke=1; shift; }
dir="${1:-.}"
gate="$(cd "$(dirname "$0")" && pwd)/human-gate.sh"
# The key (which unlock file belongs to this repo + branch) is computed by the hook itself,
# so the two scripts can never disagree.
k="$("$gate" --key "$dir")" || { echo "Can't unlock: see above. Run this inside the checkout of the branch you approve." >&2; exit 1; }
IFS=$'\t' read -r mark repo branch <<< "$k"
if [ "$revoke" -eq 1 ]; then
  rm -f "$mark"; echo "locked: $branch  ($repo)"; exit 0
fi
mkdir -p "$(dirname "$mark")"
{ printf '%s\t%s\n' "$repo" "$branch"; echo "approved: $(date)"; echo "commit: $(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"; } > "$mark"
echo "OK: $branch is unlocked for ${HUMAN_OK_TTL_HOURS:-6} hours  ($repo, at commit $(git -C "$dir" rev-parse --short HEAD 2>/dev/null))."
