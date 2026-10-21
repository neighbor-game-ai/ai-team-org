# hooks

A helper that catches the common slips around the few actions that must wait for your OK. Written rules get broken now and then in long sessions; a hook is checked before every command it is set up for.

- `human-gate.sh` — PreToolUse hook. Refuses `git push`, `gh pr create|new|ready|merge` and `npm|pnpm|yarn|bun run check:all` until you have said OK for that repository + branch. Also refuses writes into its unlock folder and running `human-ok.sh`.
- `human-ok.sh` — your unlock switch. Run it yourself in a terminal; it refuses to run without one.
- `test-human-gate.sh` — regression tests: feeds the hook JSON and checks allow/refuse. Nothing is pushed. `bash hooks/test-human-gate.sh`

## What it catches, and what it doesn't

It reads the command the way a shell splits it (quotes, `;` `&&` `|`, `$(…)`, backticks), so these are all caught:
`git push` · `git -C dir push` · `git -c k=v push` · `env git push` · `/usr/bin/git push` · `FOO=1 git push` · `timeout 60 git push` · `bash -c "git push"` · `cd other-repo && gh pr create` · `npm --prefix web run check:all`
— while `echo "gh pr create"`, `grep "git push" notes.md` and `cat scripts/check-all.sh` still run.

It is **not** a security boundary. It does not see a push hidden in a variable (`$G push`), an alias, a script that pushes internally, or a tool your matcher doesn't name. Anything running as your user can write the unlock file, and a program that fakes a terminal can run `human-ok.sh`. It stops habits and slips; the written rule every member gets does the rest: *if a command is blocked, don't try another way — report it.*

If `jq` is missing or the hook can't read its input, it refuses every command it sees and says why, rather than letting everything through.

## Install

Do this once per machine; `JOIN.md` step 3 walks a session through it.

1. Copy `human-gate.sh` and `human-ok.sh` **together** into one stable folder, e.g. `~/.claude/hooks/`, and `chmod +x` both (`human-ok.sh` calls `human-gate.sh` next to it). Install `jq` (`brew install jq`, `apt install jq`).
2. Add the hook to a settings file that **every session you want covered** reads:
   - `<config folder>/settings.json` for each account — `~/.claude/settings.json` for the default account, `~/.claude-team/settings.json` for `CLAUDE_CONFIG_DIR=~/.claude-team`. A hook in one config folder does nothing for sessions started with another (members run with `MEMBER_CONFIG_DIR`).
   - or `.claude/settings.json` inside a work repository, committed — then it applies to every account working in that repo.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/human-gate.sh" }]
      }
    ]
  }
}
```

   `Bash` is the minimum. `Write|Edit|MultiEdit` add a check that the file tools don't write into the unlock folder. If a GitHub MCP server can open or merge pull requests, add its tools to the matcher too — they are then refused until the OK, like `gh pr create`:

```json
"matcher": "Bash|Write|Edit|MultiEdit|mcp__github__create_pull_request|mcp__github__merge_pull_request"
```

   Tool names depend on the server's name; `/mcp` in Claude Code lists them.

3. Check it: start a new session with that account and ask it to run `gh pr create --help`. It must be refused with a message telling it to wait for your OK. If it runs, the hook is not in a settings file that session reads.
4. When you agree with a change: open your own terminal **in the checkout you looked at** and run `~/.claude/hooks/human-ok.sh` (the refusal message prints the exact line). It unlocks that repository + branch for 6 hours (`HUMAN_OK_TTL_HOURS`); `--revoke` locks it again. Unlocks live in `~/.claude/human-ok/` (`HUMAN_OK_DIR`).

The hook adds about 0.1 s to each command it checks (measured on a laptop).

## Change what is gated

Edit `GATED_GIT`, `GATED_GH_PR` and `GATED_SCRIPTS` at the top of `human-gate.sh`, then run `bash hooks/test-human-gate.sh`. Keep the lists short: every gate is a stop you clear by hand.
