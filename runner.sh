#!/bin/bash
# Claude Mates Runner
# Executes a single mate using Claude Code CLI
#
# ARCHITECTURE: Code enforces, prompts guide.
# - Phase 1 (Claude): Analyzes and edits files. Constrained by --allowedTools.
# - Phase 2 (Shell):  Validates changes against hard rules. Creates branch/commit/issue/PR.
#   All hard rules are enforced HERE, not in prompts. Prompts guide behavior only.

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

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 0: Self-loop guard — don't analyze our own output
#
# On scheduled runs, skip if no HUMAN commits have landed since this mate's
# last contribution. Without this, the mate would review its own prior output
# every night (echo chamber / churn risk).
#
# "Automation commits" we ignore:
#   - [claude-mate:*] — this mate or any other mate's merged PR
#   - docs: Update CHANGELOG for v... — release automation's CHANGELOG PR
#   - [skip release] — explicit opt-out marker
#
# Only gated on schedule events. workflow_dispatch (manual) and push always
# run — a human explicitly asked or a real push happened.
# ═══════════════════════════════════════════════════════════════════════════

if [ "${GITHUB_EVENT_NAME:-}" = "schedule" ]; then
  # Deepen history so git log can reach back beyond recent commits. A small
  # fetch-depth on the caller's checkout is fine because we deepen here.
  git fetch --deepen 100 origin 2>/dev/null || true

  LAST_USER_COMMIT=$(git log --invert-grep \
      --grep='\[claude-mate' \
      --grep='docs: Update CHANGELOG for v' \
      --grep='\[skip release\]' \
      -1 --format=%H 2>/dev/null || echo "")

  LAST_MATE_COMMIT=$(git log -1 --format=%H \
      --grep="\[claude-mate:${MATE_NAME}\]" 2>/dev/null || echo "")

  if [ -n "$LAST_MATE_COMMIT" ] && [ -n "$LAST_USER_COMMIT" ] \
     && git merge-base --is-ancestor "$LAST_USER_COMMIT" "$LAST_MATE_COMMIT"; then
    echo "=== Phase 0: Self-loop guard ==="
    echo "Last user commit ($LAST_USER_COMMIT) is an ancestor of last ${MATE_NAME} mate commit ($LAST_MATE_COMMIT)."
    echo "No human-authored work since this mate's last contribution — skipping."
    # Emit outputs so downstream steps can branch on this.
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      {
        echo "outcome=none"
        echo "status=clean"
        echo "issue-url="
        echo "pr-url="
      } >> "$GITHUB_OUTPUT"
    fi
    exit 0
  fi
  echo "Phase 0: Self-loop guard passed — human commits exist since last mate run."
fi

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION — Read all mate settings from mate.yml and project config
# Hard rules are read here, enforced in Phase 2.
# ═══════════════════════════════════════════════════════════════════════════

# Read mate config with defaults
MODEL="haiku"
MAX_TURNS=15
COMMIT_PREFIX="chore"
MATE_DESC="$MATE_NAME"
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

  COMMIT_PREFIX=$(python3 -c "
import yaml
with open('$MATE_CONFIG') as f:
    config = yaml.safe_load(f)
print(config.get('commit_prefix', 'chore'))
" 2>/dev/null || echo "chore")

  MATE_DESC=$(python3 -c "
import yaml
with open('$MATE_CONFIG') as f:
    config = yaml.safe_load(f)
print(config.get('description', '$MATE_NAME'))
" 2>/dev/null || echo "$MATE_NAME")
fi

# Read allowed_paths from mate.yml (code-enforced scope — defaults)
ALLOWED_PATHS=$(python3 -c "
import yaml
with open('$MATE_CONFIG') as f:
    config = yaml.safe_load(f)
paths = config.get('allowed_paths', [])
if paths:
    print('\n'.join(paths))
" 2>/dev/null || echo "")

# Override allowed_paths from project config if specified
# Project config REPLACES mate.yml defaults (not merges)
if [ -f "$CONFIG_PATH" ]; then
  PROJECT_ALLOWED=$(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    config = yaml.safe_load(f)
mate_config = config.get('mates', {}).get('$MATE_NAME', {})
paths = mate_config.get('allowed_paths', [])
if paths:
    print('\n'.join(paths))
" 2>/dev/null || echo "")

  if [ -n "$PROJECT_ALLOWED" ]; then
    ALLOWED_PATHS="$PROJECT_ALLOWED"
  fi
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
echo "Commit prefix: $COMMIT_PREFIX"
echo "Description: $MATE_DESC"
if [ -n "$ALLOWED_PATHS" ]; then
  echo "Allowed paths: $(echo "$ALLOWED_PATHS" | tr '\n' ', ')"
fi

# Read deny rules from project config (injected as prompt defense-in-depth)
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

# Build label names
LABEL_PREFIX="claude-mate"
if [ -f "$CONFIG_PATH" ]; then
  LABEL_PREFIX=$(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    config = yaml.safe_load(f)
print(config.get('labels', {}).get('prefix', 'claude-mate'))
" 2>/dev/null || echo "claude-mate")
fi

MATE_LABEL="${LABEL_PREFIX}:${MATE_NAME}"

# Ensure mate label exists (gh issue/pr create fails if label is missing)
gh label create "$MATE_LABEL" --description "Claude Mate: ${MATE_NAME}" --color "7057ff" 2>/dev/null || true

BRANCH_NAME="${LABEL_PREFIX}/${MATE_NAME}/$(date +%Y-%m-%d-%H%M)"

# Check if a PR already exists for this mate today (prevent duplicates)
BRANCH_PREFIX="${LABEL_PREFIX}/${MATE_NAME}/$(date +%Y-%m-%d)"
EXISTING_PR=$(gh pr list --search "head:${BRANCH_PREFIX}" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
if [ -n "$EXISTING_PR" ]; then
  echo "Open PR #$EXISTING_PR already exists for ${BRANCH_PREFIX}* — skipping"
  # Write summary even on early exit so the Job Summary panel isn't empty
  if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    echo "### Claude Mate: \`${MATE_NAME}\` — Skipped (existing PR #${EXISTING_PR})" >> "$GITHUB_STEP_SUMMARY"
  fi
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

# Read skills from project config
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
# Tool restrictions are CODE-ENFORCED via --allowedTools.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Phase 1: Claude Code Analysis & Edits ==="
START_TIME=$(date +%s)

# Claude gets file tools ONLY — no git/gh. Shell handles all git mechanics.
# This is the primary security boundary: Claude cannot run arbitrary commands.
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
# PHASE 1.5: Extract and log Claude's analysis (for debugging visibility)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Claude Analysis Output ==="

CLAUDE_RESULT=""
CLAUDE_STATUS="empty"  # Tracks output quality: ok, clean, error, empty

if [ -f "/tmp/mate-${MATE_NAME}-output.json" ]; then
  CLAUDE_RESULT=$(python3 -c "
import json, sys
try:
    with open('/tmp/mate-${MATE_NAME}-output.json') as f:
        data = json.load(f)
    # Try multiple JSON paths — Claude CLI output format may vary
    for key in ['result', 'content', 'text', 'output']:
        val = data.get(key)
        if val:
            if isinstance(val, list):
                # Handle content blocks (list of dicts with 'text' key)
                parts = []
                for block in val:
                    if isinstance(block, dict) and 'text' in block:
                        parts.append(block['text'])
                    elif isinstance(block, str):
                        parts.append(block)
                val = '\n'.join(parts)
            if isinstance(val, str) and val.strip():
                print(val.strip())
                sys.exit(0)
    # No content key populated. Classify from CLI metadata so downstream
    # grep can distinguish real failure modes (max_turns, API errors,
    # permission denials) from a genuine empty run.
    is_error = data.get('is_error', False)
    stop_reason = data.get('stop_reason') or data.get('terminal_reason') or ''
    num_turns = data.get('num_turns', 0)
    errors = data.get('errors') or []
    denials = data.get('permission_denials') or []

    if is_error or errors:
        err_msg = ''
        if errors and isinstance(errors, list):
            first = errors[0]
            if isinstance(first, dict):
                err_msg = first.get('message') or first.get('type') or str(first)
            else:
                err_msg = str(first)
        print(f'(cli error — stop_reason={stop_reason}, errors={err_msg})')
    elif stop_reason in ('max_turns', 'end_turn_limit') or (num_turns and 'max' in str(stop_reason).lower()):
        # Max turns: Claude hit the turn budget without emitting a final result.
        # Treat as 'empty' — don't create half-baked issues.
        print(f'(no result text found — max_turns reached after {num_turns} turns)')
    elif denials:
        print(f'(no result text found — {len(denials)} permission denial(s), stop_reason={stop_reason})')
    else:
        # Fall back to dumping top-level keys for debugging
        print('(no result text found — keys: ' + ', '.join(data.keys()) + f', stop_reason={stop_reason}, num_turns={num_turns})')
except Exception as e:
    print(f'(parse error: {e})')
" 2>/dev/null || echo "(failed to parse Claude output)")

  # ─── Classify the output ───────────────────────────────────────────────
  # CODE-ENFORCED: Detect errors, empty results, and clean runs BEFORE
  # any issue creation. Don't rely on LLM output wording alone.

  # Check for API/CLI errors in the output (including structured CLI error metadata)
  if echo "$CLAUDE_RESULT" | grep -qiE "rate_limit_error|API Error|overloaded_error|server_error|authentication_error|invalid_api_key|connection_error|timeout" \
     || echo "$CLAUDE_RESULT" | grep -qE "^\(cli error"; then
    CLAUDE_STATUS="error"
    echo "::warning::Claude CLI returned an API error — skipping issue creation"
  # Check for failed/empty output parsing (no result, parse error, max_turns, permission denials)
  elif echo "$CLAUDE_RESULT" | grep -qE "^\(no result text found|^\(parse error|^\(failed to parse"; then
    CLAUDE_STATUS="empty"
    echo "::warning::Claude output parsing failed — skipping issue creation"
  # Check for clean run signals (broad matching)
  elif echo "$CLAUDE_RESULT" | grep -qiE "no (issues|findings|changes|problems|vulnerabilities|concerns|errors|bugs|security issues)|everything looks good|nothing to (report|fix|flag|do)|codebase (is|looks) clean|no action needed|clean[[:space:]]*$|exiting cleanly|no .* found|no .* detected|no .* needed|repository is clean"; then
    CLAUDE_STATUS="clean"
  else
    CLAUDE_STATUS="ok"
  fi

  echo "Output status: $CLAUDE_STATUS"

  # Log first 3000 chars of Claude's analysis to CI
  echo "$CLAUDE_RESULT" | head -c 3000
  if [ ${#CLAUDE_RESULT} -gt 3000 ]; then
    echo ""
    echo "... (truncated, full output in artifact)"
  fi
else
  echo "(no output file found)"
  CLAUDE_STATUS="empty"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: Shell handles git mechanics — ALL HARD RULES ENFORCED HERE
# The LLM has no say in this phase. Code validates, code decides.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Phase 2: Validation & Git Operations ==="

# Track outcomes for the summary
OUTCOME="none"
ISSUE_NUM=""
PR_NUM=""
ISSUE_URL_OUT=""
PR_URL_OUT=""
FILES_CHANGED_COUNT=0
VIOLATIONS_FOUND=0

# Collect all changed files (modified + untracked).
# Exclude MATES_ROOT — when consumer repos check out the framework into a
# subdirectory (e.g., .claude-mates-framework/), those files appear as
# untracked but are NOT mate changes. This prevents phantom PRs.
CHANGED_FILES=$(git diff --name-only 2>/dev/null || echo "")
UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
ALL_CHANGED=$(echo -e "${CHANGED_FILES}\n${UNTRACKED_FILES}" | sed '/^$/d' | sort -u)

# Filter out MATES_ROOT if it's a subdirectory of the repo (not ".").
# Normalize the path (strip leading ./ and trailing /) for reliable matching.
if [ -n "$MATES_ROOT" ] && [ "$MATES_ROOT" != "." ] && [ "$MATES_ROOT" != "./" ]; then
  MATES_ROOT_NORM="${MATES_ROOT#./}"
  MATES_ROOT_NORM="${MATES_ROOT_NORM%/}"
  ALL_CHANGED=$(echo "$ALL_CHANGED" | grep -v "^${MATES_ROOT_NORM}\(/\|$\)" || true)
fi

if [ -z "$ALL_CHANGED" ]; then
  echo "No file changes detected by Claude."

  # CODE-ENFORCED: Use CLAUDE_STATUS (set in Phase 1.5) to decide actions.
  # Only "ok" status creates issues. Errors, empty, and clean runs do NOT.
  case "$CLAUDE_STATUS" in
    clean)
      echo "Claude found no issues — codebase is clean for this mate's scope."
      OUTCOME="clean"
      ;;
    error)
      echo "Claude encountered an API error — no issue created. Check CI logs."
      OUTCOME="error"
      ;;
    empty)
      echo "Claude output was empty or unparseable — no issue created."
      OUTCOME="clean"
      ;;
    ok)
      # Real findings — create issue or reference existing one
      if [ -n "$EXISTING_ISSUE" ]; then
        echo "Claude reported findings but made no file edits. Existing issue #${EXISTING_ISSUE} covers these."
        ISSUE_NUM="$EXISTING_ISSUE"
        OUTCOME="no_changes_existing_issue"
      else
        echo "Claude reported findings but made no file edits. Creating issue..."
        ISSUE_TITLE="[${LABEL_PREFIX}:${MATE_NAME}] ${MATE_DESC} findings — $(date +%Y-%m-%d)"
        ISSUE_BODY="$CLAUDE_RESULT"

        ISSUE_URL=$(gh issue create \
          --title "$ISSUE_TITLE" \
          --label "$MATE_LABEL" \
          --body "$ISSUE_BODY" 2>/tmp/mate-issue-error.txt || echo "")

        if echo "$ISSUE_URL" | grep -q "^https://"; then
          ISSUE_NUM=$(echo "$ISSUE_URL" | grep -o '[0-9]*$')
          ISSUE_URL_OUT="$ISSUE_URL"
          EXISTING_ISSUE="$ISSUE_NUM"
          OUTCOME="issue_created"
        else
          ISSUE_ERROR=$(cat /tmp/mate-issue-error.txt 2>/dev/null || echo "unknown error")
          echo "Issue creation failed: $ISSUE_ERROR"
          OUTCOME="findings_no_issue"
        fi
      fi
      ;;
  esac
else
  PRE_VALIDATION_COUNT=$(echo "$ALL_CHANGED" | wc -l | tr -d ' ')
  echo "File changes detected ($PRE_VALIDATION_COUNT files before validation):"
  echo "$ALL_CHANGED"

  # ═══════════════════════════════════════════════════════════════════════
  # HARD RULE: Protected paths — NEVER allow modification
  # These files are framework core, governance, and infrastructure.
  # Any changes to these are REVERTED, regardless of what the LLM decided.
  # ═══════════════════════════════════════════════════════════════════════
  echo ""
  echo "--- Validating protected paths ---"
  PROTECTED_PATTERN="^(runner\.sh|dispatcher\.sh|action\.yml|CODEOWNERS|SECURITY\.md|\.github/workflows/|\.env)"
  PROTECTED_VIOLATIONS=$(echo "$ALL_CHANGED" | grep -E "$PROTECTED_PATTERN" || echo "")

  # Also protect other mates' config (a mate should never edit another mate's files)
  OTHER_MATE_VIOLATIONS=$(echo "$ALL_CHANGED" | grep "^mates/" | grep -v "^mates/${MATE_NAME}/" 2>/dev/null || echo "")

  ALL_VIOLATIONS=$(echo -e "${PROTECTED_VIOLATIONS}\n${OTHER_MATE_VIOLATIONS}" | sed '/^$/d' | sort -u)

  if [ -n "$ALL_VIOLATIONS" ]; then
    echo "::warning::Mate '$MATE_NAME' attempted to modify protected files — reverting:"
    echo "$ALL_VIOLATIONS"
    VIOLATIONS_FOUND=$(echo "$ALL_VIOLATIONS" | wc -l | tr -d ' ')

    # Revert each protected file
    while IFS= read -r file; do
      if [ -n "$file" ]; then
        if git ls-files --error-unmatch "$file" 2>/dev/null; then
          # Tracked file — revert to HEAD
          git checkout -- "$file" 2>/dev/null || true
        else
          # Untracked file — delete it
          rm -f "$file" 2>/dev/null || true
        fi
        echo "  Reverted: $file"
      fi
    done <<< "$ALL_VIOLATIONS"
  else
    echo "No protected path violations."
  fi

  # ═══════════════════════════════════════════════════════════════════════
  # HARD RULE: Scope enforcement — only allow changes to mate's allowed_paths
  # If mate.yml defines allowed_paths, changes outside those paths are REVERTED.
  # ═══════════════════════════════════════════════════════════════════════
  if [ -n "$ALLOWED_PATHS" ]; then
    echo ""
    echo "--- Validating scope boundaries ---"

    # Re-collect changes after protected path reverts
    CHANGED_FILES=$(git diff --name-only 2>/dev/null || echo "")
    UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
    ALL_CHANGED=$(echo -e "${CHANGED_FILES}\n${UNTRACKED_FILES}" | sed '/^$/d' | sort -u)

    # Check each changed file against allowed_paths using Python fnmatch
    SCOPE_VIOLATIONS=$(python3 -c "
import fnmatch, sys

allowed = '''$ALLOWED_PATHS'''.strip().split('\n')
changed = '''$ALL_CHANGED'''.strip().split('\n')

for f in changed:
    f = f.strip()
    if not f:
        continue
    matched = False
    for pattern in allowed:
        pattern = pattern.strip()
        if not pattern:
            continue
        if fnmatch.fnmatch(f, pattern):
            matched = True
            break
    if not matched:
        print(f)
" 2>/dev/null || echo "")

    if [ -n "$SCOPE_VIOLATIONS" ]; then
      echo "::warning::Mate '$MATE_NAME' edited files outside its allowed scope — reverting:"
      echo "$SCOPE_VIOLATIONS"
      SCOPE_VIOLATION_COUNT=$(echo "$SCOPE_VIOLATIONS" | wc -l | tr -d ' ')
      VIOLATIONS_FOUND=$((VIOLATIONS_FOUND + SCOPE_VIOLATION_COUNT))

      # Revert out-of-scope files
      while IFS= read -r file; do
        if [ -n "$file" ]; then
          if git ls-files --error-unmatch "$file" 2>/dev/null; then
            git checkout -- "$file" 2>/dev/null || true
          else
            rm -f "$file" 2>/dev/null || true
          fi
          echo "  Reverted: $file"
        fi
      done <<< "$SCOPE_VIOLATIONS"
    else
      echo "All changes within allowed scope."
    fi
  fi

  # ═══════════════════════════════════════════════════════════════════════
  # HARD RULE: Change size guardrail
  # Warn if a mate modified too many files — probably something wrong.
  # ═══════════════════════════════════════════════════════════════════════

  # Re-collect changes after all reverts
  CHANGED_FILES=$(git diff --name-only 2>/dev/null || echo "")
  UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
  ALL_CHANGED=$(echo -e "${CHANGED_FILES}\n${UNTRACKED_FILES}" | sed '/^$/d' | sort -u)

  if [ -z "$ALL_CHANGED" ]; then
    echo ""
    echo "All changes were outside scope or protected — nothing to commit."
    if [ "$VIOLATIONS_FOUND" -gt 0 ]; then
      OUTCOME="violations_only"
    else
      OUTCOME="clean"
    fi
  else
    VALID_FILE_COUNT=$(echo "$ALL_CHANGED" | wc -l | tr -d ' ')
    echo ""
    echo "Valid changes after validation: $VALID_FILE_COUNT files"
    echo "$ALL_CHANGED"

    MAX_FILES=20
    if [ "$VALID_FILE_COUNT" -gt "$MAX_FILES" ]; then
      echo "::warning::Mate '$MATE_NAME' modified $VALID_FILE_COUNT files (threshold: $MAX_FILES). Review carefully."
    fi

    # ═════════════════════════════════════════════════════════════════════
    # Create issue (if none exists) — title and body driven by mate config
    # ═════════════════════════════════════════════════════════════════════
    if [ -z "$EXISTING_ISSUE" ]; then
      echo "Creating issue for findings..."
      ISSUE_TITLE="[${LABEL_PREFIX}:${MATE_NAME}] ${MATE_DESC} — $(date +%Y-%m-%d)"
      ISSUE_BODY="${CLAUDE_RESULT:-${MATE_DESC} analysis complete. See PR for details.}"

      ISSUE_URL=$(gh issue create \
        --title "$ISSUE_TITLE" \
        --label "$MATE_LABEL" \
        --body "$ISSUE_BODY" 2>/tmp/mate-issue-error.txt || echo "")

      if echo "$ISSUE_URL" | grep -q "^https://"; then
        ISSUE_NUM=$(echo "$ISSUE_URL" | grep -o '[0-9]*$')
        ISSUE_URL_OUT="$ISSUE_URL"
        EXISTING_ISSUE="$ISSUE_NUM"
      else
        echo "Issue creation failed: $(cat /tmp/mate-issue-error.txt 2>/dev/null || echo 'unknown error')"
      fi
    fi

    # ═════════════════════════════════════════════════════════════════════
    # Create branch, commit, push — all deterministic, no LLM involvement
    # Commit message uses mate.yml commit_prefix, not hard-coded "docs:"
    # ═════════════════════════════════════════════════════════════════════

    # Configure git identity for CI
    git config user.name "Claude Mates [bot]"
    git config user.email "claude-mates[bot]@users.noreply.github.com"

    echo "Creating branch: ${BRANCH_NAME}"
    git checkout -b "${BRANCH_NAME}" origin/main 2>/dev/null || git checkout -b "${BRANCH_NAME}"

    git add -A
    COMMIT_MSG="${COMMIT_PREFIX}: ${MATE_DESC} findings [${LABEL_PREFIX}:${MATE_NAME}]

Automated fixes by Claude Mates ${MATE_NAME} reviewer.
$([ -n "$EXISTING_ISSUE" ] && echo "Fixes #${EXISTING_ISSUE}")"

    git commit -m "$COMMIT_MSG"

    git push origin "${BRANCH_NAME}" 2>/dev/null

    # ═════════════════════════════════════════════════════════════════════
    # Create PR — title uses conventional commit prefix first so it passes
    # consumer repos' pr-title-check workflows and release automation.
    # Format: "<prefix>: <description> [<label>:<mate>]"
    # ═════════════════════════════════════════════════════════════════════
    PR_TITLE="${COMMIT_PREFIX}: ${MATE_DESC} fixes [${LABEL_PREFIX}:${MATE_NAME}]"
    PR_BODY="## ${MATE_DESC} — Automated Fixes

Fixes identified and applied by the \`${MATE_NAME}\` Claude Mate.

$([ -n "$EXISTING_ISSUE" ] && echo "Fixes #${EXISTING_ISSUE}" || echo "")

### Changed Files
$(printf '%s\n' "$ALL_CHANGED" | while IFS= read -r f; do [ -n "$f" ] && echo "- $f"; done)
$([ "$VIOLATIONS_FOUND" -gt 0 ] && echo "
### Validation Notes
$VIOLATIONS_FOUND file(s) were reverted by the runner for violating scope or protected path rules. See CI logs for details." || echo "")

---
*Generated by [Claude Mates](https://github.com/vlad-ko/claude-mates)*"

    PR_ERROR=""
    PR_URL=$(gh pr create \
      --title "$PR_TITLE" \
      --body "$PR_BODY" \
      --base main \
      --head "${BRANCH_NAME}" \
      --label "$MATE_LABEL" 2>/tmp/mate-pr-error.txt || echo "")

    if echo "$PR_URL" | grep -q "^https://"; then
      PR_NUM=$(echo "$PR_URL" | grep -o '[0-9]*$')
      PR_URL_OUT="$PR_URL"
      FILES_CHANGED_COUNT=$(echo "$ALL_CHANGED" | wc -l | tr -d ' ')
      OUTCOME="issue_and_pr"
    else
      PR_ERROR=$(cat /tmp/mate-pr-error.txt 2>/dev/null || echo "unknown error")
      echo "PR creation failed: $PR_ERROR"
      OUTCOME="issue_only_pr_failed"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY — Clear, reviewable output
# ═══════════════════════════════════════════════════════════════════════════

# Parse token usage
TOKENS_IN=0
TOKENS_OUT=0
if [ -f "/tmp/mate-${MATE_NAME}-output.json" ]; then
  TOKENS_IN=$(python3 -c "
import json
try:
    with open('/tmp/mate-${MATE_NAME}-output.json') as f:
        data = json.load(f)
    print(data.get('usage', {}).get('input_tokens', 0))
except: print(0)
" 2>/dev/null || echo "0")

  TOKENS_OUT=$(python3 -c "
import json
try:
    with open('/tmp/mate-${MATE_NAME}-output.json') as f:
        data = json.load(f)
    print(data.get('usage', {}).get('output_tokens', 0))
except: print(0)
" 2>/dev/null || echo "0")
fi

# Print summary to CI logs
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              CLAUDE MATE RUN SUMMARY                    ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Mate:       ${MATE_NAME}"
echo "║  Desc:       ${MATE_DESC}"
echo "║  Model:      ${MODEL_ID}"
echo "║  Duration:   ${DURATION}s"
echo "║  Tokens:     ${TOKENS_IN} in / ${TOKENS_OUT} out"
echo "║  Violations: ${VIOLATIONS_FOUND} files reverted"
echo "╠══════════════════════════════════════════════════════════╣"

case "$OUTCOME" in
  issue_and_pr)
    echo "║  RESULT:   Issue + PR created"
    echo "║  Issue:    #${ISSUE_NUM} ${ISSUE_URL_OUT}"
    echo "║  PR:       #${PR_NUM} ${PR_URL_OUT}"
    echo "║  Files:    ${FILES_CHANGED_COUNT} changed"
    ;;
  issue_created)
    echo "║  RESULT:   Issue created (findings need human review)"
    echo "║  Issue:    #${ISSUE_NUM} ${ISSUE_URL_OUT}"
    echo "║  PR:       Not created — Claude reported findings but didn't edit files"
    ;;
  no_changes_existing_issue)
    echo "║  RESULT:   Existing issue still open, no new edits"
    echo "║  Issue:    #${ISSUE_NUM} (existing)"
    echo "║  PR:       Not created — no new file edits"
    ;;
  findings_no_issue)
    echo "║  RESULT:   Findings reported (issue creation skipped)"
    echo "║  Issue:    Not created — check Claude output above"
    echo "║  PR:       Not created"
    ;;
  error)
    echo "║  RESULT:   Error — Claude API/CLI failure"
    echo "║  Issue:    Not created (API error, not a finding)"
    echo "║  PR:       Not created"
    ;;
  issue_only_pr_failed)
    echo "║  RESULT:   Changes pushed, PR creation failed"
    echo "║  Issue:    #${ISSUE_NUM}"
    echo "║  PR:       Not created — ${PR_ERROR:-see logs above}"
    ;;
  violations_only)
    echo "║  RESULT:   All changes reverted (scope/protected violations)"
    echo "║  Issue:    Not created"
    echo "║  PR:       Not created"
    ;;
  clean)
    echo "║  RESULT:   Clean — no findings, codebase looks good"
    echo "║  Issue:    Not needed"
    echo "║  PR:       Not needed"
    ;;
  none)
    echo "║  RESULT:   Clean — no findings, no changes needed"
    echo "║  Issue:    Not created"
    echo "║  PR:       Not created"
    ;;
esac

echo "╚══════════════════════════════════════════════════════════╝"

# Write to GitHub Actions Job Summary
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
  cat >> "$GITHUB_STEP_SUMMARY" << MDEOF
### Claude Mate: \`${MATE_NAME}\`

| | |
|---|---|
| **Description** | ${MATE_DESC} |
| **Model** | ${MODEL_ID} |
| **Duration** | ${DURATION}s |
| **Tokens** | ${TOKENS_IN} in / ${TOKENS_OUT} out |
| **Result** | ${OUTCOME} |
| **Violations reverted** | ${VIOLATIONS_FOUND} |
$([ -n "$ISSUE_NUM" ] && echo "| **Issue** | #${ISSUE_NUM} |")
$([ -n "$PR_NUM" ] && echo "| **PR** | #${PR_NUM} |")
$([ "$FILES_CHANGED_COUNT" -gt 0 ] 2>/dev/null && echo "| **Files changed** | ${FILES_CHANGED_COUNT} |")
MDEOF
fi

# Create summary artifact
cat > "/tmp/mate-${MATE_NAME}-summary.json" << JSONEOF
{
  "mate": "${MATE_NAME}",
  "description": "${MATE_DESC}",
  "model": "${MODEL_ID}",
  "tokens_in": ${TOKENS_IN},
  "tokens_out": ${TOKENS_OUT},
  "duration_seconds": ${DURATION},
  "outcome": "${OUTCOME}",
  "issue_number": "${ISSUE_NUM}",
  "pr_number": "${PR_NUM}",
  "files_changed": ${FILES_CHANGED_COUNT},
  "violations_reverted": ${VIOLATIONS_FOUND},
  "branch": "${BRANCH_NAME}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF

# ═══════════════════════════════════════════════════════════════════════════
# Action outputs — surface a simplified outcome to callers via $GITHUB_OUTPUT.
# Internal OUTCOME has many values; the composite action contract is just
#   outcome ∈ {none, issue, pr}  and  status ∈ {ok, clean, error, empty}
# Downstream workflow steps can branch on these.
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  case "$OUTCOME" in
    issue_and_pr|issue_only_pr_failed)
      ACTION_OUTCOME="pr" ;;
    issue_created|no_changes_existing_issue|violations_only)
      ACTION_OUTCOME="issue" ;;
    *)
      ACTION_OUTCOME="none" ;;
  esac
  {
    echo "outcome=${ACTION_OUTCOME}"
    echo "status=${CLAUDE_STATUS}"
    echo "issue-url=${ISSUE_URL_OUT}"
    echo "pr-url=${PR_URL_OUT}"
  } >> "$GITHUB_OUTPUT"
fi
