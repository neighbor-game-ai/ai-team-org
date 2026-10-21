#!/usr/bin/env bash
# human-gate.sh — a Claude Code PreToolUse hook (matcher: Bash, plus optional tools, see hooks/README.md).
#
# What it does: some commands may only run after the human has said OK — opening a pull request,
# pushing, running the expensive full test gate. This hook refuses them unless the human has
# unlocked that repository + branch from their own terminal with hooks/human-ok.sh, for a limited time.
#
# Why a hook and not a rule in CLAUDE.md: the rule was written down three times and still broken.
# An AI follows written rules most of the time; a hook is checked on every Bash command, so the
# usual slip ("the work is done, so open the PR") gets caught even late in a long session.
#
# What it is NOT: a security boundary. It catches the common ways of writing these commands
# (`git push`, `git -C dir push`, `env git push`, `/usr/bin/git push`, `npm --prefix x run check:all`,
# `bash -c "…"`, `$(…)`, `cd other && …`). It does not see through variables (`$G push`), scripts that
# push internally, aliases, or anything that runs as your user and writes the unlock file directly.
# Pair it with the written rule "if a command is blocked, don't try another way; report it".
#
# Decisions: exit 0 = allow, exit 2 = refuse (the reason goes to stderr, which Claude reads).
# Refusing never needs jq, so a missing jq or unreadable input refuses instead of letting
# everything through (an earlier version treated "could not parse" as "nothing to check").
#
# Other mode (used by human-ok.sh and the tests, not by Claude Code):
#   human-gate.sh --key <folder>   print "<unlock file>\t<repo>\t<branch>" for that checkout
#
# Setup: see hooks/README.md. Needs git and jq (without jq every Bash command is refused, with the reason).

OK_DIR="${HUMAN_OK_DIR:-$HOME/.claude/human-ok}"
TTL_HOURS="${HUMAN_OK_TTL_HOURS:-6}"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# What needs the human's OK. Edit these for your project; keep them short (every gate is a stop
# you clear by hand). Matching is on the parsed command, not on text, so `cat scripts/check-all.sh`,
# `grep "git push" notes.md` and `echo "gh pr create"` still run.
GATED_GIT=" push "                       # git <subcommand>
GATED_GH_PR=" create new ready merge "   # gh pr <subcommand>
GATED_SCRIPTS=" check:all "              # npm|pnpm|yarn|bun [run] <script>

deny() { printf '%s\n' "$1" >&2; exit 2; }

# --- Approval key -------------------------------------------------------------------------------
# An approval belongs to one repository + one branch. The repository is identified by its shared
# .git folder (`--git-common-dir`), so every worktree of the same repo agrees, and a same-named
# branch in another repo does not. The file name is a hash of "repo<TAB>branch", so "a/b" and
# "a__b" can't collide (an earlier version turned "/" into "__"). The file's first line repeats
# repo and branch and is compared on read.
hash_of() { { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || cksum; } | cut -c1-40 | tr -c '0-9a-zA-Z\n' _; }
# Prints "<unlock file>\t<repo>\t<branch>", or a reason on stderr and returns 1.
key_for() {
  local dir="$1" repo branch
  repo="$(cd "$dir" 2>/dev/null && common="$(git rev-parse --git-common-dir 2>/dev/null)" && cd "$common" && pwd -P)" \
    || { echo "not inside a git repository: $dir" >&2; return 1; }
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)" \
    || { echo "no branch checked out (detached HEAD) in $dir" >&2; return 1; }
  printf '%s\t%s\t%s\n' "$OK_DIR/$(printf '%s\t%s' "$repo" "$branch" | hash_of)" "$repo" "$branch"
}
if [ "${1:-}" = "--key" ]; then key_for "${2:-.}"; exit $?; fi

# --- Read the hook input ------------------------------------------------------------------------
INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || deny "human-gate: jq is not installed, so this hook cannot read the command and refuses it. Ask the human to install jq (e.g. brew install jq / apt install jq)."
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || deny "human-gate: the hook input is not valid JSON, so the command is refused. Report this to the human."
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"
[ -n "$CWD" ] || CWD="$PWD"

UNLOCK_MSG="Only the human can unlock this. Do not create the unlock file or run human-ok.sh. Ask the human to run it in their own terminal."

# --- File tools (if your matcher includes Write/Edit): never write into the unlock folder ---------
case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit)
    case "$FILE" in "$OK_DIR"/*|*/human-ok/*) deny "$UNLOCK_MSG" ;; esac
    exit 0 ;;
esac

# --- Which actions need an OK, and where they run ------------------------------------------------
targets=""    # one line per gated action: "<folder>\t<what>"
add_target() { targets+="$1"$'\t'"$2"$'\n'; }
abs_dir() { case "$2" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${2#\~/}" ;; /*) printf '%s' "$2" ;; *) printf '%s/%s' "$1" "$2" ;; esac; }

if [ "$TOOL" != "Bash" ] && [ -n "$TOOL" ]; then
  # A non-Bash tool reached this hook only because your matcher names it (e.g. a GitHub MCP tool
  # that opens a pull request). It runs for the session's folder.
  case "$TOOL" in mcp__*) add_target "$CWD" "$TOOL" ;; *) exit 0 ;; esac
else
  [ -n "$CMD" ] || exit 0

  # 1. Claude must not unlock itself: refuse writes into the unlock folder and running human-ok.sh.
  #    Only "write into human-ok/" or "human-ok.sh in command position" — a command that merely
  #    mentions the name (docs, a commit message, grep) still runs.
  #    The unlock folder is matched by its default name and by HUMAN_OK_DIR, if you moved it.
  writes='(>|\btee\b|\btouch\b|\bcp\b|\bmv\b|\bln\b|\bmkdir\b|\brm\b|\binstall\b|\bdate\b)'
  if printf '%s' "$CMD" | grep -Eq "$writes"'[^;&|]*human-ok/' \
     || { printf '%s' "$CMD" | grep -Fq "$OK_DIR" && printf '%s' "$CMD" | grep -Eq "$writes"; } \
     || printf '%s' "$CMD" | grep -Eq '(^|[;&|(`]|\$\()[[:space:]]*((/usr)?/bin/)?(env[[:space:]]+)?((bash|sh|zsh|source)[[:space:]]+|\.[[:space:]]+)?[~./A-Za-z0-9_-]*human-ok\.sh'; then
    deny "$UNLOCK_MSG"
  fi

  # 2. Split the command into simple commands, respecting quotes. One line per simple command,
  #    words separated by \037. `;` `&` `|` `(` `)` newlines, `$(…)` and backticks start a new simple
  #    command; the text after a `$(…)` continues the outer one. Quotes are removed, so "git" push
  #    and g\it push are seen as git push, while echo "gh pr create" stays one echo word.
  split_commands() {
    GATE_CMD="$1" awk 'function tok_end() { if (have) { line = line (nt ? US : "") tok; nt++ } tok = ""; have = 0 }
      function cmd_end() { tok_end(); if (nt) print line; line = ""; nt = 0 }
      function push(m) { sp++; sm[sp] = m; sl[sp] = line; sn[sp] = nt; st[sp] = tok; sh[sp] = have; tok_end(); line = ""; nt = 0; tok = ""; have = 0 }
      function pop() { cmd_end(); mode = sm[sp]; line = sl[sp]; nt = sn[sp]; tok = st[sp]; have = 1; sp-- }
      BEGIN { s = ENVIRON["GATE_CMD"]; n = length(s); US = "\037"; mode = "n"; sp = 0
        for (i = 1; i <= n; i++) {
          c = substr(s, i, 1)
          if (mode == "s") { if (c == "\047") mode = "n"; else tok = tok c; continue }
          if (mode == "d") {
            if (c == "\"") { mode = "n"; continue }
            if (c == "\\") { i++; tok = tok substr(s, i, 1); continue }
            if (c == "$" && substr(s, i + 1, 1) == "(") { i++; push("d"); mode = "n"; continue }
            if (c == "`") { push("d`"); mode = "n"; continue }
            if (c == "\n") c = " "
            tok = tok c; continue
          }
          if (c == "\\") { i++; c = substr(s, i, 1); if (c != "\n") { tok = tok c; have = 1 } continue }
          if (c == "\047") { mode = "s"; have = 1; continue }
          if (c == "\"") { mode = "d"; have = 1; continue }
          if (c == "$" && substr(s, i + 1, 1) == "(") { i++; push("n"); continue }
          if (c == "`") { if (sp && (sm[sp] == "d`" || sm[sp] == "n`")) { m = sm[sp]; pop(); mode = substr(m, 1, 1) } else push("n`"); continue }
          if (c == ")") { if (sp && (sm[sp] == "d" || sm[sp] == "n")) pop(); else cmd_end(); continue }
          if (c == ";" || c == "&" || c == "|" || c == "(" || c == "\n") { cmd_end(); continue }
          if (c == " " || c == "\t") { tok_end(); continue }
          if (c == "#" && !have) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
          tok = tok c; have = 1
        }
        cmd_end() }'
  }

  # 3. Look at one simple command (words in the array w). Unwraps env/command/sudo/timeout/xargs/…,
  #    follows `cd`, re-reads `bash -c "<string>"` and `eval`, then checks git / gh / npm-style runners.
  #    $dir is the folder the command runs in (changed by cd for the commands after it).
  dir="$CWD"; depth=0
  check_words() {
    local i=0 n=${#w[@]} p a sub opt gdir
    # Leading shell words and VAR=value assignments.
    while [ $i -lt $n ]; do
      case "${w[$i]}" in '!'|'{'|'}'|then|do|else|elif|if|while|until|[A-Za-z_]*=*) i=$((i + 1)) ;; *) break ;; esac
    done
    # Wrappers that run the rest of the line as a command.
    while [ $i -lt $n ]; do
      p="${w[$i]##*/}"
      case "$p" in
        env|command|builtin|exec|nohup|nice|time|sudo|doas|timeout|gtimeout|xargs|caffeinate)
          i=$((i + 1))
          while [ $i -lt $n ]; do
            a="${w[$i]}"
            case "$p:$a" in
              *:--) i=$((i + 1)); break ;;
              env:-u|env:-C|env:-P|env:-S|sudo:-u|sudo:-g|sudo:-C|doas:-u|nice:-n|xargs:-I|xargs:-n|xargs:-L|xargs:-P|xargs:-d|xargs:-E|xargs:-s|timeout:-s|timeout:-k|gtimeout:-s|gtimeout:-k) i=$((i + 2)) ;;
              *:-*) i=$((i + 1)) ;;
              *:[A-Za-z_]*=*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          # timeout's first operand is the duration.
          case "$p" in timeout|gtimeout) i=$((i + 1)) ;; esac ;;
        *) break ;;
      esac
    done
    [ $i -lt $n ] || return 0
    p="${w[$i]##*/}"
    case "$p" in
      cd|pushd)
        a="${w[$((i + 1))]:-~}"; case "$a" in -*) a="${w[$((i + 2))]:-~}" ;; esac
        dir="$(abs_dir "$dir" "$a")" ;;
      bash|sh|zsh|dash|ksh)
        local j=$((i + 1))
        while [ $j -lt $n ]; do
          case "${w[$j]}" in --*) j=$((j + 1)) ;; -*c*) [ $((j + 1)) -lt $n ] && scan "${w[$((j + 1))]}"; break ;; -*) j=$((j + 1)) ;; *) break ;; esac
        done ;;
      eval) scan "${w[*]:$((i + 1))}" ;;
      git)
        gdir="$dir"; i=$((i + 1))
        while [ $i -lt $n ]; do
          a="${w[$i]}"
          case "$a" in
            -C) gdir="$(abs_dir "$gdir" "${w[$((i + 1))]:-.}")"; i=$((i + 2)) ;;
            -c|--git-dir|--work-tree|--namespace|--exec-path|--config-env|--super-prefix) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        sub="${w[$i]:-}"
        case "$GATED_GIT" in *" $sub "*) [ -n "$sub" ] && add_target "$gdir" "git $sub" ;; esac ;;
      gh)
        local repo_flag="" rest=() j=$((i + 1))
        while [ $j -lt $n ]; do
          a="${w[$j]}"
          case "$a" in -R|--repo) repo_flag=1; j=$((j + 2)); continue ;; --repo=*|-R?*) repo_flag=1 ;; *) rest+=("$a") ;; esac
          j=$((j + 1))
        done
        # gh [flags] pr [flags] <subcommand>: the first two words that aren't flags.
        local words=() x
        for x in ${rest[@]+"${rest[@]}"}; do case "$x" in -*) ;; *) words+=("$x") ;; esac; done
        if [ "${words[0]:-}" = "pr" ]; then
          sub="${words[1]:-}"
          case "$GATED_GH_PR" in *" $sub "*)
            [ -n "$sub" ] || return 0
            # -R/--repo points gh at a repository by name; the hook can't tell which local checkout
            # (and so which approval) that is. Refuse rather than guess.
            [ -n "$repo_flag" ] && deny "human-gate: \"gh pr $sub\" with -R/--repo names the target repository by name, so the hook can't match it to an approval. Ask the human; when they agree, run it from inside that repository's folder without -R."
            add_target "$dir" "gh pr $sub" ;;
          esac
        fi ;;
      npm|pnpm|yarn|bun)
        # Skip options (and the ones that take a value), then: [run|run-script] <script>.
        local j=$((i + 1)) words=()
        while [ $j -lt $n ]; do
          a="${w[$j]}"
          case "$a" in
            --prefix|-C|--dir|--cwd|--workspace|-w|--filter|-F) j=$((j + 2)); continue ;;
            -*) ;;
            *) words+=("$a") ;;
          esac
          j=$((j + 1))
        done
        sub="${words[0]:-}"
        case "$sub" in run|run-script) sub="${words[1]:-}" ;; esac
        case "$GATED_SCRIPTS" in *" $sub "*) [ -n "$sub" ] && add_target "$dir" "$p run $sub" ;; esac ;;
    esac
  }
  scan() {
    depth=$((depth + 1))
    # bash -c "bash -c \"…\"" nesting is followed a few levels; deeper than that is refused as unreadable.
    [ $depth -gt 4 ] && deny "human-gate: the command nests shells too deeply to check. Write it plainly."
    local l
    while IFS= read -r l; do
      IFS=$'\037' read -r -a w <<< "$l"
      check_words
    done < <(split_commands "$1")
    depth=$((depth - 1))
  }
  scan "$CMD"
fi
[ -n "$targets" ] || exit 0

# --- Allowed only if that repo + branch was unlocked less than TTL_HOURS ago ---------------------
problems=""; ok_cmds=""
while IFS=$'\t' read -r tdir what; do
  [ -n "$tdir" ] || continue
  if ! k="$(key_for "$tdir" 2>&1)"; then
    problems+="- $what: can't tell which repository and branch it runs on ($k), so it is refused."$'\n'
    continue
  fi
  IFS=$'\t' read -r mark repo branch <<< "$k"
  if [ -f "$mark" ] && [ "$(head -n 1 "$mark")" = "$repo"$'\t'"$branch" ]; then
    now="$(date +%s)"; mt="$(stat -f %m "$mark" 2>/dev/null || stat -c %Y "$mark" 2>/dev/null || echo 0)"
    age_h=$(( (now - mt) / 3600 ))
    [ "$age_h" -lt "$TTL_HOURS" ] && continue
    problems+="- $what: the OK for branch $branch is ${age_h}h old (it lasts ${TTL_HOURS}h)."$'\n'
  else
    problems+="- $what: no OK yet for branch $branch."$'\n'
  fi
  top="$(git -C "$tdir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$tdir")"
  ok_cmds+="  cd '$top' && '$HOOK_DIR/human-ok.sh'"$'\n'
done <<< "$targets"
[ -n "$problems" ] || exit 0

deny "This needs the human's OK first:
${problems}Do this instead: give the human something they can try (a URL, a build, a summary) and wait for their OK. Do not retry this command another way.
When they agree, they run this in their own terminal (it unlocks that repository + branch for ${TTL_HOURS}h):
$(printf '%s' "$ok_cmds" | awk '!s[$0]++')"
