Status: active
Owner: you@example.com / Example lead 1
Waiting on: -

# Brief: show a clear message when a reset link has expired

The first 3 lines above are the task's state. Only those lines change as the task moves
(active → waiting → done); everything from here down is the brief for the member.

## Background
- Reset links expire after 30 minutes (decisions.md, 2026-01-12). Today an expired link shows a blank page.

## Do
1. Show "This link has expired" with a button that sends a new link.
2. Add a test for an expired link.

## Don't
- Change how long links last.

## Report
What changed, the commit, how you checked it, anything left.
