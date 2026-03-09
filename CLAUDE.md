# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.

The static task plan is in `prd.json`.
The dynamic loop lifecycle is in the local state file at `$RALPH_STATE_FILE`.
The required validation gate for every story is `$RALPH_FAST_CI_COMMAND` when it is set. If it is empty, use the repository's default CI, test, or typecheck command set.

## Your Task

1. Read `prd.json`.
2. Read `progress.txt` and check `## Codebase Patterns` first.
3. Read the local state file from `$RALPH_STATE_FILE`.
4. Pick the highest-priority story whose state is not `merged`.
5. Resume that story on its own branch or create the branch from the story `branchName`.
6. Implement only that single story.
7. Run only `$RALPH_FAST_CI_COMMAND` as the required merge gate when it is set, unless the PRD explicitly requires extra checks. If it is empty, run the repository's default CI, test, or typecheck command set.
8. Open or update a PR to `main` when the branch is ready.
9. Update the local state file for the story.
10. Append progress to `progress.txt`.

## State Rules

- Do not use `prd.json` for runtime bookkeeping.
- Use `$RALPH_STATE_FILE` as the source of truth for branch, PR, validation, and merge status.
- Set a story to `ready_to_merge` only when the branch tip is pushed, the PR exists, and the required validation gate passed on that branch tip.

## Progress Format

Append to `progress.txt`:

```text
## [Date/Time] - [Story ID]
Session: Claude Code
Branch: [branch name]
PR: [url or "not opened"]
Merge: [sha or "not merged"]
- What was implemented
- Validation: [command] -> [result]
- Learnings for future iterations:
  - reusable pattern
  - blocker or gotcha
---
```

If you discover a reusable pattern, add it under `## Codebase Patterns` at the top of `progress.txt`.

## Important

- Work on one story per iteration.
- Keep changes focused.
- Do not run heavyweight repo-default CI when `$RALPH_FAST_CI_COMMAND` is provided.
- If `$RALPH_FAST_CI_COMMAND` is empty, choose the normal repository validation path and keep it focused on the default merge gate.
- If a story is blocked, record the exact blocker in the local state file and in `progress.txt`.
- If all stories in `$RALPH_STATE_FILE` are `merged`, reply with:

<promise>COMPLETE</promise>
