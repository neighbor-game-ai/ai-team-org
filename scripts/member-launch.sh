#!/usr/bin/env bash
# member-launch.sh — start one member (a background Claude Code session) the same way every time.
#
# Why one script: launching by hand went wrong in the same few ways again and again — the wrong
# account, a member that stopped to create its own worktree, a member that started from an
# uncommitted brief and later disagreed with what the lead thought it said. Every check below
# exists because one of those happened.
#
# Usage:
#   scripts/member-launch.sh <worktree> "<member name>" <brief path inside the worktree> [options]
#     --model <id>          model for this member (default: MEMBER_MODEL in org.env, else Claude Code's default)
#     --add-dir <dir>       extra folder the member may read/write (repeatable)
#     --mcp-config <file>   MCP config inside the worktree; only these servers are loaded (--strict-mcp-config)
#     --dry-run             print the account, the command and the prompt, and start nothing
#   e.g. scripts/member-launch.sh "$WORKTREE_ROOT/example-login" "Example login" docs/teams/example/tasks/login.md
#
# No `claude --bg` on your machine? Run with --dry-run, open a new terminal in the worktree,
# start claude there with the env shown on the printed line, and paste the printed prompt. Everything
# else (brief, status, report) works the same.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

usage() { sed -n '/^# Usage:/,/^# else/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
[ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; } && usage 0
[ $# -ge 3 ] || usage 1

# The member account is decided in one place (org.env). A value set in the environment wins,
# so a second person can launch with their own account without editing the shared file.
_cfg="${MEMBER_CONFIG_DIR:-}"; _wt="${WORKTREE_ROOT:-}"; _model="${MEMBER_MODEL:-}"; _perm="${MEMBER_PERMISSION_MODE:-}"
# shellcheck disable=SC1091
[ -f "$root/org.env" ] && . "$root/org.env"
[ -n "$_cfg" ] && MEMBER_CONFIG_DIR="$_cfg"
[ -n "$_wt" ] && WORKTREE_ROOT="$_wt"
[ -n "$_model" ] && MEMBER_MODEL="$_model"
[ -n "$_perm" ] && MEMBER_PERMISSION_MODE="$_perm"
expand() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }

wt="$(expand "$1")"; name="$2"; brief="$3"; shift 3
model="${MEMBER_MODEL:-}"; dry=0; extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    --add-dir) extra+=(--add-dir "$2"); shift 2 ;;
    # --strict-mcp-config: load only this file. All members share one config folder, so without it
    # one team's connections would leak into every other team's members.
    --mcp-config) [ -f "$wt/$2" ] || { echo "MCP config not found: $wt/$2"; exit 1; }
                  extra+=(--mcp-config "$wt/$2" --strict-mcp-config); shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "unknown option: $1"; usage 1 ;;
  esac
done

[ -n "${MEMBER_CONFIG_DIR:-}" ] || { echo "MEMBER_CONFIG_DIR is empty. Set it in org.env (copy org.env.example) — refusing to guess the account."; exit 1; }
cfg="$(expand "$MEMBER_CONFIG_DIR")"; cfg="${cfg%/}"
# ~/.claude is the default account. Claude Code keeps that login NEXT TO the folder (~/.claude.json)
# and uses it only while CLAUDE_CONFIG_DIR is unset; CLAUDE_CONFIG_DIR=~/.claude would switch to
# ~/.claude/.claude.json, a different login. So the default folder runs with CLAUDE_CONFIG_DIR unset.
if [ "$cfg" = "$HOME/.claude" ]; then login="$HOME/.claude.json"; envcfg=(-u CLAUDE_CONFIG_DIR)
else login="$cfg/.claude.json"; envcfg=("CLAUDE_CONFIG_DIR=$cfg"); fi
[ -d "$wt" ] || { echo "worktree not found: $wt  (from your workdir, after committing the brief: git -C \"<lead workdir>\" worktree add -b \"<team>/<task>\" \"${WORKTREE_ROOT:-<WORKTREE_ROOT>}/<team>-<task>\" HEAD)"; exit 1; }
wt="$(cd "$wt" && pwd)"
# Worktrees inside the app's own folder can be removed by its automatic cleanup, work and all.
case "$wt" in */.claude/worktrees/*) echo "worktree is inside .claude/worktrees/ — the app may clean it up. Create it under WORKTREE_ROOT instead."; exit 1 ;; esac
if [ -n "${WORKTREE_ROOT:-}" ]; then
  r="$(expand "$WORKTREE_ROOT")"
  case "$wt/" in "$r"/*) ;; *) echo "worktree is outside WORKTREE_ROOT ($r): $wt"; exit 1 ;; esac
fi
# The brief must be committed and clean: the member, the lead and the status script must all read the same text.
git -C "$wt" ls-files --error-unmatch "$brief" >/dev/null 2>&1 || { echo "brief is not committed: $brief"; exit 1; }
git -C "$wt" diff --quiet HEAD -- "$brief" || { echo "brief has uncommitted changes: $brief"; exit 1; }

# Show which account the member will run as, before anything starts.
account="(unknown — not logged in?)"
if command -v jq >/dev/null 2>&1 && [ -f "$login" ]; then
  account="$(jq -r '.oauthAccount.emailAddress // "(not logged in)"' "$login" 2>/dev/null || echo "(unreadable)")"
fi
echo "account: $account  ($cfg)   model: ${model:-default}"

# The rules travel with every member, so a brief never has to repeat them.
# Keep ${...} braces: bash 3.2 (macOS) can read a non-ASCII character right after $name as part of the name.
prompt="You are the member \"${name}\". You are already inside the worktree ${wt} (do not create another worktree). First read ${wt}/${brief} in full and do what it says (its first 3 lines are the lead's; don't change them). Rules: do not open pull requests, do not run the full test gate, do not push, do not switch git or gh accounts, and if a command is blocked do not retry it another way — write it in your final report. Use a headless browser only. Never print keys or tokens. Commit your work to this branch. End with a short report in the language of the brief: what you did, commits, how you checked it, what is left, and what was blocked."

# auto = the member works without stopping for routine permission prompts; your hooks still apply.
cmd=(claude --bg --permission-mode "${MEMBER_PERMISSION_MODE:-auto}" -n "$name")
[ -n "$model" ] && cmd+=(--model "$model")
cmd+=(${extra[@]+"${extra[@]}"})   # the +form avoids "unbound variable" for an empty array under set -u on bash 3.2

if [ "$dry" -eq 1 ]; then
  printf 'cd %q && env' "$wt"; printf ' %q' "${envcfg[@]}" "${cmd[@]}"; printf ' -- "<prompt>"\n\n--- prompt ---\n%s\n' "$prompt"
  exit 0
fi
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found. Use --dry-run and paste the prompt into a session by hand."; exit 1; }
claude --help 2>/dev/null | grep -q -- '--bg' || { echo "this claude CLI has no --bg. Use --dry-run and paste the prompt into a new terminal session by hand."; exit 1; }
cd "$wt"
env "${envcfg[@]}" "${cmd[@]}" -- "$prompt"
