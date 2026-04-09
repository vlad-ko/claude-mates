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

BRANCH_NAME="${LABEL_PREFIX}/${MATE_NAME}/$(date +%Y-%m-%d-%H%M)"

# Check if a PR already exists for this mate today (prevent duplicates)
# Use date-only prefix to catch any run from today
BRANCH_PREFIX="${LABEL_PREFIX}/${MATE_NAME}/$(date +%Y-%m-%d)"
EXISTING_PR=$(gh pr list --search "head:${BRANCH_PREFIX}" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
if [ -n "$EXISTING_PR" ]; then
  echo "Open PR #$EXISTING_PR already exists for ${BRANCH_PREFIX}* — skipping"
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
$([ -n "$EXISTING_ISSUE" ] && echo "Existing open issue: #${EXISTING_ISSUE} — do NOT create a new issue. Reference this issue in your PR with 'Fixes #${EXISTING_ISSUE}'. Focus on creating the PR with fixes." || echo "No existing open issue — create one if needed, then create a PR with fixes.")

## Deny Rules

${DENY_RULES}
- NEVER merge any PR
- NEVER push directly to main
- NEVER modify .env files
- Max 1 PR per run
- Max 1 issue per run"

# Read skills from project config (skills the mate should invoke via /skill-name)
SKILLS_NOTE=""
if [ -f "$CONFIG_PATH" ]; then
  SKILLS_LIST=$(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    config = yaml.safe_load(f)
mate_config = config.get('mates', {}).get('$MATE_NAME', {})
skills = mate_config.get('skills', [])
if skills:
    print('\n'.join(f'- {s}' for s in skills))
" 2>/dev/null || echo "")

  if [ -n "$SKILLS_LIST" ]; then
    SKILLS_NOTE="
## Available Skills

The following project skills are available. Use them if relevant:
${SKILLS_LIST}
"
    FULL_PROMPT="${FULL_PROMPT}${SKILLS_NOTE}"
  fi
fi

# Read scope exclusions from project config
EXCLUSIONS=""
if [ -f "$CONFIG_PATH" ]; then
  EXCLUSIONS=$(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    config = yaml.safe_load(f)
mate_config = config.get('mates', {}).get('$MATE_NAME', {})
excludes = mate_config.get('exclude', [])
if excludes:
    print('\n'.join(f'- {e}' for e in excludes))
" 2>/dev/null || echo "")

  if [ -n "$EXCLUSIONS" ]; then
    FULL_PROMPT="${FULL_PROMPT}

## Excluded Paths (do not scan or modify)

${EXCLUSIONS}"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: Claude analyzes and edits files (no git, no gh — just file ops)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Phase 1: Claude Code Analysis & Edits ==="
START_TIME=$(date +%s)

# Claude gets file tools ONLY — no git/gh. Shell handles all git mechanics.
claude -p "$FULL_PROMPT" \
  --model "$MODEL_ID" \
  --allowedTools "Read,Glob,Grep,Edit,Write,Bash(find *),Bash(wc *),Bash(mv *),Bash(cat *),Bash(head *),Bash(tail *)" \
  --permission-mode acceptEdits \
  --max-turns "$MAX_TURNS" \
  --output-format json > "/tmp/mate-${MATE_NAME}-output.json" 2>&1 || true

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=== Phase 1 Complete (${DURATION}s) ==="

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: Shell handles git mechanics deterministically
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Phase 2: Git & GitHub Operations ==="

# Check if Claude made any file changes
CHANGED_FILES=$(git diff --name-only 2>/dev/null || echo "")
UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")

if [ -z "$CHANGED_FILES" ] && [ -z "$UNTRACKED_FILES" ]; then
  echo "No file changes detected — Claude found nothing to fix or only reported findings."

  # If no existing issue, Claude should have created one via the prompt.
  # But since we removed gh from Claude's tools, we need to handle issue creation here too.
  if [ -z "$EXISTING_ISSUE" ]; then
    echo "Creating issue from Claude's analysis..."
    # Extract Claude's output text for the issue body
    CLAUDE_OUTPUT=$(python3 -c "
import json
try:
    with open('/tmp/mate-${MATE_NAME}-output.json') as f:
        data = json.load(f)
    print(data.get('result', data.get('content', 'No analysis output available.')))
except:
    print('Analysis completed but output could not be parsed.')
" 2>/dev/null || echo "Analysis completed. Check workflow run for details.")

    ISSUE_URL=$(gh issue create \
      --title "[${LABEL_PREFIX}:${MATE_NAME}] Documentation review — $(date +%Y-%m-%d)" \
      --label "${LABEL_PREFIX}:${MATE_NAME}" \
      --body "$CLAUDE_OUTPUT" 2>/dev/null || echo "")

    if [ -n "$ISSUE_URL" ]; then
      echo "Created issue: $ISSUE_URL"
      EXISTING_ISSUE=$(echo "$ISSUE_URL" | grep -o '[0-9]*$')
    else
      echo "::warning::Failed to create issue"
    fi
  else
    echo "Existing issue #${EXISTING_ISSUE} covers these findings."
  fi

  echo "outcome=issue_only"
else
  echo "File changes detected:"
  echo "$CHANGED_FILES"
  echo "$UNTRACKED_FILES"

  # Step 1: Create issue if none exists
  if [ -z "$EXISTING_ISSUE" ]; then
    echo "Creating issue for findings..."
    CLAUDE_OUTPUT=$(python3 -c "
import json
try:
    with open('/tmp/mate-${MATE_NAME}-output.json') as f:
        data = json.load(f)
    print(data.get('result', data.get('content', 'Documentation fixes applied.')))
except:
    print('Documentation fixes applied. See PR for details.')
" 2>/dev/null || echo "Documentation fixes applied. See PR for details.")

    ISSUE_URL=$(gh issue create \
      --title "[${LABEL_PREFIX}:${MATE_NAME}] Documentation update needed — $(date +%Y-%m-%d)" \
      --label "${LABEL_PREFIX}:${MATE_NAME}" \
      --body "$CLAUDE_OUTPUT" 2>/dev/null || echo "")

    if [ -n "$ISSUE_URL" ]; then
      EXISTING_ISSUE=$(echo "$ISSUE_URL" | grep -o '[0-9]*$')
      echo "Created issue #${EXISTING_ISSUE}: $ISSUE_URL"
    fi
  fi

  # Step 2: Create branch, commit, push
  echo "Creating branch: ${BRANCH_NAME}"
  git checkout -b "${BRANCH_NAME}" origin/main 2>/dev/null || git checkout -b "${BRANCH_NAME}"

  git add -A
  git commit -m "docs: Fix documentation findings [${LABEL_PREFIX}:${MATE_NAME}]

Automated fixes by Claude Mates docs reviewer.
$([ -n "$EXISTING_ISSUE" ] && echo "Fixes #${EXISTING_ISSUE}")"

  git push origin "${BRANCH_NAME}" 2>/dev/null

  # Step 3: Create PR
  PR_BODY="## Automated Documentation Fixes

Fixes identified and applied by the \`${MATE_NAME}\` Claude Mate.

$([ -n "$EXISTING_ISSUE" ] && echo "Fixes #${EXISTING_ISSUE}" || echo "")

### Changed Files
$(echo "$CHANGED_FILES" "$UNTRACKED_FILES" | sed '/^$/d' | sed 's/^/- /')

---
*Generated by [Claude Mates](https://github.com/vlad-ko/claude-mates)*"

  PR_URL=$(gh pr create \
    --title "[${LABEL_PREFIX}:${MATE_NAME}] Fix documentation findings" \
    --body "$PR_BODY" \
    --base main \
    --head "${BRANCH_NAME}" \
    --label "${LABEL_PREFIX}:${MATE_NAME}" 2>/dev/null || echo "")

  if [ -n "$PR_URL" ]; then
    echo "Created PR: $PR_URL"
    echo "outcome=issue_and_pr"
  else
    echo "::warning::Failed to create PR"
    echo "outcome=issue_only"
  fi
fi

echo ""
echo "=== Phase 2 Complete ==="

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
