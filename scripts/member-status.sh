#!/usr/bin/env bash
# member-status.sh — list members, or print a member's last report.
#
# Why this exists: a member's final report is the answer the lead needs, but members cannot
# message the lead, and `claude logs` only works while the session is still running. So this
# reads the report from the member's own transcript on disk.
#
# Usage:
#   scripts/member-status.sh                     list recent members: updated · state · id · name · folder
#   scripts/member-status.sh "<part of name>"    the member's last report (its last assistant message)
#   scripts/member-status.sh "<name>" <config dir>   read another account's members (e.g. after a handoff)
#
# Note: this reads Claude Code's job files (<config dir>/jobs/*/state.json and the transcript they
# point to). That layout is internal and may change; if it does, `claude agents` (list) and
# `claude attach <name>` (open a running member) are the supported fallbacks.
# Needs: jq.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
_cfg="${MEMBER_CONFIG_DIR:-}"
# shellcheck disable=SC1091
[ -f "$root/org.env" ] && . "$root/org.env"
[ -n "$_cfg" ] && MEMBER_CONFIG_DIR="$_cfg"
[ -n "${2:-}" ] && MEMBER_CONFIG_DIR="$2"
cfg="${MEMBER_CONFIG_DIR:-$HOME/.claude}"
case "$cfg" in "~") cfg="$HOME" ;; "~/"*) cfg="$HOME/${cfg#\~/}" ;; esac
q="${1:-}"
command -v jq >/dev/null 2>&1 || { echo "needs jq"; exit 1; }

# One line per job: updatedAt <TAB> state <TAB> job id <TAB> name <TAB> cwd <TAB> transcript
rows="$(for f in "$cfg"/jobs/*/state.json; do
  [ -f "$f" ] || continue
  id="$(basename "$(dirname "$f")")"
  jq -r --arg id "$id" '[.updatedAt // "", .state // "?", $id, .name // "", .cwd // "", .linkScanPath // ""] | @tsv' "$f" 2>/dev/null
done | sort -r)"
[ -n "$rows" ] || { echo "no members found in $cfg/jobs"; exit 0; }

if [ -z "$q" ]; then
  printf '%s\n' "$rows" | head -n 40 | awk -F'\t' '{ printf "%s  %-8s %s  %s  %s\n", substr($1,1,16), $2, $3, $4, $5 }' | sed "s|$HOME|~|g"
  exit 0
fi

# Match on part of the name, or the start of the job id. Newest first, so the latest run wins.
while IFS=$'\t' read -r _ state id name cwd transcript; do
  case "$name" in *"$q"*) ;; *) case "$id" in "$q"*) ;; *) continue ;; esac ;; esac
  echo "== $name  [$state]  $id  ${cwd/#$HOME/~}"
  if [ -f "$transcript" ]; then
    # Last assistant message that has text. Lines that are not JSON are skipped (fromjson?).
    jq -Rs 'split("\n") | map(fromjson? | select(.type == "assistant") | [.message.content[]? | select(type == "object" and .type == "text") | .text] | join("") | select(test("\\S"))) | last // "(no report yet)"' -r "$transcript"
  else
    echo "(transcript not found)"
  fi
  exit 0
done <<< "$rows"
echo "not found: $q"
exit 1
