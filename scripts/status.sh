#!/usr/bin/env bash
# status.sh — the whole org on one screen, without an LLM.
#
# What it shows: teams and who owns them, open tasks, running members, questions still waiting
# on the human, and the latest decisions. Use it instead of reading a handoff note.
#
# Why no LLM: the status must be the same no matter who asks, cost nothing, and never invent
# anything. So this script only reads the fixed formats in CONVENTIONS.md:
#   teams.tsv · docs/teams/<team>/decisions.md · the first 3 lines of docs/teams/<team>/tasks/*.md
# and asks Claude Code which background sessions are running (`claude agents --json`).
#
# Why it never hides a problem: a status screen that quietly drops what it can't read is worse
# than none — the missing task is exactly the one nobody looks at. So:
#   - a task whose header is broken or whose Status is not active/waiting/done is listed as
#     "unknown" and named under "Warnings" (an earlier version counted it as done and hid it);
#   - "Running members" says "cannot check (<reason>)" when `claude agents` is missing, fails or
#     times out, and "- none" only when it answered and the answer was empty.
#
# Usage:  scripts/status.sh [team ...]        e.g. scripts/status.sh example
# Exit:   0 = no warnings · 1 = there are warnings (see the "Warnings" section)
# Needs:  bash 3.2+ and standard Unix tools. `claude` + `jq` are optional (only for "Running members";
#         without them that section says it cannot check, and why).
# Speed:  measured ~0.5 s for the example team, including `claude agents` (it times out after
#         STATUS_AGENTS_TIMEOUT seconds, default 10).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

# org.env is the one place for per-machine settings (see org.env.example).
# A value already set in the environment wins, so a second person can use their own account
# without editing the shared file.
_cfg="${MEMBER_CONFIG_DIR:-}"; _wt="${WORKTREE_ROOT:-}"
# shellcheck disable=SC1091
[ -f "$root/org.env" ] && . "$root/org.env"
[ -n "$_cfg" ] && MEMBER_CONFIG_DIR="$_cfg"
[ -n "$_wt" ] && WORKTREE_ROOT="$_wt"
tsv="${ORG_TEAMS_TSV:-$root/teams.tsv}"
agents_timeout="${STATUS_AGENTS_TIMEOUT:-10}"

# Paths in teams.tsv may be absolute, start with ~, or be relative to this repo.
expand() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$root" "$1" ;;
  esac
}
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# Run a command with a time limit. macOS has no `timeout` by default, so fall back to a watchdog.
# The watchdog's output goes to /dev/null: otherwise $(...) would wait for its `sleep` to end.
# Exit 124 = timed out (same code as coreutils `timeout`).
with_timeout() {
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  "$@" & local p=$!
  ( sleep "$s"; kill "$p" 2>/dev/null ) >/dev/null 2>&1 & local w=$!
  wait "$p"; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  [ "$rc" -eq 143 ] && rc=124
  return "$rc"
}

nl=$'\n'; tab=$'\t'
tasks=""; asks=""; recent=""; warn=""; seen=" "; every=""
[ -f "$tsv" ] || { echo "teams.tsv not found: $tsv"; exit 1; }

echo "== Teams (teams.tsv)"
# Columns are tab-separated. Empty columns are not allowed (bash's read would shift them), use "-".
while IFS=$'\t' read -r team session owner workdir branch charter _rest || [ -n "${team:-}" ]; do
  case "$team" in ''|'#'*) continue ;; esac
  charter="${charter%$'\r'}"
  if [ -z "$charter" ]; then warn+="teams.tsv: a row has fewer than 6 columns (team: $team)$nl"; continue; fi
  if [ $# -gt 0 ]; then case " $* " in *" $team "*) ;; *) continue ;; esac; fi
  printf '%-14s %s / %s  [%s]\n' "$team" "$session" "$owner" "$branch"
  dir="$(expand "$workdir")"
  case "$dir" in */.claude/worktrees/*) warn+="$team: workdir is inside .claude/worktrees/ (the app may clean it up). Move it under WORKTREE_ROOT$nl" ;; esac
  # "." = this repo itself (used by the example team). Everything else should live under WORKTREE_ROOT.
  if [ -n "${WORKTREE_ROOT:-}" ] && [ "$workdir" != "." ]; then
    case "$dir/" in "$(expand "$WORKTREE_ROOT")"/*) ;; *) warn+="$team: workdir is outside WORKTREE_ROOT: $workdir$nl" ;; esac
  fi
  if [ ! -d "$dir" ]; then warn+="$team: workdir not found: $workdir$nl"; continue; fi
  [ -f "$dir/$charter" ] || warn+="$team: charter not found: $charter$nl"
  tdir="$dir/docs/teams/$team"

  # Tasks: only the first 3 lines are read, and they must be exactly
  #   Status: active|waiting|done / Owner: … / Waiting on: …
  # Anything else is shown as "unknown" with the reason — never silently dropped as done.
  for t in "$tdir"/tasks/*.md; do
    [ -f "$t" ] || continue
    name="$team/$(basename "$t" .md)"
    l1=""; l2=""; l3=""
    { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; } < "$t"
    l1="${l1%$'\r'}"; l2="${l2%$'\r'}"; l3="${l3%$'\r'}"
    why=""; st=""; ow="?"; wa="?"
    case "$l1" in Status:*) st="$(trim "${l1#Status:}")" ;; *) why="line 1 is not \"Status: …\"" ;; esac
    case "$l2" in Owner:*) ow="$(trim "${l2#Owner:}")" ;; *) why="${why:+$why, }line 2 is not \"Owner: …\"" ;; esac
    case "$l3" in "Waiting on:"*) wa="$(trim "${l3#Waiting on:}")" ;; *) why="${why:+$why, }line 3 is not \"Waiting on: …\"" ;; esac
    if [ -z "$why" ]; then
      case "$st" in active|waiting|done) ;; *) why="Status is \"$st\" (must be active, waiting or done)" ;; esac
    fi
    if [ -n "$why" ]; then
      st="unknown"
      warn+="$name: $why — listed as unknown. Fix the first 3 lines (CONVENTIONS.md §2)$nl"
    fi
    every+="$name$tab$st$tab$session$nl"
    [ "$st" = "done" ] && continue
    tasks+="$name: $st · ${ow:-?} · waiting on: ${wa:--}$nl"
  done

  # Decisions: one file per team, written only by the team's first row (CONVENTIONS.md §1),
  # so read it once per team even when several rows share the team.
  case "$seen" in *" $team "*) continue ;; esac
  seen+="$team "
  dec="$tdir/decisions.md"
  if [ -f "$dec" ]; then
    while IFS= read -r l; do asks+="$team: ${l#- OPEN }$nl"; done < <(grep -E '^- OPEN ' "$dec")
    while IFS= read -r l; do recent+="$team: ${l#- }$nl"; done < <(grep -E '^- ' "$dec" | grep -vE '^- OPEN ' | tail -n 3)
  else
    warn+="$team: decisions.md not found: docs/teams/$team/decisions.md$nl"
  fi
done < "$tsv"

# A parallel lead's worktree branches off the same team branch, so it carries copies of the same
# task files. Identical lines are shown once. When the copies disagree (e.g. "active" in one
# workdir and "done" in the other) the open line alone would not tell you, so the disagreement is
# named under "Warnings" with each row's session. The task's Owner (line 2) holds the copy that counts.
printf '\n== Open tasks (first 3 lines of tasks/*.md)\n%s' "${tasks:-- none$nl}" | awk '!s[$0]++'
warn+="$(printf '%s' "$every" | awk -F'\t' '
  { k = $1; v = $2 " (" $3 ")"; if (!(k in all)) order[++n] = k
    if (index(SUBSEP all[k] SUBSEP, SUBSEP v SUBSEP) == 0) all[k] = all[k] SUBSEP v
    if (index(" " st[k] " ", " " $2 " ") == 0) { st[k] = st[k] " " $2; c[k]++ } }
  END { for (i = 1; i <= n; i++) { k = order[i]; if (c[k] > 1) { s = all[k]; gsub(SUBSEP, ", ", s); sub(/^, /, "", s)
        printf "%s: the copies in parallel workdirs disagree: %s — the Owner'"'"'s copy counts\n", k, s } } }')"
[ -n "${warn##*"$nl"}" ] && warn+="$nl"

echo; echo "== Running members (claude agents)"
# "- none" must mean "asked, and nothing is running". Anything else is "cannot check (<why>)",
# so a broken CLI never looks like a quiet org.
agents_err=""
if ! command -v claude >/dev/null 2>&1; then agents_err="the claude CLI is not installed or not on PATH"
elif ! command -v jq >/dev/null 2>&1; then agents_err="jq is not installed"
else
  # Output goes to a file, not a pipe: a killed CLI can leave a child holding the pipe open,
  # and reading the pipe would then wait for that child instead of the time limit.
  tmp="$(mktemp "${TMPDIR:-/tmp}/status-agents.XXXXXX")"; trap 'rm -f "$tmp"' EXIT
  # ~/.claude is the default account: run with CLAUDE_CONFIG_DIR unset, as `claude` itself would
  # (setting it to ~/.claude would make the CLI read a different login file, ~/.claude/.claude.json).
  (if [ -n "${MEMBER_CONFIG_DIR:-}" ]; then c="$(expand "$MEMBER_CONFIG_DIR")"; c="${c%/}"
     if [ "$c" = "$HOME/.claude" ]; then unset CLAUDE_CONFIG_DIR; else CLAUDE_CONFIG_DIR="$c"; export CLAUDE_CONFIG_DIR; fi
   fi
   with_timeout "$agents_timeout" claude agents --json >"$tmp" 2>/dev/null)
  rc=$?; json="$(cat "$tmp")"
  if [ "$rc" -eq 124 ]; then agents_err="claude agents --json did not answer within ${agents_timeout}s"
  elif [ "$rc" -ne 0 ]; then agents_err="claude agents --json failed (exit $rc)"
  elif ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then agents_err="claude agents --json did not return a JSON list"
  else
    # Background sessions of the member account. The state is whatever the CLI reports: today it is
    # `.state` (working · blocked = needs a person · done); older versions used `.status`, so read both.
    out="$(printf '%s' "$json" \
        | jq -r '.[] | select(.kind == "background") | "\(.state // .status // "(state missing)")\t\(.name // "(no name)")\t\(.cwd // "")"' \
        | sed "s|$HOME|~|" | awk -F'\t' '{ printf "%-8s %s  %s\n", $1, $2, $3 }' | sort)"
    echo "${out:-- none}"
  fi
fi
if [ -n "$agents_err" ]; then
  echo "- cannot check ($agents_err)"
  warn+="Running members could not be checked: $agents_err$nl"
fi

printf '\n== Waiting on the human (decisions.md "- OPEN" lines)\n%s' "${asks:-- none$nl}"
printf '\n== Latest decisions (last 3 per team)\n%s' "${recent:-- none$nl}"
if [ -n "$warn" ]; then
  printf '\n== Warnings\n'; printf '%s' "$warn" | awk 'NF && !s[$0]++' | sed 's/^/! /'
  exit 1
fi
exit 0
