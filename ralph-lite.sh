#!/bin/bash
# Ralph Light - minimal Codex loop for PR/task-list documents
# Usage: ./ralph-lite.sh --plan /path/to/plan.md [--iterations N] [--audit-iterations N] [--inline]

set -euo pipefail

MAX_ITERATIONS=20
AUDIT_ITERATIONS=3
PLAN_FILE=""
INLINE_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN_FILE="$2"
      shift 2
      ;;
    --plan=*)
      PLAN_FILE="${1#*=}"
      shift
      ;;
    --iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --iterations=*)
      MAX_ITERATIONS="${1#*=}"
      shift
      ;;
    --audit-iterations)
      AUDIT_ITERATIONS="$2"
      shift 2
      ;;
    --audit-iterations=*)
      AUDIT_ITERATIONS="${1#*=}"
      shift
      ;;
    --inline)
      INLINE_MODE=1
      shift
      ;;
    *)
      echo "Error: Unknown argument '$1'."
      exit 1
      ;;
  esac
done

if [[ -z "$PLAN_FILE" ]]; then
  echo "Error: --plan is required."
  exit 1
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [[ ! "$AUDIT_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "Error: --iterations and --audit-iterations must be non-negative integers."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="$(cd "$(dirname "$PLAN_FILE")" && pwd)/$(basename "$PLAN_FILE")"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "Error: Plan file not found: $PLAN_FILE"
  exit 1
fi

shell_quote() {
  printf "%q" "$1"
}

applescript_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

launch_visible_terminal() {
  local command
  command="cd $(shell_quote "$PWD") && RALPH_LITE_IN_TERMINAL=1 $(shell_quote "$SCRIPT_DIR/ralph-lite.sh") --inline --plan $(shell_quote "$PLAN_FILE") --iterations $(shell_quote "$MAX_ITERATIONS") --audit-iterations $(shell_quote "$AUDIT_ITERATIONS"); printf '\\nRalph Light exited with status %s\\n' \$?"

  osascript <<EOF
tell application "Terminal"
  activate
  do script "$(applescript_escape "$command")"
end tell
EOF
}

GIT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [[ -n "$GIT_DIR" ]]; then
  STATE_FILE="$GIT_DIR/ralph-lite-state.json"
  LOG_FILE="$GIT_DIR/ralph-lite.log"
else
  STATE_FILE="$SCRIPT_DIR/ralph-lite-state.json"
  LOG_FILE="$SCRIPT_DIR/ralph-lite.log"
fi

if [[ "$INLINE_MODE" -eq 0 && "${RALPH_LITE_IN_TERMINAL:-0}" != "1" && "$OSTYPE" == darwin* ]]; then
  launch_visible_terminal
  echo "Ralph Light launched in Terminal."
  exit 0
fi

ensure_state_file() {
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [[ ! -f "$STATE_FILE" ]]; then
    jq -n \
      --arg plan_file "$PLAN_FILE" \
      --arg timestamp "$timestamp" \
      --argjson max_iterations "$MAX_ITERATIONS" \
      --argjson audit_iterations "$AUDIT_ITERATIONS" '
      {
        schemaVersion: 1,
        planFile: $plan_file,
        maxIterations: $max_iterations,
        auditIterations: $audit_iterations,
        originalPlanCompleted: false,
        auditIterationsRun: 0,
        lastMode: "plan",
        lastMarker: null,
        startedAt: $timestamp,
        updatedAt: $timestamp
      }
    ' > "$STATE_FILE"
  fi
}

update_state() {
  local mode="$1"
  local marker="$2"
  local timestamp tmp_file
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp_file="$(mktemp)"

  jq \
    --arg mode "$mode" \
    --arg marker "$marker" \
    --arg timestamp "$timestamp" '
    .lastMode = $mode
    | .lastMarker = $marker
    | .updatedAt = $timestamp
    | .originalPlanCompleted = (if $marker == "plan_complete" or .originalPlanCompleted then true else false end)
    | .auditIterationsRun = (
        if $mode == "audit" then
          (.auditIterationsRun + 1)
        else
          .auditIterationsRun
        end
      )
  ' "$STATE_FILE" > "$tmp_file"
  mv "$tmp_file" "$STATE_FILE"
}

current_mode() {
  jq -r '
    if .originalPlanCompleted then
      "audit"
    else
      "plan"
    end
  ' "$STATE_FILE"
}

audit_iterations_run() {
  jq -r '.auditIterationsRun // 0' "$STATE_FILE"
}

extract_marker() {
  local output="$1"
  if grep -q '<ralph-lite>plan_complete</ralph-lite>' <<<"$output"; then
    echo "plan_complete"
  elif grep -q '<ralph-lite>audit_done</ralph-lite>' <<<"$output"; then
    echo "audit_done"
  else
    echo "continue"
  fi
}

ensure_state_file
: > "$LOG_FILE"

echo "Starting Ralph Light - Max iterations: $MAX_ITERATIONS - Audit iterations: $AUDIT_ITERATIONS"

for i in $(seq 1 "$MAX_ITERATIONS"); do
  MODE="$(current_mode)"
  AUDIT_RUNS="$(audit_iterations_run)"
  AUDIT_REMAINING=$((AUDIT_ITERATIONS - AUDIT_RUNS))

  if [[ "$MODE" == "audit" && "$AUDIT_REMAINING" -le 0 ]]; then
    echo "Ralph Light completed the original plan and exhausted the audit budget."
    exit 0
  fi

  echo ""
  echo "==============================================================="
  echo "  Ralph Light Iteration $i of $MAX_ITERATIONS ($MODE)"
  echo "==============================================================="

  OUTPUT="$(RALPH_LITE_PLAN_FILE="$PLAN_FILE" \
    RALPH_LITE_STATE_FILE="$STATE_FILE" \
    RALPH_LITE_MODE="$MODE" \
    RALPH_LITE_AUDIT_REMAINING="$AUDIT_REMAINING" \
    codex exec --dangerously-bypass-approvals-and-sandbox - < "$SCRIPT_DIR/LIGHT_CODEX.md" 2>&1 | tee -a "$LOG_FILE" /dev/stderr)" || true

  MARKER="$(extract_marker "$OUTPUT")"
  update_state "$MODE" "$MARKER"

  case "$MARKER" in
    plan_complete)
      echo "Original plan completed. Future iterations will audit for more issues."
      if [[ "$AUDIT_ITERATIONS" -eq 0 ]]; then
        echo "Audit budget is 0. Stopping now."
        exit 0
      fi
      ;;
    audit_done)
      echo "No more worthwhile audit tasks remain. Stopping."
      exit 0
      ;;
    *)
      echo "Iteration $i complete. Continuing."
      ;;
  esac

  sleep 2
done

echo "Ralph Light reached max iterations ($MAX_ITERATIONS)."
exit 1
