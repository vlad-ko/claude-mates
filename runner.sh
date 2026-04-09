#!/bin/bash
# Claude Mates Runner
# Executes a single mate using Claude Code CLI

set -euo pipefail

MATE_NAME="$1"
MATE_DIR="$2"
CONFIG_PATH="${3:-.claude-mates.yml}"
TRIGGER_CONTEXT="${TRIGGER_CONTEXT:-{}}"

PROMPT_FILE="$MATE_DIR/PROMPT.md"
MATE_CONFIG="$MATE_DIR/mate.yml"

echo "Running mate: $MATE_NAME"
echo "Prompt: $PROMPT_FILE"
echo "Config: $MATE_CONFIG"

# Validate prompt exists
if [ ! -f "$PROMPT_FILE" ]; then
  echo "::error::Prompt file not found: $PROMPT_FILE"
  exit 1
fi

# Read mate config
MODEL="haiku"
MAX_TURNS=15
if [ -f "$MATE_CONFIG" ]; then
  MODEL=$(python3 -c "
import yaml
with open('$MATE_CONFIG') as f:
    config = yaml.safe_load(f)
print(config.get('model', 'haiku'))
" 2>/dev/null || echo "haiku")

  MAX_TURNS=$(python3 -c "
import yaml
with open('$MATE_CONFIG') as f:
    config = yaml.safe_load(f)
print(config.get('max_turns', 15))
" 2>/dev/null || echo "15")
fi

# Override model from project config if specified
if [ -f "$CONFIG_PATH" ]; then
  PROJECT_MODEL=$(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    config = yaml.safe_load(f)
mate_config = config.get('mates', {}).get('$MATE_NAME', {})
print(mate_config.get('model', ''))
" 2>/dev/null || echo "")

  if [ -n "$PROJECT_MODEL" ]; then
    MODEL="$PROJECT_MODEL"
  fi
fi

# Map model shorthand to full model ID
case "$MODEL" in
  haiku)  MODEL_ID="claude-haiku-4-5-20251001" ;;
  sonnet) MODEL_ID="claude-sonnet-4-6" ;;
  opus)   MODEL_ID="claude-opus-4-6" ;;
  *)      MODEL_ID="$MODEL" ;;
esac

echo "Model: $MODEL_ID"
echo "Max turns: $MAX_TURNS"

# Read deny rules from project config
DENY_RULES=""
if [ -f "$CONFIG_PATH" ]; then
  DENY_RULES=$(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    config = yaml.safe_load(f)
rules = config.get('deny', [])
print('\n'.join(f'- {r}' for r in rules))
" 2>/dev/null || echo "")
fi

# Build the full prompt
LABEL_PREFIX="claude-mate"
if [ -f "$CONFIG_PATH" ]; then
  LABEL_PREFIX=$(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    config = yaml.safe_load(f)
print(config.get('labels', {}).get('prefix', 'claude-mate'))
" 2>/dev/null || echo "claude-mate")
fi

BRANCH_NAME="${LABEL_PREFIX}/${MATE_NAME}/$(date +%Y-%m-%d)"

# Check if a PR already exists for this mate today (prevent duplicates)
EXISTING_PR=$(gh pr list --search "head:${BRANCH_NAME}" --json number --jq '.[0].number' 2>/dev/null || echo "")
if [ -n "$EXISTING_PR" ]; then
  echo "PR #$EXISTING_PR already exists for $BRANCH_NAME — skipping"
  exit 0
fi

# Also check for existing open issues from this mate today
EXISTING_ISSUE=$(gh issue list --search "label:${LABEL_PREFIX}:${MATE_NAME} is:open" --json number --jq '.[0].number' 2>/dev/null || echo "")

# Build the full prompt with context
FULL_PROMPT="$(cat "$PROMPT_FILE")

## Context

Trigger: ${TRIGGER_CONTEXT}
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Branch for changes: ${BRANCH_NAME}
Label for issues/PRs: ${LABEL_PREFIX}:${MATE_NAME}
$([ -n "$EXISTING_ISSUE" ] && echo "Existing open issue: #${EXISTING_ISSUE} — update it instead of creating a new one" || echo "No existing open issue — create one if needed")

## Deny Rules

${DENY_RULES}
- NEVER merge any PR
- NEVER push directly to main
- NEVER modify .env files
- Max 1 PR per run
- Max 1 issue per run"

# Run Claude Code CLI
echo ""
echo "=== Executing Claude Code ==="
START_TIME=$(date +%s)

claude -p "$FULL_PROMPT" \
  --model "$MODEL_ID" \
  --allowedTools "Read,Glob,Grep,Edit,Write,Bash(git diff *),Bash(git log *),Bash(git checkout -b *),Bash(git add *),Bash(git commit *),Bash(git push *),Bash(gh pr *),Bash(gh issue *),Bash(wc *),Bash(find *)" \
  --permission-mode acceptEdits \
  --max-turns "$MAX_TURNS" \
  --output-format json > "/tmp/mate-${MATE_NAME}-output.json" 2>&1 || true

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Extract results
echo ""
echo "=== Mate Run Complete ==="
echo "Duration: ${DURATION}s"

# Parse output for cost info if available
if [ -f "/tmp/mate-${MATE_NAME}-output.json" ]; then
  TOKENS_IN=$(python3 -c "
import json
with open('/tmp/mate-${MATE_NAME}-output.json') as f:
    data = json.load(f)
print(data.get('usage', {}).get('input_tokens', 0))
" 2>/dev/null || echo "0")

  TOKENS_OUT=$(python3 -c "
import json
with open('/tmp/mate-${MATE_NAME}-output.json') as f:
    data = json.load(f)
print(data.get('usage', {}).get('output_tokens', 0))
" 2>/dev/null || echo "0")

  echo "Tokens in: $TOKENS_IN"
  echo "Tokens out: $TOKENS_OUT"

  # Create summary artifact
  cat > "/tmp/mate-${MATE_NAME}-summary.json" << JSONEOF
{
  "mate": "${MATE_NAME}",
  "model": "${MODEL_ID}",
  "tokens_in": ${TOKENS_IN},
  "tokens_out": ${TOKENS_OUT},
  "duration_seconds": ${DURATION},
  "branch": "${BRANCH_NAME}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF

  echo "Summary: /tmp/mate-${MATE_NAME}-summary.json"
fi
