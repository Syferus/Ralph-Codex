#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool amp|claude|codex] [max_iterations]

set -euo pipefail

TOOL="amp"
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

if [[ "$TOOL" != "amp" && "$TOOL" != "claude" && "$TOOL" != "codex" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp', 'claude', or 'codex'."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
GIT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [[ -n "$GIT_DIR" ]]; then
  LAST_BRANCH_FILE="$GIT_DIR/ralph-last-branch"
  STATE_FILE="$GIT_DIR/ralph-state.json"
else
  LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
  STATE_FILE="$SCRIPT_DIR/ralph-state.json"
fi

ensure_state_file() {
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [[ ! -f "$STATE_FILE" ]]; then
    jq -n --arg timestamp "$timestamp" '
      {
        schemaVersion: 1,
        updatedAt: $timestamp,
        stories: {}
      }
    ' > "$STATE_FILE"
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  jq --slurpfile prd "$PRD_FILE" --arg timestamp "$timestamp" '
    .schemaVersion = 1
    | .updatedAt = $timestamp
    | .stories = (
        reduce ($prd[0].userStories // [])[] as $story (.stories // {};
          .[$story.id] = (
            .[$story.id] // {
              status: "pending",
              prNumber: null,
              prUrl: null,
              mergeCommitSha: null,
              blockedReason: null,
              lastValidatedCommit: null,
              fastCiPassed: false,
              lastUpdated: $timestamp
            }
            | .title = $story.title
            | .branchName = ($story.branchName // ("codex/" + ($story.id | ascii_downcase)))
          )
        )
      )
  ' "$STATE_FILE" > "$tmp_file"
  mv "$tmp_file" "$STATE_FILE"
}

fast_ci_command() {
  jq -r '.loopConfig.fastCiCommand // empty' "$PRD_FILE"
}

merge_method() {
  jq -r '.loopConfig.mergeMethod // "merge"' "$PRD_FILE"
}

all_stories_merged() {
  jq -e --slurpfile prd "$PRD_FILE" '
    . as $state
    | ($prd[0].userStories // [])
    | all(.[]; (($state.stories[.id].status // "pending") == "merged"))
  ' "$STATE_FILE" >/dev/null 2>&1
}

update_story_state() {
  local story_id="$1"
  local status="$2"
  local pr_number="${3:-}"
  local pr_url="${4:-}"
  local merge_commit_sha="${5:-}"
  local blocked_reason="${6:-}"
  local last_validated_commit="${7:-}"
  local fast_ci_passed="${8:-false}"
  local tmp_file
  tmp_file="$(mktemp)"
  jq \
    --arg story_id "$story_id" \
    --arg status "$status" \
    --arg pr_number "$pr_number" \
    --arg pr_url "$pr_url" \
    --arg merge_commit_sha "$merge_commit_sha" \
    --arg blocked_reason "$blocked_reason" \
    --arg last_validated_commit "$last_validated_commit" \
    --argjson fast_ci_passed "$fast_ci_passed" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
      .stories[$story_id] |= (
        .status = $status
        | .prNumber = (if $pr_number == "" then .prNumber else ($pr_number | tonumber) end)
        | .prUrl = (if $pr_url == "" then .prUrl else $pr_url end)
        | .mergeCommitSha = (if $merge_commit_sha == "" then .mergeCommitSha else $merge_commit_sha end)
        | .blockedReason = (if $blocked_reason == "" then .blockedReason else $blocked_reason end)
        | .lastValidatedCommit = (if $last_validated_commit == "" then .lastValidatedCommit else $last_validated_commit end)
        | .fastCiPassed = $fast_ci_passed
        | .lastUpdated = $timestamp
      )
      | .updatedAt = $timestamp
    ' "$STATE_FILE" > "$tmp_file"
  mv "$tmp_file" "$STATE_FILE"
}

sync_pr_state() {
  ensure_state_file

  local story_ids story_id pr_number pr_json pr_state pr_url merge_sha
  mapfile -t story_ids < <(jq -r '.stories | keys[]' "$STATE_FILE")

  for story_id in "${story_ids[@]}"; do
    pr_number="$(jq -r --arg story_id "$story_id" '.stories[$story_id].prNumber // empty' "$STATE_FILE")"
    if [[ -z "$pr_number" ]]; then
      continue
    fi

    if ! pr_json="$(gh pr view "$pr_number" --json number,url,state,mergeCommit 2>/dev/null)"; then
      continue
    fi

    pr_state="$(jq -r '.state' <<<"$pr_json")"
    pr_url="$(jq -r '.url // empty' <<<"$pr_json")"
    merge_sha="$(jq -r '.mergeCommit.oid // empty' <<<"$pr_json")"

    if [[ "$pr_state" == "MERGED" ]]; then
      update_story_state "$story_id" "merged" "$pr_number" "$pr_url" "$merge_sha" "" "" true
    elif [[ -n "$pr_url" ]]; then
      local current_status
      local current_fast_ci
      current_status="$(jq -r --arg story_id "$story_id" '.stories[$story_id].status // "pending"' "$STATE_FILE")"
      current_fast_ci="$(jq -r --arg story_id "$story_id" '.stories[$story_id].fastCiPassed // false' "$STATE_FILE")"
      update_story_state "$story_id" "$current_status" "$pr_number" "$pr_url" "" "" "" "$current_fast_ci"
    fi
  done
}

auto_merge_ready_prs() {
  ensure_state_file
  sync_pr_state

  local method merge_flag ready_story_ids story_id pr_number
  method="$(merge_method)"
  case "$method" in
    squash) merge_flag="--squash" ;;
    rebase) merge_flag="--rebase" ;;
    *) merge_flag="--merge" ;;
  esac

  mapfile -t ready_story_ids < <(jq -r '.stories | to_entries[] | select(.value.status == "ready_to_merge" and (.value.prNumber != null)) | .key' "$STATE_FILE")
  for story_id in "${ready_story_ids[@]}"; do
    pr_number="$(jq -r --arg story_id "$story_id" '.stories[$story_id].prNumber' "$STATE_FILE")"
    if gh pr merge "$pr_number" "$merge_flag" --delete-branch >/dev/null 2>&1; then
      sync_pr_state
    fi
  done
}

if [[ -f "$PRD_FILE" ]] && [[ -f "$LAST_BRANCH_FILE" ]]; then
  CURRENT_BRANCH="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")"
  LAST_BRANCH="$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")"

  if [[ -n "$CURRENT_BRANCH" ]] && [[ -n "$LAST_BRANCH" ]] && [[ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]]; then
    DATE="$(date +%Y-%m-%d)"
    FOLDER_NAME="$(echo "$LAST_BRANCH" | sed 's|^ralph/||')"
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [[ -f "$PRD_FILE" ]] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [[ -f "$PROGRESS_FILE" ]] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

ensure_state_file
sync_pr_state

if [[ -f "$PRD_FILE" ]]; then
  CURRENT_BRANCH="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")"
  if [[ -n "$CURRENT_BRANCH" ]]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

if [[ ! -f "$PROGRESS_FILE" ]]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  auto_merge_ready_prs
  if all_stories_merged; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  FAST_CI_COMMAND="$(fast_ci_command)"
  if [[ -z "$FAST_CI_COMMAND" ]]; then
    echo "Error: prd.json must define loopConfig.fastCiCommand."
    exit 1
  fi

  if [[ "$TOOL" == "amp" ]]; then
    OUTPUT="$(RALPH_STATE_FILE="$STATE_FILE" RALPH_FAST_CI_COMMAND="$FAST_CI_COMMAND" RALPH_MERGE_METHOD="$(merge_method)" amp --dangerously-allow-all < "$SCRIPT_DIR/prompt.md" 2>&1 | tee /dev/stderr)" || true
  elif [[ "$TOOL" == "claude" ]]; then
    OUTPUT="$(RALPH_STATE_FILE="$STATE_FILE" RALPH_FAST_CI_COMMAND="$FAST_CI_COMMAND" RALPH_MERGE_METHOD="$(merge_method)" claude --dangerously-skip-permissions --print < "$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr)" || true
  else
    OUTPUT="$(RALPH_STATE_FILE="$STATE_FILE" RALPH_FAST_CI_COMMAND="$FAST_CI_COMMAND" RALPH_MERGE_METHOD="$(merge_method)" codex exec --dangerously-bypass-approvals-and-sandbox - < "$SCRIPT_DIR/CODEX.md" 2>&1 | tee /dev/stderr)" || true
  fi

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    sync_pr_state
    auto_merge_ready_prs
    if all_stories_merged; then
      echo ""
      echo "Ralph completed all tasks!"
      echo "Completed at iteration $i of $MAX_ITERATIONS"
      exit 0
    fi
    echo "Agent reported COMPLETE, but runtime state still has unfinished stories. Continuing."
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
