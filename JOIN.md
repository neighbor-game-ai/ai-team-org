# Join the org

**The one line to paste into Claude Code:** `Read JOIN.md in this repo and do what it says.`

This works for every case — the very first setup, a new person, someone taking over, someone joining in parallel.

You (the session reading this) do steps 1–7 in order. Ask the human only what you can't read from files: which account they use, which team they are taking, and — on a first setup — which repository the team works on. Talk to them in the language they write in. Open CONVENTIONS.md only for the part you need. In commands, keep paths in double quotes (`"$WORKTREE_ROOT/…"`), so a folder with a space in its name still works.

## 1. Find the account

Every Claude Code account on a machine has a **config folder**, and its login file sits in a fixed place relative to it:

| Config folder | Login file | How sessions use it |
|---|---|---|
| `~/.claude` (the default account) | `~/.claude.json` — *next to* the folder, not inside | `claude` |
| any other folder, e.g. `~/.claude-team` | `~/.claude-team/.claude.json` — inside | `CLAUDE_CONFIG_DIR=~/.claude-team claude` |

List them with the account each is logged in to:

```bash
for f in ~/.claude.json ~/.claude-*/.claude.json; do
  [ -f "$f" ] || continue
  case "$f" in "$HOME/.claude.json") d="$HOME/.claude" ;; *) d="$(dirname "$f")" ;; esac
  echo "$d: $(jq -r '.oauthAccount.emailAddress // "(not logged in)"' "$f" 2>/dev/null || echo '(cannot read: is jq installed?)')"
done
```

Show the list and ask once: "Which of these is the account you are using?" Call the answer `<account>` and its folder `<config folder>`.

- **No `jq`:** the lines say "cannot read". Ask the human to install it (`brew install jq` / `apt install jq`) — the hook in step 3 needs it too. Until then, ask them to type the config folder and the account.
- **The folder is somewhere else** (another name, another disk): ask the human to type its path and use it as is.
- **Not in the list / not logged in:** ask the human to log in once in a terminal — `CLAUDE_CONFIG_DIR=~/.claude-<name> claude`, then `/login`, then exit — and use that folder. You do not log in for them.

## 2. Set the member account

- No `org.env` yet (first setup): `cp org.env.example org.env`, set `MEMBER_CONFIG_DIR=<config folder>` and `WORKTREE_ROOT` (default `~/worktrees`). This is the one place members' account is decided.
- `org.env` exists and someone else uses it: **don't edit it.** Put `MEMBER_CONFIG_DIR="<config folder>"` in front of every `scripts/member-*.sh` command instead.

## 3. Install the hook (once per config folder)

The hook (`hooks/human-gate.sh`) catches pull requests, pushes and the full test gate before the human's OK. It only works for sessions whose settings name it, so check both the lead's `<config folder>` and the member account's folder (`MEMBER_CONFIG_DIR`):

```bash
grep -l human-gate.sh "<config folder>/settings.json" 2>/dev/null || echo "not installed for <config folder>"
```

If it is missing, follow `hooks/README.md` → Install, steps 1–2. Show the human the settings change before you make it — it is their settings file. Then check the script itself once (nothing is run; the hook only judges the JSON):

```bash
printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create --help"},"cwd":"%s"}' "$PWD" | ~/.claude/hooks/human-gate.sh; echo "exit $?"   # must print a refusal and "exit 2"
```

Settings are read when a session starts, so the real test is in step 7: every lead's first command is `gh pr create --help`, and it must be refused.

## 4. Look at the current state

```bash
scripts/status.sh
```

Teams, owners, open tasks, running members, questions waiting on the human, latest decisions — read from the files, without an LLM. Don't look for a handoff note or read old conversations; this is the state. Read the **Warnings** section: a task listed as `unknown` or members that "cannot check" are real gaps, not noise (the script exits 1 when there are warnings).

## 5. First setup: one team, one task

Only if `teams.tsv` has nothing but the example row. Ask the human which repository the team works on (a local clone) and its main branch. In this example the clone is `~/src/shop`, the main branch `main`, and the team `web`; use the human's answers instead.

```bash
. ./org.env                                                     # WORKTREE_ROOT from step 2
git -C ~/src/shop worktree add -b team/web "$WORKTREE_ROOT/web-lead" main
( cd "$WORKTREE_ROOT/web-lead" &&
  mkdir -p docs/teams/web/tasks &&
  cp "<path to this repo>/docs/teams/example.md" docs/teams/web.md &&      # then rewrite its 4 points for this team
  printf '# web — decisions by the human (newest at the bottom; never delete or reorder)\n\n' > docs/teams/web/decisions.md &&
  git add docs/teams && git commit -m "web team: charter and decisions" )
```

Then the name tag (step 6) is this row in `teams.tsv` (tab-separated): `web  Web lead 1  <account>  ~/worktrees/web-lead  team/web  docs/teams/web.md`. Remove the example row once your team's row is in.

From now on **you are the manager** — the one session that owns `teams.tsv` and talks to the human about the whole org (CONVENTIONS.md §0). Stay in this repo. The lead you start in step 7 writes the first task's brief and starts its member (CONVENTIONS.md §6). A later manager joins with the same one line and takes over as in step 6.

## 6. Put up your name tag (`teams.tsv`)

Ask: "Which team will you take — as a replacement, or in parallel with the current lead?" Then, per team:

- **New team**: add a row (CONVENTIONS.md §5) and create its charter, decisions file and `tasks/` folder in its workdir as in step 5.
- **Parallel**: add another row for the same team with a different session name and your own workdir and branch:
  `git -C "<team workdir>" worktree add -b "<team>/<short name>" "$WORKTREE_ROOT/<team>-<short name>" "<team branch>"`
- **Replacement**: two sessions must never write to one workdir at the same time, so go in this order:
  1. **Stop new work.** Tell the previous lead (or ask the human to tell it): "Your successor is starting. Don't start new work or members. Write down what exists only in this conversation (see *Leaving*), commit, and stop."
  2. **Its notes are in.** `git -C "<workdir>" status --short` is empty and `git -C "<workdir>" log -3` shows its last commit. If it can't write any more, ask the human for the missing decisions and add them yourself after 3.
  3. **It has stopped.** The human confirms the session is closed (or `CLAUDE_CONFIG_DIR="<its config folder>" claude agents` no longer shows it working). Members it started may keep running in their own worktrees — leave them; read their reports with `scripts/member-status.sh "<name>" "<their config folder>"`.
  4. **Swap the name tag.** In the team's row, change the session name to a new one and the account to `<account>`. Keep the workdir and branch.
  5. **Start the successor** (step 7).

  **If you can't confirm 3**, don't share the workdir: create a new one from the team branch (`git -C "<workdir>" worktree add -b "<team>/lead-2" "$WORKTREE_ROOT/<team>-lead-2" "<team branch>"`), put it in the row as workdir and branch, and merge the old branch into it once the old session has stopped.
- Workdirs always go under `WORKTREE_ROOT`, never inside `.claude/worktrees/`.
- Commit `teams.tsv`, then run `scripts/status.sh <team>` and check your row appears without warnings.

## 7. Start one lead session per team

For each team, start a new Claude Code session **in that team's workdir, with the account's config folder** (`CLAUDE_CONFIG_DIR="<config folder>" claude`, or plain `claude` for `~/.claude`), and give it the prompt below (fill in the `<…>`). If you can start sessions yourself, do it; otherwise print one ready-to-paste block per team and tell the human: "Open a new terminal in each folder, start Claude Code as shown, and paste its block."

> You are "<session name>", the lead of the <team> team (account <account>). <Replacement: "You take over from the previous lead." / Parallel: "You work alongside "<other session name>"; you own <scope>. Don't touch their workdir or members.">. Your workdir is <workdir> (branch <branch>, yours only); you are already in it — do not create another worktree for yourself. First, run `gh pr create --help` once: it must be refused by the hook. If it runs, stop and tell the human the hook is not installed for this account. Then read: <workdir>/<charter> → <workdir>/docs/teams/<team>/decisions.md → `"<path to this repo>/scripts/status.sh" <team>` → "<path to this repo>/CONVENTIONS.md". You supervise only: plan, write briefs, start members exactly as in CONVENTIONS.md §6 (commit the brief in your workdir first, then create the member's worktree from that commit, then `"<path to this repo>/scripts/member-launch.sh"`), read their reports with `member-status.sh`, review and merge into your branch, and record decisions. Your copy of each task's first 3 lines is the one that counts. When the human decides something, add one line to decisions.md; when a task changes state, change only its first 3 lines; commit both. No pull requests or full test gate before the human's OK, no push, never retry a blocked command another way, never print keys.

## Leaving

Before you go, write down only what exists nowhere else: decisions that are only in the conversation → one line each in `decisions.md`; task states → their first 3 lines. Commit. Delete your row from `teams.tsv` (unless someone is taking it over). That is the whole handoff.
