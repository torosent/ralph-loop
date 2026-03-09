#!/bin/bash

# Ralph Loop Stop Hook for GitHub Copilot CLI
# Prevents session exit when a ralph-loop is active, feeding the same
# prompt back into the agent for the next iteration.

set -euo pipefail

HOOK_INPUT=$(cat)

# Check .copilot/ state directory
RALPH_STATE_FILE=""
if [[ -f ".copilot/ralph-loop.local.md" ]]; then
  RALPH_STATE_FILE=".copilot/ralph-loop.local.md"
fi

if [[ -z "$RALPH_STATE_FILE" ]]; then
  exit 0
fi

# Parse YAML frontmatter
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation: only this session's loop should be affected
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Validate numeric fields
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Ralph loop: corrupted state (iteration='$ITERATION'). Stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Ralph loop: corrupted state (max_iterations='$MAX_ITERATIONS'). Stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check iteration limit
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Try to read the last assistant message from the transcript (if available)
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || true)
LAST_OUTPUT=""

if [[ -n "$TRANSCRIPT_PATH" ]]; then
  if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    echo "⚠️  Ralph loop: Transcript file not found at $TRANSCRIPT_PATH" >&2
    echo "   This may indicate a Copilot CLI internal issue. Stopping loop." >&2
    rm "$RALPH_STATE_FILE"
    exit 0
  fi

  if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null; then
    echo "⚠️  Ralph loop: No assistant messages in transcript. Stopping loop." >&2
    rm "$RALPH_STATE_FILE"
    exit 0
  fi

  LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100)
  if [[ -n "$LAST_LINES" ]]; then
    set +e
    LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
      map(.message.content[]? | select(.type == "text") | .text) | join("\n")
    ' 2>&1)
    JQ_EXIT=$?
    set -e

    if [[ $JQ_EXIT -ne 0 ]]; then
      echo "⚠️  Ralph loop: Failed to parse transcript JSON. Stopping loop." >&2
      echo "   Error: $LAST_OUTPUT" >&2
      rm "$RALPH_STATE_FILE"
      exit 0
    fi
  fi
fi

# Check for completion promise
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]] && [[ -n "$LAST_OUTPUT" ]]; then
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    echo "✅ Ralph loop: Detected <promise>$COMPLETION_PROMISE</promise>"
    rm "$RALPH_STATE_FILE"
    exit 0
  fi
fi

# Continue loop: increment iteration and re-feed the prompt
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after closing ---) and strip leading blank lines
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE" | sed '/./,$!d')

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Ralph loop: no prompt found in state file. Stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Update iteration counter atomically
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

# Build system message
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | To stop: output <promise>$COMPLETION_PROMISE</promise> (ONLY when TRUE)"
else
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | No completion promise set - loop continues until max iterations or /ralph-loop:stop"
fi

# Output JSON to block the stop and feed prompt back
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
