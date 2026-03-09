#!/bin/bash

# Ralph Loop Setup Script for GitHub Copilot CLI
# Creates state file for in-session Ralph loop iteration

set -euo pipefail

PROMPT_PARTS=()
MAX_ITERATIONS=0
COMPLETION_PROMISE="null"

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP_EOF'
Ralph Loop - Iterative self-referential development loop for Copilot CLI

USAGE:
  /ralph-loop [PROMPT...] [OPTIONS]

ARGUMENTS:
  PROMPT...    Task description for the loop (can be multiple words)

OPTIONS:
  --max-iterations <n>           Maximum iterations before auto-stop (default: unlimited)
  --completion-promise '<text>'  Promise phrase that signals completion
  -h, --help                     Show this help message

DESCRIPTION:
  Starts a Ralph Loop in your CURRENT Copilot CLI session. The agentStop
  hook prevents exit and feeds your output back as input until the
  completion promise is detected or the iteration limit is reached.

  To signal completion, output: <promise>YOUR_PHRASE</promise>

EXAMPLES:
  /ralph-loop Build a todo API --completion-promise 'DONE' --max-iterations 20
  /ralph-loop --max-iterations 10 Fix the auth bug
  /ralph-loop Refactor cache layer  (runs until cancelled)

STOPPING:
  • Reaching --max-iterations
  • Detecting --completion-promise in <promise>...</promise> tags
  • Manually: /cancel-ralph

MONITORING:
  grep '^iteration:' .copilot/ralph-loop.local.md
  head -10 .copilot/ralph-loop.local.md
HELP_EOF
      exit 0
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: --max-iterations requires a non-negative integer" >&2
        echo "   Examples: --max-iterations 10, --max-iterations 50" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "❌ Error: --completion-promise requires a text argument" >&2
        echo "   Examples: --completion-promise 'DONE', --completion-promise 'All tests passing'" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    *)
      PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

PROMPT="${PROMPT_PARTS[*]}"

if [[ -z "$PROMPT" ]]; then
  echo "❌ Error: No prompt provided" >&2
  echo "   Example: /ralph-loop Build a REST API --completion-promise 'DONE' --max-iterations 20" >&2
  echo "   For help: /ralph-loop --help" >&2
  exit 1
fi

mkdir -p .copilot

if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""
else
  COMPLETION_PROMISE_YAML="null"
fi

# Detect session ID from environment (try multiple known variable names)
SESSION_ID="${COPILOT_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"

cat > .copilot/ralph-loop.local.md <<EOF
---
active: true
iteration: 1
session_id: ${SESSION_ID}
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE_YAML
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF

cat <<EOF
🔄 Ralph loop activated!

Iteration: 1
Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo $MAX_ITERATIONS; else echo "unlimited"; fi)
Completion promise: $(if [[ "$COMPLETION_PROMISE" != "null" ]]; then echo "${COMPLETION_PROMISE//\"/}"; else echo "none (runs until cancelled or max iterations)"; fi)

The agentStop hook is now active. When the agent finishes responding,
the SAME PROMPT will be fed back, creating a self-referential loop
where each iteration sees your previous work in files and git history.

To cancel: /ralph-loop:stop
To monitor: head -10 .copilot/ralph-loop.local.md
EOF

if [[ "$COMPLETION_PROMISE" != "null" ]]; then
  echo ""
  echo "To complete this loop, output EXACTLY:"
  echo "  <promise>$COMPLETION_PROMISE</promise>"
  echo ""
  echo "⚠️  The promise MUST be TRUE when you output it. Do not lie to exit."
fi
