# Conventions

One goal: anyone — a new person, a replacement, a fresh AI session — can join at any time and understand where things stand by reading the same few places. No handoff notes. `scripts/status.sh` reads only the formats below, so keep to them exactly.

## 0. Roles

| Role | How many | What it does | What it does not do |
|---|---|---|---|
| **You** (the human) | 1 | Decide. Say OK. Talk to the manager and the leads. | Write handoff notes. |
| **Manager** | 1 session | Owns `teams.tsv`, merges team branches, releases, reports to you. Runs members for work that has no team. | Hand-edit status. |
| **Lead** | 1 session per team | Plans, writes briefs, starts members, reviews and merges their work into the team branch, records your decisions. **Supervises only.** | Write the code, the copy, the research itself. |
| **Member** | as many as needed | Does one task from one brief in its own worktree (`claude --bg`), then reports. | Open PRs, push, talk to you directly. |

## 1. Decisions — `docs/teams/<team>/decisions.md`

- When you decide something, the session you told adds one line and commits: `- YYYY-MM-DD what was decided (short)`
- When a session asks you something and has no answer yet: `- OPEN YYYY-MM-DD the question (short)`. When you answer, rewrite that line as a decision.
- Never delete or reorder lines (newest at the bottom). A long reason goes in its own file; link to it.
- Only the owner in the team's **first** row of `teams.tsv` writes this file. A parallel session sends the decision to that owner, who adds the line — so there is never a second, diverging copy.

## 2. Tasks — `docs/teams/<team>/tasks/<task>.md`

The first 3 lines are the task's state; the brief starts on line 4:

```
Status: active | waiting | done
Owner: <account> / <session name>
Waiting on: <who, for what>   (or -)
```

- When the state changes, change only these lines and commit. Rewriting three lines costs almost nothing; rewriting a status page costs a lot and drifts.
- Exactly these three labels, and `Status` is exactly `active`, `waiting` or `done`. Anything else (a missing line, `Status: finished`) is listed by `status.sh` as `unknown` and named under Warnings — it is never dropped as done.
- The copy that counts is the one in the **lead's** workdir (the Owner's). A member doesn't change these lines; the lead does, in its own workdir, and keeps its version when it merges the member's branch.

## 3. Charter — `docs/teams/<team>.md`

Four points, short: what the team does · your decisions (a link to `decisions.md`, never a copy) · how members are started (a link to §6) · what it asks of other teams and what they ask of it. Example: `docs/teams/example.md`.

## 4. No "NOW" file, no handoff note

"Where things stand" is already in §1–§3: open and waiting work = task headers, decisions and open questions = `decisions.md`, roles = the charter, who is where = `teams.tsv`, running members = `claude agents`. Don't write a separate status file — it is the first thing to go stale. Why: `docs/WHY.md`.

## 5. Name tags — `teams.tsv`

- One row per lead session, tab-separated, no empty columns: `team · session name · account · workdir · branch · charter`
- Add your row **before** you start. Leave → delete your row. Take over → change the session name and account in the existing row.
- Working in parallel with someone on the same team → add a second row with your own session name, workdir and branch.

## 6. Starting members

In this order — the brief first, in the lead's workdir, so `status.sh` (which reads the lead's workdir) sees the task and the member starts from exactly that text:

1. In **your (the lead's) workdir**, write the brief as `docs/teams/<team>/tasks/<task>.md` (header from §2) **and commit it** on your team branch.
2. Create the member's worktree **from that commit**, always under `WORKTREE_ROOT` (never inside `.claude/worktrees/`, which the app may clean up):
   `git -C "<your workdir>" worktree add -b "<team>/<task>" "$WORKTREE_ROOT/<team>-<task>" HEAD`
3. `scripts/member-launch.sh "$WORKTREE_ROOT/<team>-<task>" "<member name>" docs/teams/<team>/tasks/<task>.md`
   The rules in §7 are added to every member's prompt automatically.
4. Progress: `scripts/status.sh`. Final report: `scripts/member-status.sh "<part of name>"`. When the state changes, edit the first 3 lines in your workdir and commit (§2).
5. A new account may stop on "Workspace not trusted" the first time. Open that folder once yourself with `CLAUDE_CONFIG_DIR=<folder> claude` (plain `claude` for the default `~/.claude`) and trust it — don't edit config files to skip it.

All members run on one account, set once in `org.env` (`MEMBER_CONFIG_DIR`). Someone else working in parallel puts `MEMBER_CONFIG_DIR=<their folder>` in front of the command instead of editing the file.

## 7. Rules for every session

- No pull request and no full test gate before your OK. Don't push. (`hooks/human-gate.sh` catches the usual ways of writing these; it is a safety net, not the rule itself.)
- If a command is blocked, don't try it another way. Report it.
- Don't create worktrees on your own; members start inside theirs.
- Never throw away uncommitted changes without asking.
- Never print or write keys, tokens or passwords.
- Members use a headless browser only — never your own browser.
- Nothing public names a person or a company unless you said so.
