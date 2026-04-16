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
# PHASE 0: Bounded delta window — the delta-only contract
#
# Hard rule: a mate ALWAYS reviews a bounded delta. Full-repo scans are
# forbidden — even on first run. Historical cleanup is for humans running
# Claude Code directly; mates do simple cleanup of recent changes.
#
# Window-selection algorithm:
#
#   PRIMARY: max(cursor, now - MAX_WINDOW_HOURS) by recency.
#            Whichever is more recent wins → smaller window → bounded cost.
#
#   FALLBACK: if the primary window resolves to the N-hour cap and the
#             cap produces ZERO changed files (no commits in last N hours),
#             AND a cursor exists, extend the window to the cursor. This
#             catches unreviewed work that predates the window horizon —
#             e.g., a burst of commits three days ago with nothing since.
#             The cap is a cost safety-net; when there's no cost to bound,
#             don't waste the run.
#
#   SKIP:     only when BOTH primary and fallback produce zero changed
#             files, OR when neither a cursor nor a cap exists (brand-new
#             repo younger than the window horizon with no prior mate run).
#             "Fully idle since last review" correctly skips.
#
# MAX_WINDOW_HOURS defaults to 24, configurable via .claude-mates.yml.
# Adopters who want the mate to "catch up" after an outage can raise
# this: e.g. max_window_hours: 168 for a week. No upper bound — their cost.
#
# Downstream cases:
#   1. WINDOW_START set, REVIEW_SET non-empty → run, prompt scopes to it
#   2. WINDOW_START set, REVIEW_SET empty     → skip clean, zero API cost
#   3. WINDOW_START empty                     → skip clean (no window work)
#
# Self-loop guards (below) are a separate concern: don't review
# mate-authored commits or release automation. Window scope is the
# review-AMOUNT question; self-loop guards are the should-we-run question.
#
# "Automation commits" we ignore when finding the last human commit:
#   - [claude-mate:*] — this mate or any other mate's merged PR
#   - docs: Update CHANGELOG for v... — release automation's CHANGELOG PR
#   - [skip release] — explicit opt-out marker
#
# Self-loop SKIP is gated on schedule events only. workflow_dispatch and
# push always proceed — a human asked, or a real push happened.
# ═══════════════════════════════════════════════════════════════════════════

# Deepen history once (idempotent; no-op if already deep enough). Runs on
# every event type so both the self-loop skip AND the metadata enrichment
# have enough history to work with.
git fetch --deepen 100 origin 2>/dev/null || true

# Cursor: this mate's most recent contribution on HEAD's ancestry.
# Empty on first-ever run or after history rewrites that wiped the mate
# commits. Kept separately from WINDOW_START because it's useful for
# telemetry and for distinguishing "never ran" vs. "ran long ago".
LAST_MATE_COMMIT=$(git log -1 --format=%H \
    --grep="\[claude-mate:${MATE_NAME}\]" 2>/dev/null || echo "")

# MAX_WINDOW_HOURS resolution (precedence):
#   1. .claude-mates.yml → mates.<name>.max_window_hours (project override)
#   2. mate.yml → max_window_hours (framework default)
#   3. Hard fallback: 24
MAX_WINDOW_HOURS=24
if [ -f "$MATE_CONFIG" ]; then
  MATE_MAX_WINDOW=$(python3 -c "
import yaml
with open('$MATE_CONFIG') as f:
    config = yaml.safe_load(f)
v = config.get('max_window_hours')
if v is not None:
    print(v)
" 2>/dev/null || echo "")
  if [ -n "$MATE_MAX_WINDOW" ]; then
    MAX_WINDOW_HOURS="$MATE_MAX_WINDOW"
  fi
fi
if [ -f "$CONFIG_PATH" ]; then
  PROJECT_MAX_WINDOW=$(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    config = yaml.safe_load(f)
mate_config = config.get('mates', {}).get('$MATE_NAME', {})
v = mate_config.get('max_window_hours')
if v is not None:
    print(v)
" 2>/dev/null || echo "")
  if [ -n "$PROJECT_MAX_WINDOW" ]; then
    MAX_WINDOW_HOURS="$PROJECT_MAX_WINDOW"
  fi
fi

# Window cap: the most recent commit that is strictly OLDER than the
# window horizon. Empty if the repo is brand-new (all commits younger
# than the horizon) or has no history at all.
WINDOW_CAP_SHA=$(git log -1 --format=%H --before="${MAX_WINDOW_HOURS} hours ago" 2>/dev/null || echo "")

# WINDOW_START = max(cursor, cap) by recency. Whichever is newer bounds
# the smaller window. Empty if both are empty → no delta → skip downstream.
WINDOW_START=""
WINDOW_SOURCE=""
if [ -n "$LAST_MATE_COMMIT" ] && [ -n "$WINDOW_CAP_SHA" ]; then
  # Both exist. If cursor is an ancestor of the cap, cursor is older
  # (further back in history) → cap is more recent → use cap.
  if git merge-base --is-ancestor "$LAST_MATE_COMMIT" "$WINDOW_CAP_SHA" 2>/dev/null; then
    WINDOW_START="$WINDOW_CAP_SHA"
    WINDOW_SOURCE="${MAX_WINDOW_HOURS}h-cap"
  else
    WINDOW_START="$LAST_MATE_COMMIT"
    WINDOW_SOURCE="cursor"
  fi
elif [ -n "$LAST_MATE_COMMIT" ]; then
  # Cap doesn't apply (repo has no history older than the window horizon).
  WINDOW_START="$LAST_MATE_COMMIT"
  WINDOW_SOURCE="cursor"
elif [ -n "$WINDOW_CAP_SHA" ]; then
  WINDOW_START="$WINDOW_CAP_SHA"
  WINDOW_SOURCE="${MAX_WINDOW_HOURS}h-fallback"
fi
# else: WINDOW_START remains empty → REVIEW_SET will be empty → skip.

# CHANGED_FILES: files touched between WINDOW_START and HEAD.
# Capped at 200 entries; truncation flagged in metadata.
CHANGED_FILES=""
CHANGED_FILES_COUNT=0
CHANGED_FILES_TRUNCATED="false"
if [ -n "$WINDOW_START" ]; then
  ALL_CHANGED_LIST=$(git diff --name-only "${WINDOW_START}..HEAD" 2>/dev/null || echo "")
  CHANGED_FILES_COUNT=$(printf '%s\n' "$ALL_CHANGED_LIST" | sed '/^$/d' | wc -l | tr -d ' ')
  CHANGED_FILES=$(printf '%s\n' "$ALL_CHANGED_LIST" | sed '/^$/d' | head -200)
  if [ "$CHANGED_FILES_COUNT" -gt 200 ]; then
    CHANGED_FILES_TRUNCATED="true"
  fi
fi

# ─── Cursor fallback ───────────────────────────────────────────────────────
# When the primary window is the 24h cap (cursor is older than cap, OR no
# cursor exists) AND the cap produced zero commits (no activity in the
# window) AND a cursor exists → extend the window to the cursor. Rationale:
# the cap is a cost-bounding safety net. If it produces nothing, it's
# serving no purpose, and there may still be unreviewed work since the
# last mate run. Extending to cursor catches it.
#
# Skip logic downstream (REVIEW_SET_COUNT=0) still fires if the cursor
# window is also empty — that's the "fully idle since last review" case.
if [ "$WINDOW_SOURCE" = "${MAX_WINDOW_HOURS}h-cap" ] \
   && [ "$CHANGED_FILES_COUNT" -eq 0 ] \
   && [ -n "$LAST_MATE_COMMIT" ]; then
  WINDOW_START="$LAST_MATE_COMMIT"
  WINDOW_SOURCE="cursor-fallback"
  ALL_CHANGED_LIST=$(git diff --name-only "${WINDOW_START}..HEAD" 2>/dev/null || echo "")
  CHANGED_FILES_COUNT=$(printf '%s\n' "$ALL_CHANGED_LIST" | sed '/^$/d' | wc -l | tr -d ' ')
  CHANGED_FILES=$(printf '%s\n' "$ALL_CHANGED_LIST" | sed '/^$/d' | head -200)
  if [ "$CHANGED_FILES_COUNT" -gt 200 ]; then
    CHANGED_FILES_TRUNCATED="true"
  fi
fi

# Enrich TRIGGER_CONTEXT JSON with the window metadata (observability).
# `since` is WINDOW_START (what we're actually diffing against), not
# LAST_MATE_COMMIT (which may or may not equal it).
if [ -n "$WINDOW_START" ]; then
  TRIGGER_CONTEXT=$(
    WINDOW_START="$WINDOW_START" \
    WINDOW_SOURCE="$WINDOW_SOURCE" \
    CHANGED_FILES="$CHANGED_FILES" \
    CHANGED_FILES_TRUNCATED="$CHANGED_FILES_TRUNCATED" \
    LAST_MATE_COMMIT="$LAST_MATE_COMMIT" \
    MAX_WINDOW_HOURS="$MAX_WINDOW_HOURS" \
    TRIGGER_CONTEXT="$TRIGGER_CONTEXT" \
    python3 -c "
import json, os
try:
    tc = json.loads(os.environ.get('TRIGGER_CONTEXT') or '{}')
except Exception:
    tc = {}
tc['since'] = os.environ['WINDOW_START']
tc['window_source'] = os.environ.get('WINDOW_SOURCE','')
tc['last_mate_commit'] = os.environ.get('LAST_MATE_COMMIT','')
tc['max_window_hours'] = int(os.environ.get('MAX_WINDOW_HOURS','24'))
files = [f for f in os.environ.get('CHANGED_FILES','').splitlines() if f]
tc['changed_files'] = files
tc['changed_files_truncated'] = os.environ.get('CHANGED_FILES_TRUNCATED') == 'true'
print(json.dumps(tc))
" 2>/dev/null || echo "$TRIGGER_CONTEXT")
fi

# ─── Helper: emit skip outputs and exit cleanly ─────────────────────────────
# Used by all Phase 0 skip paths. Keeps output contract consistent
# with the bounded-window skip-fast-path below: structured banner, GitHub
# Step Summary entry, contract outputs, exit 0.
#
# $1 = kind: one of self_loop | release_automation | no_human_work
#      Controls the banner title so operators can distinguish "safety
#      guard fired" from "nothing to review" at a glance in CI logs.
# $2 = reason: human-readable explanation (freeform text)
emit_skip_and_exit() {
  local kind="$1"
  local reason="$2"

  local banner_title
  local summary_label
  case "$kind" in
    self_loop)
      banner_title="SKIP — Self-loop prevention (mate reviewing own output)"
      summary_label="skipped (self-loop)" ;;
    release_automation)
      banner_title="SKIP — Nothing to analyze (release-automation commit)"
      summary_label="skipped (release automation)" ;;
    no_human_work)
      banner_title="SKIP — No unreviewed human work since last mate run"
      summary_label="skipped (no new human work)" ;;
    *)
      banner_title="SKIP — Phase 0 guard fired"
      summary_label="skipped" ;;
  esac

  echo ""
  echo "════════════════════════════════════════════════════════════════════════"
  echo "  ${banner_title}"
  echo "════════════════════════════════════════════════════════════════════════"
  echo "  mate:           ${MATE_NAME}"
  echo "  event:          ${GITHUB_EVENT_NAME:-unknown}"
  echo "  kind:           ${kind}"
  echo ""
  echo "  Reason:"
  printf '  %s\n' "$reason" | fold -s -w 70 | sed '2,$s/^/  /'
  echo ""
  echo "  Action: exiting cleanly (outcome=none, status=clean). Zero API cost."
  echo "════════════════════════════════════════════════════════════════════════"

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "outcome=none"
      echo "status=clean"
      echo "issue-url="
      echo "pr-url="
    } >> "$GITHUB_OUTPUT"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## ${MATE_NAME} — ${summary_label}"
      echo ""
      echo "${reason}"
      echo ""
      echo "_Outputs: \`outcome=none\`, \`status=clean\`._"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
}

# ─── Event-agnostic guards (apply on any trigger except workflow_dispatch) ──
# workflow_dispatch is manual invocation — a human explicitly asked, so we
# respect that and always run (no skipping).
#
# On pull_request / push / schedule, apply these checks:
#   1. PR branch starts with claude-mate/   (PRs from this mate or another)
#   2. HEAD commit message contains [claude-mate   (mate-authored merge/push)
#   3. HEAD commit message contains [skip release] (release/CHANGELOG PR)
#   4. HEAD commit message starts with "docs: Update CHANGELOG for v"
#      (defense-in-depth for CHANGELOG merges where [skip release] was
#       accidentally removed)
if [ "${GITHUB_EVENT_NAME:-}" != "workflow_dispatch" ]; then
  # Check 1: PR branch name (only populated on pull_request events)
  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] \
     && [ -n "${GITHUB_HEAD_REF:-}" ] \
     && [[ "${GITHUB_HEAD_REF}" =~ ^claude-mate/ ]]; then
    emit_skip_and_exit "self_loop" "PR branch '${GITHUB_HEAD_REF}' is mate-originated — skipping to prevent self-referencing loop."
  fi

  # Check 2: HEAD commit is mate-authored (unconditional — self-loop prevention).
  # The [claude-mate pattern catches squash-merged commits (e.g., PR title
  # "docs: ... [claude-mate:docs]"). The claude-mate/ pattern catches regular
  # merge commits (e.g., "Merge pull request #N from vlad-ko/claude-mate/docs/...").
  # Both forms mean "this commit came from a mate's own PR" — skip.
  HEAD_MSG=$(git log -1 --format=%B HEAD 2>/dev/null || echo "")
  if echo "$HEAD_MSG" | grep -qE '\[claude-mate|claude-mate/'; then
    emit_skip_and_exit "self_loop" "HEAD commit is mate-authored (claude-mate marker in message) — skipping to prevent self-referencing loop."
  fi

  # Checks 3-4: Release-automation HEAD (skip release / CHANGELOG).
  # On `schedule` events, skip these fast-bail checks and let the smarter
  # delta guard below (line ~301) handle them. The delta guard's
  # `--invert-grep` already excludes these patterns and finds the last
  # human commit underneath. Without this bypass, consumers using
  # direct-push CHANGELOG (e.g., CHANGELOG committed straight to main
  # after a release) would have a bot commit as HEAD every morning,
  # causing all nightly mates to skip even when unreviewed human work
  # exists. See #93.
  #
  # On non-schedule events (push, pull_request), the HEAD check is
  # correct: the event is for that specific commit, and a
  # release-automation commit has nothing to review.
  if [ "${GITHUB_EVENT_NAME:-}" != "schedule" ]; then
    if echo "$HEAD_MSG" | grep -qF "[skip release]"; then
      emit_skip_and_exit "release_automation" "HEAD commit carries [skip release] marker — release-automation commit, nothing for a drift mate to analyze."
    fi
    if echo "$HEAD_MSG" | grep -qE "^docs: Update CHANGELOG for v"; then
      emit_skip_and_exit "release_automation" "HEAD commit is an auto-generated CHANGELOG update — nothing for a drift mate to analyze."
    fi
  fi
fi

# ─── Schedule-only guard: "nothing human since last mate run" ───────────────
# On scheduled runs specifically, skip if this mate has already contributed
# after the last user-authored change. Prevents nightly echo-chamber drift
# (mate reviewing its own prior output).
#
# Not applied on pull_request: on a PR, the PR's diff IS the human-authored
# work; the guard above (PR branch / HEAD commit) already handles mate PRs.
if [ "${GITHUB_EVENT_NAME:-}" = "schedule" ]; then
  LAST_USER_COMMIT=$(git log --invert-grep \
      --grep='\[claude-mate' \
      --grep='docs: Update CHANGELOG for v' \
      --grep='\[skip release\]' \
      -1 --format=%H 2>/dev/null || echo "")

  if [ -n "$LAST_MATE_COMMIT" ] && [ -n "$LAST_USER_COMMIT" ] \
     && git merge-base --is-ancestor "$LAST_USER_COMMIT" "$LAST_MATE_COMMIT"; then
    emit_skip_and_exit "no_human_work" "Last user commit ($LAST_USER_COMMIT) is an ancestor of last ${MATE_NAME} mate commit ($LAST_MATE_COMMIT). No human-authored work since this mate's last contribution."
  fi
  echo "Phase 0: Nightly self-loop guard passed — human commits exist since last mate run."
fi

echo "Phase 0: event=${GITHUB_EVENT_NAME:-unknown}, TRIGGER_CONTEXT enriched (since=${LAST_MATE_COMMIT:-<none>}, changed_files=${CHANGED_FILES_COUNT}, truncated=${CHANGED_FILES_TRUNCATED})"

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

# ═══════════════════════════════════════════════════════════════════════════
# DELTA SCOPE — intersect CHANGED_FILES with ALLOWED_PATHS
#
# REVIEW_SET is what the mate will be told to review. Cases:
#   - WINDOW_START set, intersection non-empty → populate REVIEW_SET,
#     prompt will scope to it (see "## Review Window" below).
#   - WINDOW_START set, intersection empty   → skip clean. Nothing in
#     this mate's scope changed in the window; zero API cost.
#   - WINDOW_START empty                     → skip clean. No eligible
#     work (brand-new repo, or no commits older than the window
#     horizon and no prior cursor). Zero API cost.
# ═══════════════════════════════════════════════════════════════════════════
REVIEW_SET=""
REVIEW_SET_COUNT=0
if [ -n "$WINDOW_START" ] && [ -n "$CHANGED_FILES" ]; then
  if [ -n "$ALLOWED_PATHS" ]; then
    # Intersect: each changed file that matches any allowed_paths glob.
    REVIEW_SET=$(
      CHANGED_FILES="$CHANGED_FILES" \
      ALLOWED_PATHS="$ALLOWED_PATHS" \
      python3 -c "
import fnmatch, os
changed = [f for f in os.environ.get('CHANGED_FILES','').splitlines() if f]
allowed = [p.strip() for p in os.environ.get('ALLOWED_PATHS','').splitlines() if p.strip()]
for f in changed:
    if any(fnmatch.fnmatch(f, pat) for pat in allowed):
        print(f)
" 2>/dev/null || echo "")
  else
    # No allowed_paths configured — all changed files are in scope.
    REVIEW_SET="$CHANGED_FILES"
  fi
  REVIEW_SET_COUNT=$(printf '%s\n' "$REVIEW_SET" | sed '/^$/d' | wc -l | tr -d ' ')
fi

WINDOW_SHORT="<none>"
if [ -n "$WINDOW_START" ]; then
  WINDOW_SHORT="${WINDOW_START:0:7}"
fi
CURSOR_SHORT="<none>"
if [ -n "$LAST_MATE_COMMIT" ]; then
  CURSOR_SHORT="${LAST_MATE_COMMIT:0:7}"
fi
echo "Delta window: start=${WINDOW_SHORT} (source=${WINDOW_SOURCE:-none}), cursor=${CURSOR_SHORT}, max_window=${MAX_WINDOW_HOURS}h, changed=${CHANGED_FILES_COUNT} files, review_set=${REVIEW_SET_COUNT} in-scope"

# Skip-fast-path: no work in this mate's window. Three distinct kinds, each
# gets a kind-specific reason so an operator reading the CI log a week later
# can tell at a glance whether action is needed (almost always: no).
#
#   no_window      — cursor missing AND no commits older than horizon
#                    (typical for brand-new repos under the window age)
#   window_empty   — window resolved, but no commits between window start
#                    and HEAD (idle or fully reviewed since cursor)
#   none_in_scope  — commits exist in window, but none match allowed_paths
#                    (activity is in other parts of the repo)
if [ "$REVIEW_SET_COUNT" -eq 0 ]; then
  CAP_SHORT="<none — repo younger than ${MAX_WINDOW_HOURS}h>"
  if [ -n "$WINDOW_CAP_SHA" ]; then
    CAP_SHORT="${WINDOW_CAP_SHA:0:7}"
  fi

  if [ -z "$WINDOW_START" ]; then
    SKIP_KIND="no_window"
    SKIP_REASON="No window could be established. The repo has no commits older than ${MAX_WINDOW_HOURS}h AND no prior mate run exists. This is typical for brand-new repos. The next scheduled run will pick up new activity once commits accumulate."
  elif [ "$CHANGED_FILES_COUNT" -eq 0 ]; then
    SKIP_KIND="window_empty"
    SKIP_REASON="Window resolved to \`${WINDOW_SHORT}\` (${WINDOW_SOURCE}) but no files changed between there and HEAD. Either the repo has been idle since this point, or a previous mate run already reviewed everything. Nothing for this mate to do."
  else
    SKIP_KIND="none_in_scope"
    ALLOWED_DISPLAY=$(echo "$ALLOWED_PATHS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    SKIP_REASON="${CHANGED_FILES_COUNT} file(s) changed in window since \`${WINDOW_SHORT}\` (${WINDOW_SOURCE}), but NONE match this mate's allowed_paths (\`${ALLOWED_DISPLAY}\`). The activity is real, just outside this mate's domain."
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════════════"
  echo "  SKIP — bounded delta window has nothing to review (kind: ${SKIP_KIND})"
  echo "════════════════════════════════════════════════════════════════════════"
  echo "  mate:           ${MATE_NAME}"
  echo "  max_window:     ${MAX_WINDOW_HOURS}h"
  echo "  cursor:         ${CURSOR_SHORT}"
  echo "  ${MAX_WINDOW_HOURS}h cap:        ${CAP_SHORT}"
  echo "  window:         ${WINDOW_SHORT} (source: ${WINDOW_SOURCE:-none})"
  echo "  in window:      ${CHANGED_FILES_COUNT} files changed"
  echo "  in mate scope:  ${REVIEW_SET_COUNT} files"
  echo ""
  echo "  Reason:"
  printf '  %s\n' "$SKIP_REASON" | fold -s -w 70 | sed '2,$s/^/  /'
  echo ""
  echo "  Action: exiting cleanly (outcome=none, status=clean). Zero API cost."
  echo "          Next scheduled run will reassess against latest HEAD."
  echo "════════════════════════════════════════════════════════════════════════"

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "outcome=none"
      echo "status=clean"
      echo "issue-url="
      echo "pr-url="
    } >> "$GITHUB_OUTPUT"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## ${MATE_NAME} — skipped (no drift to review)"
      echo ""
      echo "**Skip kind:** \`${SKIP_KIND}\`"
      echo ""
      echo "${SKIP_REASON}"
      echo ""
      echo "| | |"
      echo "|---|---|"
      echo "| max_window | ${MAX_WINDOW_HOURS}h |"
      echo "| cursor | \`${CURSOR_SHORT}\` |"
      echo "| ${MAX_WINDOW_HOURS}h cap | \`${CAP_SHORT}\` |"
      echo "| window start | \`${WINDOW_SHORT}\` (${WINDOW_SOURCE:-none}) |"
      echo "| files in window | ${CHANGED_FILES_COUNT} |"
      echo "| files in mate scope | ${REVIEW_SET_COUNT} |"
      echo ""
      echo "_Outputs: \`outcome=none\`, \`status=clean\`. Next scheduled run will reassess._"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

# ─── Test mode: exit after Phase 0 + config + delta scope completes ─────────
# Used by tests/runner_phase0_test.sh to exercise Phase 0 guards AND the
# delta-scope skip-fast-path deterministically without invoking the Claude
# CLI or gh. Not for production use — only the test harness sets this.
if [ "${MATE_TEST_MODE:-}" = "phase0-only" ]; then
  echo "Phase 0 complete — exiting in MATE_TEST_MODE=phase0-only"
  exit 0
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

# ─── Review Window: inform the mate what code enforces ─────────────────────
# The review window is CODE-ENFORCED in Phase 2: edits to files outside
# REVIEW_SET are reverted. This prompt block tells the mate the contract
# so it doesn't waste turns on edits that will be discarded. It is NOT
# the enforcement — the runner's scope validator is.
#
# This block always renders when we reach Phase 1 — the skip-fast-path
# above already exited if there was nothing to review. No "bootstrap
# full scan" branch exists: mates NEVER scan the whole repo.
REVIEW_FILE_LIST=$(printf '%s\n' "$REVIEW_SET" | sed '/^$/d' | sed 's/^/- /')
TRUNC_NOTE=""
if [ "$CHANGED_FILES_TRUNCATED" = "true" ]; then
  TRUNC_NOTE="
(Window contained >200 files; first 200 in-scope shown.)"
fi

FULL_PROMPT="${FULL_PROMPT}

## Review Window (code-enforced, bounded delta)

Window start: \`${WINDOW_START:0:7}\` (source: ${WINDOW_SOURCE}, max_window_hours=${MAX_WINDOW_HOURS})
Files in review window (${REVIEW_SET_COUNT}):

${REVIEW_FILE_LIST}${TRUNC_NOTE}

The runner reverts any edit to a file not in this list. Work the list.
You may read other files for reference; edits outside the window are
discarded automatically. Full-repo scans are forbidden by the framework —
historical cleanup is for humans running Claude Code directly."

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
      # Claude reported findings but made no file edits. Previously this
      # path filed a GitHub issue per run, which created low-signal noise
      # in the issue tracker — findings without a concrete fix belong in
      # the CI output where a human can skim, decide, and manually file
      # an issue only if a tracked follow-up is warranted.
      #
      # Findings are rendered to:
      #   1. stdout (workflow log) — full analysis, always visible
      #   2. $GITHUB_STEP_SUMMARY — the Summary panel of the workflow run
      #
      # The uploaded /tmp/mate-*-summary.json artifact also captures the
      # outcome for programmatic consumers.
      echo ""
      echo "=== ${MATE_DESC} — Analysis Summary ==="
      printf '%s\n' "$CLAUDE_RESULT"
      echo "=== End Analysis ==="
      echo ""

      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
          echo "## ${MATE_DESC} — Findings (no file edits)"
          echo ""
          echo "_Claude reported findings but made no file edits. Rendered here instead of filed as a GitHub issue — open one manually if a tracked follow-up is needed._"
          echo ""
          echo '```'
          printf '%s\n' "$CLAUDE_RESULT"
          echo '```'
        } >> "$GITHUB_STEP_SUMMARY"
      fi

      OUTCOME="findings_in_summary"
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
  # HARD RULE: Review-window enforcement — only allow edits to files that
  # changed within the bounded delta window (REVIEW_SET). Claude may read
  # files outside this window (for context) but edits there are REVERTED.
  # This is the code-side teeth for delta scope; the prompt's "review
  # only these files" is guidance, this is enforcement.
  #
  # Always runs: if the runner reached Phase 2, there's a non-empty
  # REVIEW_SET (the skip-fast-path in Phase 0 handles empty windows).
  # ═══════════════════════════════════════════════════════════════════════
  if [ -n "$WINDOW_START" ] && [ -n "$REVIEW_SET" ]; then
    echo ""
    echo "--- Validating review window ---"

    # Re-collect after previous reverts
    CHANGED_FILES=$(git diff --name-only 2>/dev/null || echo "")
    UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
    ALL_CHANGED=$(echo -e "${CHANGED_FILES}\n${UNTRACKED_FILES}" | sed '/^$/d' | sort -u)

    # Files Claude edited that aren't in the review set = window violations
    WINDOW_VIOLATIONS=$(
      CLAUDE_CHANGED="$ALL_CHANGED" \
      REVIEW_SET_ENV="$REVIEW_SET" \
      python3 -c "
import os
changed = set(f for f in os.environ.get('CLAUDE_CHANGED','').splitlines() if f)
review  = set(f for f in os.environ.get('REVIEW_SET_ENV','').splitlines() if f)
for f in sorted(changed - review):
    print(f)
" 2>/dev/null || echo "")

    if [ -n "$WINDOW_VIOLATIONS" ]; then
      echo "::warning::Mate '$MATE_NAME' edited files outside the review window — reverting:"
      echo "$WINDOW_VIOLATIONS"
      WINDOW_VIOLATION_COUNT=$(echo "$WINDOW_VIOLATIONS" | wc -l | tr -d ' ')
      VIOLATIONS_FOUND=$((VIOLATIONS_FOUND + WINDOW_VIOLATION_COUNT))

      while IFS= read -r file; do
        if [ -n "$file" ]; then
          if git ls-files --error-unmatch "$file" 2>/dev/null; then
            git checkout -- "$file" 2>/dev/null || true
          else
            rm -f "$file" 2>/dev/null || true
          fi
          echo "  Reverted: $file (not in review window)"
        fi
      done <<< "$WINDOW_VIOLATIONS"
    else
      echo "All edits within review window."
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
    # Analysis Summary — render Claude's findings to the CI log and the
    # workflow's Job Summary panel. Historically this also filed a
    # "companion" GitHub issue that the PR closed via `Fixes #N` — but
    # the PR itself is the actionable artifact, and duplicating findings
    # into an auto-issue is pure noise in the issue tracker.
    #
    # Issues are now reserved for things a human chooses to track
    # (humans can still file an issue manually; the PR's `Fixes #N`
    # link handles it if `EXISTING_ISSUE` was found from a human-filed
    # issue with the mate label).
    # ═════════════════════════════════════════════════════════════════════
    if [ -n "$CLAUDE_RESULT" ]; then
      echo ""
      echo "=== ${MATE_DESC} — Analysis Summary ==="
      printf '%s\n' "$CLAUDE_RESULT"
      echo "=== End Analysis ==="
      echo ""

      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
          echo "## ${MATE_DESC} — Analysis (accompanies the PR below)"
          echo ""
          echo '```'
          printf '%s\n' "$CLAUDE_RESULT"
          echo '```'
        } >> "$GITHUB_STEP_SUMMARY"
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
    # Try branching from origin/main (normal); fall back to HEAD if
    # origin/main isn't locally known (shallow-fetch edge). Capture
    # stderr so failures surface in the CI log instead of vanishing.
    if ! git checkout -b "${BRANCH_NAME}" origin/main 2>/tmp/mate-checkout-error.txt; then
      echo "::warning::Could not branch from origin/main — falling back to HEAD. Reason: $(cat /tmp/mate-checkout-error.txt 2>/dev/null || echo 'unknown')"
      if ! git checkout -b "${BRANCH_NAME}" 2>/tmp/mate-checkout-error.txt; then
        echo "::error::git checkout -b failed: $(cat /tmp/mate-checkout-error.txt 2>/dev/null || echo 'unknown')"
        OUTCOME="pr_failed"
        PR_PATH_ABORTED=1
      fi
    fi

    # Each subsequent step (add/commit/push/PR) is guarded by PR_PATH_ABORTED.
    # Once any step fails, downstream steps are skipped and the script falls
    # through to the summary phase so $GITHUB_OUTPUT is still populated.
    # Without this guard, a failure at commit/push would kill the script under
    # `set -e` with zero diagnostic output — the bug this block replaces.
    if [ -z "${PR_PATH_ABORTED:-}" ]; then
      git add -A
      # The `|| echo ""` on the Fixes-line substitution is NOT cosmetic —
      # without it, `[ -n "$EXISTING_ISSUE" ]` on an empty variable (the
      # common case when no human-filed issue exists) exits 1, `&&` short-
      # circuits, `$(...)` returns non-zero, the assignment propagates that
      # exit, and `set -e` kills the script silently with zero diagnostic
      # output. See #90. Sibling substitutions in PR_BODY and the Step
      # Summary heredoc already use this safe pattern; this one didn't.
      COMMIT_MSG="${COMMIT_PREFIX}: ${MATE_DESC} findings [${LABEL_PREFIX}:${MATE_NAME}]

Automated fixes by Claude Mates ${MATE_NAME} reviewer.
$([ -n "$EXISTING_ISSUE" ] && echo "Fixes #${EXISTING_ISSUE}" || echo "")"

      if ! git commit -m "$COMMIT_MSG" 2>/tmp/mate-commit-error.txt; then
        echo "::error::git commit failed: $(cat /tmp/mate-commit-error.txt 2>/dev/null || echo 'unknown')"
        OUTCOME="pr_failed"
        PR_PATH_ABORTED=1
      fi
    fi

    if [ -z "${PR_PATH_ABORTED:-}" ]; then
      # git push stderr is no longer suppressed. The actions runner already
      # masks secret values (***) in logs, and actions/checkout@v5 uses
      # http.extraheader for auth rather than embedding the token in the
      # URL, so there's nothing sensitive to hide here.
      if ! git push origin "${BRANCH_NAME}" 2>/tmp/mate-push-error.txt; then
        echo "::error::git push failed: $(cat /tmp/mate-push-error.txt 2>/dev/null || echo 'unknown')"
        OUTCOME="pr_failed"
        PR_PATH_ABORTED=1
      fi
    fi

    # ═════════════════════════════════════════════════════════════════════
    # Create PR — title uses conventional commit prefix first so it passes
    # consumer repos' pr-title-check workflows and release automation.
    # Format: "<prefix>: <description> [<label>:<mate>]"
    # ═════════════════════════════════════════════════════════════════════
    if [ -z "${PR_PATH_ABORTED:-}" ]; then
      PR_TITLE="${COMMIT_PREFIX}: ${MATE_DESC} fixes [${LABEL_PREFIX}:${MATE_NAME}]"
      PR_BODY="## ${MATE_DESC} — Automated Fixes

Fixes identified and applied by the \`${MATE_NAME}\` Claude Mate.

$([ -n "$EXISTING_ISSUE" ] && echo "Fixes #${EXISTING_ISSUE}" || echo "")

### Changed Files
$(printf '%s\n' "$ALL_CHANGED" | while IFS= read -r f; do [ -n "$f" ] && echo "- $f"; done)
$([ "$VIOLATIONS_FOUND" -gt 0 ] && echo "
### Validation Notes
$VIOLATIONS_FOUND file(s) were reverted by the runner for violating scope or protected path rules. See CI logs for details." || echo "")
$([ -n "$CLAUDE_RESULT" ] && printf '\n### Analysis\n\n%s\n' "$CLAUDE_RESULT" || echo "")

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
        OUTCOME="pr_created"
      else
        PR_ERROR=$(cat /tmp/mate-pr-error.txt 2>/dev/null || echo "unknown error")
        echo "::error::PR creation failed: $PR_ERROR"
        OUTCOME="pr_failed"
      fi
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
  pr_created)
    echo "║  RESULT:   PR opened for human review"
    echo "║  PR:       #${PR_NUM} ${PR_URL_OUT}"
    # Guard with `if` — short-circuit `[ -n "" ] && echo` exits 1 when
    # empty. Not currently a bug (the next echo succeeds and becomes the
    # branch's last exit code) but defensive consistency with the same
    # pattern we just fixed in mates.yml.
    if [ -n "$EXISTING_ISSUE" ]; then
      echo "║  Linked:   #${EXISTING_ISSUE} (will auto-close on merge via Fixes)"
    fi
    echo "║  Files:    ${FILES_CHANGED_COUNT} changed"
    ;;
  findings_in_summary)
    echo "║  RESULT:   Findings rendered to Job Summary (no file edits)"
    echo "║  Issue:    Not created — see Analysis Summary above / in Job Summary panel"
    echo "║  PR:       Not created — no file edits to commit"
    ;;
  pr_failed)
    echo "║  RESULT:   Edits pushed to branch, but PR creation failed"
    echo "║  Branch:   ${BRANCH_NAME} (open PR manually if desired)"
    echo "║  PR:       Not created — ${PR_ERROR:-see logs above}"
    ;;
  error)
    echo "║  RESULT:   Error — Claude API/CLI failure"
    echo "║  Issue:    Not created (API error, not a finding)"
    echo "║  PR:       Not created"
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
$([ -n "$ISSUE_NUM" ] && echo "| **Issue** | #${ISSUE_NUM} |" || echo "")
$([ -n "$PR_NUM" ] && echo "| **PR** | #${PR_NUM} |" || echo "")
$([ "$FILES_CHANGED_COUNT" -gt 0 ] 2>/dev/null && echo "| **Files changed** | ${FILES_CHANGED_COUNT} |" || echo "")
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
  "since": "${LAST_MATE_COMMIT:-}",
  "window_file_count": ${CHANGED_FILES_COUNT:-0},
  "window_truncated": ${CHANGED_FILES_TRUNCATED:-false},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF

# ═══════════════════════════════════════════════════════════════════════════
# Action outputs — surface a simplified outcome to callers via $GITHUB_OUTPUT.
# Internal OUTCOME has several values; the composite action contract is:
#   outcome ∈ {none, findings, pr}
#   status  ∈ {ok, clean, error, empty}
#
#   none      — nothing to report (clean run, error, empty, violations-only)
#   findings  — Claude reported findings but made no file edits; rendered to
#               the Job Summary and workflow log (no GitHub issue filed)
#   pr        — a PR was opened (or attempted; see pr-url for success)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  case "$OUTCOME" in
    pr_created|pr_failed)
      ACTION_OUTCOME="pr" ;;
    findings_in_summary)
      ACTION_OUTCOME="findings" ;;
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
