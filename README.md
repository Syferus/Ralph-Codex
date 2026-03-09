# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Amp](https://ampcode.com), [Claude Code](https://docs.anthropic.com/en/docs/claude-code), or Codex CLI) repeatedly until every planned story has been turned into a merged PR. Each iteration is a fresh instance with clean context. Static task definition lives in `prd.json`; runtime lifecycle is tracked in a local state file under `.git`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- One of the following AI coding tools installed and authenticated:
  - [Amp CLI](https://ampcode.com) (default)
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
  - Codex CLI (`npm install -g @openai/codex`)
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Setup

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/

# Copy the prompt template for your AI tool of choice:
cp /path/to/ralph/prompt.md scripts/ralph/prompt.md    # For Amp
# OR
cp /path/to/ralph/CLAUDE.md scripts/ralph/CLAUDE.md    # For Claude Code
# OR
cp /path/to/ralph/CODEX.md scripts/ralph/CODEX.md      # For Codex CLI

chmod +x scripts/ralph/ralph.sh
```

### Option 2: Install skills globally (Amp)

Copy the skills to your Amp or Claude config for use across all projects:

For AMP
```bash
cp -r skills/prd ~/.config/amp/skills/
cp -r skills/ralph ~/.config/amp/skills/
```

For Claude Code (manual)
```bash
cp -r skills/prd ~/.claude/skills/
cp -r skills/ralph ~/.claude/skills/
```

### Option 3: Use as Claude Code Marketplace

Add the Ralph marketplace to Claude Code:

```bash
/plugin marketplace add snarktank/ralph
```

Then install the skills:

```bash
/plugin install ralph-skills@ralph-marketplace
```

Available skills after installation:
- `/prd` - Generate Product Requirements Documents
- `/ralph` - Convert PRDs to prd.json format

Skills are automatically invoked when you ask Claude to:
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"

### Configure Amp auto-handoff (recommended)

Add to `~/.config/amp/settings.json`:

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

This enables automatic handoff when context fills up, allowing Ralph to handle large stories that exceed a single context window.

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

Use the Ralph skill to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.

### 2.5. Add the loop contract

You can define a lightweight merge gate:

```json
{
  "loopConfig": {
    "fastCiCommand": "./scripts/ci_fast.sh",
    "mergeMethod": "merge"
  }
}
```

If `loopConfig.fastCiCommand` is present, Ralph uses it as the required validation gate for story branches. This should be the fast CI path, not a full release-grade CI run.

If `loopConfig.fastCiCommand` is omitted, Ralph falls back to the repository's default merge gate and tells the agent to run the normal CI, test, or typecheck command set for that codebase.

### 3. Run Ralph

```bash
# Using Amp (default)
./scripts/ralph/ralph.sh [max_iterations]

# Using Claude Code
./scripts/ralph/ralph.sh --tool claude [max_iterations]

# Using Codex CLI
./scripts/ralph/ralph.sh --tool codex [max_iterations]
```

Default is 10 iterations. Use `--tool amp`, `--tool claude`, or `--tool codex` to select your AI coding tool.

Ralph will:
1. Initialize or update a local runtime state file under `.git/ralph-state.json`
2. Pick the highest-priority story whose runtime state is not `merged`
3. Implement or resume that story on its own branch
4. Run the configured fast CI command, or fall back to the repository's default merge gate
5. Push the branch and open or update a PR to `main`
6. Mark the story `ready_to_merge` in local state when the branch tip is validated
7. Auto-merge the PR when it is mergeable
8. Sync merged PRs back into local state
9. Append learnings to `progress.txt`
10. Repeat until all stories are merged or max iterations reached

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | The bash loop that spawns fresh AI instances (supports `--tool amp`, `--tool claude`, or `--tool codex`) |
| `prompt.md` | Prompt template for Amp |
| `CLAUDE.md` | Prompt template for Claude Code |
| `CODEX.md` | Prompt template for Codex CLI |
| `prd.json` | Static task list plus optional `loopConfig.fastCiCommand` |
| `.git/ralph-state.json` | Local runtime state (`pending`, `in_progress`, `blocked`, `in_review`, `ready_to_merge`, `merged`) |
| `prd.json.example` | Example PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `skills/prd/` | Skill for generating PRDs (works with Amp and Claude Code) |
| `skills/ralph/` | Skill for converting PRDs to JSON (works with Amp and Claude Code) |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (Amp, Claude Code, or Codex CLI) with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (static stories and optional fast-CI contract)
- `.git/ralph-state.json` (runtime lifecycle and PR metadata)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because AI coding tools automatically read these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Validation Gate

If you provide `loopConfig.fastCiCommand`, the base Ralph loop uses that lightweight gate as the default merge gate for every story branch.

If you do not provide `loopConfig.fastCiCommand`, the base Ralph loop falls back to the repository's normal merge gate.

If you want slower or broader validation, keep it outside the base loop or add it as an explicit later story.

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using dev-browser skill" in acceptance criteria. Ralph will use the dev-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Stop Condition

When all stories are `merged` in the local runtime state file, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

## Debugging

Check current state:

```bash
# See static story definitions
cat prd.json | jq '.userStories[] | {id, title, priority, branchName}'

# See runtime story lifecycle
cat .git/ralph-state.json | jq '.stories'

# See learnings from previous iterations
cat progress.txt

# Check git history
git log --oneline -10
```

## Customizing the Prompt

After copying `prompt.md` (for Amp), `CLAUDE.md` (for Claude Code), or `CODEX.md` (for Codex CLI) to your project, customize it for your project:
- Add project-specific branch/PR conventions
- Include codebase conventions
- Add common gotchas for your stack

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Amp documentation](https://ampcode.com/manual)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
- [Codex CLI documentation](https://github.com/openai/codex)
