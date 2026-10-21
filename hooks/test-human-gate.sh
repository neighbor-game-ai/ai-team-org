#!/usr/bin/env bash
# test-human-gate.sh — regression tests for human-gate.sh.
#
# Each case feeds the hook the same JSON Claude Code would send and checks only the decision
# (exit 0 = allowed, exit 2 = refused). Nothing is executed: no push, no pull request.
# Everything happens in a temporary folder with its own unlock folder (HUMAN_OK_DIR).
#
# Why these cases: each "refuse" below is a way of writing a gated command that an earlier version
# let through, and each "allow" is a harmless command that an earlier version refused.
#
# Usage: bash hooks/test-human-gate.sh      (needs git and jq; exit 1 if any case fails)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/human-gate.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/human-gate-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
export HUMAN_OK_DIR="$tmp/ok" HUMAN_OK_TTL_HOURS=6
pass=0; fail=0

# Two repositories with the same branch name, a worktree, and a detached checkout.
mkrepo() { git init -q -b main "$1" && git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; }
A="$tmp/repo a"; B="$tmp/repo-b"           # "repo a" has a space on purpose
mkrepo "$A"; mkrepo "$B"
git -C "$A" checkout -q -b feature/x; git -C "$B" checkout -q -b feature/x
git -C "$A" branch -q a/b; git -C "$A" branch -q a__b
git -C "$A" worktree add -q "$tmp/wt-ab" a/b
git -C "$A" worktree add -q "$tmp/wt-a__b" a__b
git -C "$A" worktree add -q --detach "$tmp/wt-detached"

json_str() { printf '%s' "$1" | awk 'BEGIN { ORS = "" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); if (NR > 1) print "\\n"; print }'; }
bash_input() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$(json_str "$1")" "$(json_str "$2")"; }

# expect <allow|refuse> <cwd> <command>       (Bash tool)
# expect_raw <allow|refuse> <label> <json>   (any input)
expect_raw() {
  local want="$1" label="$2" input="$3" rc got
  printf '%s' "$input" | ${GATE_RUNNER:-bash} "$gate" >/dev/null 2>"$tmp/err"; rc=$?
  case "$rc" in 0) got=allow ;; 2) got=refuse ;; *) got="exit $rc" ;; esac
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL ($got, wanted $want): $label"; sed 's/^/    /' "$tmp/err"; fi
}
expect() { expect_raw "$1" "$3   [in ${2##*/}]" "$(bash_input "$3" "$2")"; }
approve() { local k; k="$(bash "$gate" --key "$1")" || return 1; IFS=$'\t' read -r mark repo branch <<< "$k"; mkdir -p "$HUMAN_OK_DIR"; printf '%s\t%s\n' "$repo" "$branch" > "$mark"; }

echo "== no OK yet: gated commands, however they are written"
for c in 'git push' 'git push origin HEAD' "git -C '$A' push" 'git -c color.ui=false push' 'git --no-pager push' \
         'env git push' 'env -u FOO GIT_TRACE=0 git push' '/usr/bin/git push' 'FOO=1 git push' '"git" push' 'g\it push' \
         'command git push' 'nohup git push' 'timeout 60 git push' 'xargs -n 1 git push' 'sudo -u me git push' \
         'git status && git push' 'git status; git push' 'echo x | git push' '(git push)' 'echo $(git push)' 'echo "$(git push)"' 'echo `git push`' \
         'bash -c "git push"' "sh -lc 'git push origin main'" 'eval git push' \
         'gh pr create --fill' 'gh pr new' 'gh pr ready 12' 'gh pr merge 12 --squash' 'gh --repo-dummy-flag pr create' \
         'npm run check:all' 'npm run-script check:all' 'npm --prefix web run check:all' 'npm -C web run check:all' \
         'pnpm check:all' 'pnpm --filter web run check:all' 'yarn check:all' 'yarn --cwd web check:all' 'bun run check:all'; do
  expect refuse "$A" "$c"
done

echo "== harmless commands that mention the words"
for c in 'echo "gh pr create"' "echo 'git push'" 'grep -rn "git push" .' 'cat scripts/check-all.sh' 'git commit -m "do not git push yet"' \
         'git status' 'git log --oneline -3' 'gh pr view 12' 'gh pr list' 'npm run test' 'npm run check' 'ls -la' '' \
         'echo "$(date) gh pr create"' 'printf "%s\n" "npm run check:all"' '# git push'; do
  expect allow "$A" "$c"
done

echo "== the OK is for one repository + branch"
approve "$A"
expect allow  "$A" 'git push'
expect allow  "$A" 'gh pr create --fill'
expect allow  "$A" 'npm --prefix web run check:all'
expect refuse "$B" 'git push'                               # same branch name, other repo
expect refuse "$A" "git -C '$B' push"                       # runs in the other repo
expect refuse "$A" "cd '$B' && gh pr create"                # cd first, then the PR
expect allow  "$B" "cd '$A' && git push"                    # cd into the approved one
expect refuse "$A" 'gh pr create -R someone/else'           # target named by -R: can't match it
expect refuse "$tmp/wt-ab" 'git push'                       # other branch of the same repo
approve "$tmp/wt-ab"
expect allow  "$tmp/wt-ab" 'git push'
expect refuse "$tmp/wt-a__b" 'git push'                     # a/b and a__b don't collide
expect refuse "$tmp/wt-detached" 'git push'                 # detached HEAD: no branch to match
expect refuse "$tmp" 'git push'                             # not a repository at all
k="$(bash "$gate" --key "$A")"; mark="${k%%$'\t'*}"
touch -t 202001010000 "$mark"
expect refuse "$A" 'git push'                               # expired
printf 'something else\n' > "$mark"
expect refuse "$A" 'git push'                               # file content doesn't match repo + branch

echo "== Claude can't unlock itself"
for c in "touch '$HUMAN_OK_DIR/x'" "echo ok > ~/.claude/human-ok/x" 'hooks/human-ok.sh' 'bash hooks/human-ok.sh' \
         './human-ok.sh' 'cd /tmp && ~/.claude/hooks/human-ok.sh'; do
  expect refuse "$A" "$c"
done
expect allow "$A" 'grep -n human-ok.sh README.md'
expect_raw refuse "Write into the unlock folder" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(json_str "$HUMAN_OK_DIR/x")\",\"content\":\"\"},\"cwd\":\"$(json_str "$A")\"}"
expect_raw allow  "Write elsewhere" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(json_str "$A/notes.md")\",\"content\":\"\"},\"cwd\":\"$(json_str "$A")\"}"

echo "== MCP tools named in the matcher"
expect_raw refuse "MCP pull request, no OK" "{\"tool_name\":\"mcp__github__create_pull_request\",\"tool_input\":{},\"cwd\":\"$(json_str "$B")\"}"
approve "$B"
expect_raw allow  "MCP pull request, OK given" "{\"tool_name\":\"mcp__github__create_pull_request\",\"tool_input\":{},\"cwd\":\"$(json_str "$B")\"}"

echo "== unreadable input or no jq: refuse, don't wave through"
expect_raw refuse "not JSON" 'git push'
expect_raw refuse "empty input" ''
nojq="$tmp/nojq"; mkdir -p "$nojq"
for t in bash git awk sed grep cat head date stat shasum sha256sum cksum cut tr dirname basename env mktemp; do
  p="$(type -P "$t" 2>/dev/null)" && ln -s "$p" "$nojq/$t"
done
GATE_RUNNER="env PATH=$nojq bash" expect refuse "$A" 'ls'
GATE_RUNNER="env PATH=$nojq bash" expect refuse "$A" 'git push'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
