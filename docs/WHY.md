# Why it is built this way

[日本語](WHY.ja.md)

Each rule here replaced something that was tried first and failed. If you change a rule, read why it exists before you do.

## Why there is no "NOW" or status document

The first version had a `NOW.md` per team: "here is where we are". It was rewritten at every milestone and handed to every new session. Three things went wrong:

1. **It went stale between rewrites.** Sessions update it at milestones, but work changes all the time. The next session trusted it completely, including the parts that were no longer true.
2. **It grew.** Each writer added what they thought mattered and removed little. Reading it at the start of a session cost more and more tokens, and the important line was somewhere in the middle.
3. **It was a second copy.** Decisions were in the conversation, in the NOW file, and sometimes in the charter — and the copies disagreed.

So the state now lives only where the work itself changes it: a decision is one line in `decisions.md`, a task's state is the first three lines of its file, who is where is a row in `teams.tsv`. There is nothing separate to keep in sync, and nothing to hand over.

## Why the first three lines of each task

- **Cheap to update.** Changing state means editing one to three lines and committing. Nobody puts it off.
- **Readable by a script.** A fixed position and fixed labels (`Status:` / `Owner:` / `Waiting on:`) mean `status.sh` can read them without understanding them.
- **One file, two jobs.** The same file is the member's brief (line 4 onwards) and the task's state (lines 1–3), so they can't drift apart.
- **Broken headers stay visible.** A file whose header is missing or whose `Status` isn't `active`/`waiting`/`done` is listed as `unknown` and named under Warnings. The first version counted it as done, which looked tidy and hid exactly the task nobody was watching.

## Why the status is not made by an LLM

It would be easy to ask a model "read everything and tell me where we are". We don't, because:

- **It differs between runs.** Two people asking the same question should see the same answer.
- **It costs tokens every time**, and status is the thing you check most often.
- **It is wrong convincingly.** A model fills gaps with something plausible. A script reading fixed formats is wrong only in visible ways ("decisions.md not found"), which tells you what to fix.
- **It is quick.** About half a second for a small org (measured, including asking Claude Code which members run), so you check more often.

## Why leads only supervise

A lead that writes code itself quickly loses the overview: its context fills with diffs and error messages, it forgets what other members are doing, and when its context runs out you lose the plan along with it. A lead that only plans, writes briefs, starts members, reviews and records decisions:

- stays useful for much longer on one context,
- can be replaced cleanly — everything it knows is already in the three kinds of files,
- runs several members in parallel instead of doing one thing at a time.

The work itself — code, copy, research, video — goes to members, one brief each, each in its own worktree.

## Why rules are hooks, not text

"Open a pull request only after I've tried it and said OK" was written into the instructions, then into memory, then again more strongly. It was broken all three times. Not out of disobedience: in a long session, a habit ("the work is done, so open the PR") wins over a rule read hours ago.

A hook (`hooks/human-gate.sh`) is checked before every shell command (and any tool you add to its matcher), so the usual slip gets caught however long the session is. It is a safety net, not a lock: it catches the common ways of writing these commands, not every possible one (`hooks/README.md` lists what it misses). Three details matter:

- **The unlock needs a real terminal.** `human-ok.sh` refuses to run without an interactive terminal, which Claude Code's tools don't have, and the hook refuses commands that would write the unlock file. So the session doesn't approve itself by habit or by accident.
- **The unlock is for one repository + branch.** A branch name alone ("main", "fix/login") exists in many repositories; the first version's OK leaked into all of them.
- **The unlock expires** (6 hours by default). An OK is for the change you looked at, not for whatever the branch becomes later.

Hand in hand with the hook goes one written rule every member gets: *if a command is blocked, don't try it another way — report it.* Without it, a blocked session tends to find a different command that does the same thing.

Use hooks for the few things that cost real time or money if done too early. Every gate is a stop you clear by hand, so keep the list short.

## Why worktrees live in one fixed place

Each lead and each member works in its own git worktree, so nobody overwrites anybody. At first, worktrees were created inside the app's own folder (`.claude/worktrees/`). The app's automatic cleanup removed some of them — uncommitted work included.

Now every worktree goes under one root you choose (`WORKTREE_ROOT`, outside `.claude/`), where that cleanup doesn't reach. `member-launch.sh` refuses any other location and `status.sh` warns about it. As a side effect, `ls "$WORKTREE_ROOT"` shows you everything in progress.

## Why the member account is decided in one place

Members can run on a different Claude account from the session that starts them, and different people may have different accounts. When the account was chosen per launch, members ended up on the wrong one: out of quota, missing connections, or invisible to the person checking on them — and it only showed up much later.

So there is one setting (`MEMBER_CONFIG_DIR` in `org.env`). `member-launch.sh` refuses to start without it and prints the account before every launch. A second person working in parallel puts their own folder in front of the command for that one call, instead of editing the shared setting under someone else's feet.

## Why the brief must be committed before a member starts

A member that starts from an uncommitted brief may read a version the lead later changes; the lead then reviews against a text the member never saw. A committed brief is the same text for the member, the lead and `status.sh`.

It is committed in the **lead's** workdir, and the member's worktree is created from that commit. When the brief was written only in the member's worktree, `status.sh` — which reads the lead's workdir — never saw the task, and it vanished from the list.

## Why one line to join

Every handoff note we wrote missed something — a worktree path, a branch, which account, a member still running. Instead of writing better notes, joining became a procedure (`JOIN.md`) that reads the facts from where they already are. The only thing anyone needs to pass on is one line: *Read JOIN.md in this repo and do what it says.*
