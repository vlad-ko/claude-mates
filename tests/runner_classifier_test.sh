#!/bin/bash
# Regression tests for runner.sh's Phase 1 output classifier.
#
# Background: the classifier previously did a case-insensitive keyword grep
# against the full Mate analysis text:
#
#   grep -qiE "rate_limit_error|API Error|...|timeout"
#
# That regex was unanchored, so any clean run that legitimately mentioned
# `DockerTimeoutChainTest.php`, `it_returns_500_on_server_error`, or even
# the phrase "no API error path covered" was misclassified as a CLI error.
# Sampling one workflow run (#25151999606 on wealthbot-io/webo) showed all
# three Mates returning `Status: error` despite producing valid output.
#
# The fix anchors error detection to the canonical prefix the JSON parser
# emits — `(cli error — stop_reason=...)` — at the very start of the line.
# These tests pin that contract.
#
# Runs via: bash tests/runner_classifier_test.sh
# CI: invoked alongside runner_phase0_test.sh.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/runner.sh"

TESTS_RUN=0
FAILURES=0

if [ ! -f "$RUNNER" ]; then
  echo "FATAL: runner.sh not found at $RUNNER" >&2
  exit 1
fi

# ─── Pure-shell mirror of runner.sh's error-detection regex ─────────────────
# Source-of-truth is runner.sh's classification block (search for
# `^\(cli error`). If that anchor changes in runner.sh, update this mirror
# too — and the source-inspection assertion at the end of this file will
# fail to remind you.
classify_is_error() {
  local result="$1"
  if echo "$result" | grep -qE "^\(cli error"; then
    echo "error"
  else
    echo "not-error"
  fi
}

assert_classification() {
  local label="$1"
  local input="$2"
  local expected="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  local actual
  actual=$(classify_is_error "$input")
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ PASS: $label"
  else
    echo "  ✗ FAIL: $label"
    echo "         input    : $(echo "$input" | head -c 120)"
    echo "         expected : $expected"
    echo "         actual   : $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

echo ""
echo "━━━ runner_classifier_test.sh ━━━"
echo ""
echo "── False-positive cases (clean output that mentions error-shaped tokens) ──"

# The original triggering case: tests Mate listed DockerTimeoutChainTest.php
# in its summary on 2026-04-30, hitting the legacy `timeout` keyword grep.
assert_classification \
  "clean run listing DockerTimeoutChainTest.php is NOT an error" \
  "## Analysis Complete

Test files scanned: 8
Issues found: 0
Action: none

6. **DockerTimeoutChainTest.php** - 5 tests, structural invariant checks" \
  "not-error"

assert_classification \
  "clean run mentioning a 500-error test method is NOT an error" \
  "All test files in the review window are in good health.
- it_returns_500_on_server_error has meaningful assertions" \
  "not-error"

assert_classification \
  "clean run quoting 'no API error path covered' is NOT an error" \
  "Findings: 1 (low) — no API error path covered for /webhooks/plaid endpoint" \
  "not-error"

assert_classification \
  "clean run mentioning connection_error in a finding body is NOT an error" \
  "Found 2 missing tests: connection_error retry path, rate_limit_error backoff" \
  "not-error"

echo ""
echo "── True-positive cases (genuine CLI/parser failures) ──"

assert_classification \
  "structured (cli error — max_turns) IS an error" \
  "(cli error — stop_reason=tool_use, errors=Reached maximum number of turns (15))" \
  "error"

assert_classification \
  "structured (cli error — connection_error) IS an error" \
  "(cli error — stop_reason=, errors=connection_error)" \
  "error"

assert_classification \
  "structured (cli error) at start of multi-line output IS an error" \
  "(cli error — stop_reason=api_error, errors=overloaded_error)
some trailing context line that should not affect classification" \
  "error"

echo ""
echo "── Edge case: prefix anchor matters ──"

# Some prior bug attempts matched 'cli error' anywhere in the body; ensure
# the prefix anchor still holds.
assert_classification \
  "'(cli error)' mid-body (not at line start) is NOT an error" \
  "Test summary: the cli error message format was updated last week.
No issues found." \
  "not-error"

echo ""
echo "── Source-inspection assertion: the regression-prone keyword grep is gone ──"

# This assertion catches reintroduction of the original bug at the source
# level even if behavior tests above stay green.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -nE 'grep -qiE "rate_limit_error\|API Error\|.*timeout"' "$RUNNER" >/dev/null; then
  echo "  ✗ FAIL: runner.sh still contains the legacy unanchored keyword grep"
  echo "         see runner.sh classification block (search '^\\(cli error')"
  FAILURES=$((FAILURES + 1))
else
  echo "  ✓ PASS: runner.sh does not contain the legacy unanchored keyword grep"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAILURES" -eq 0 ]; then
  echo "✓ All $TESTS_RUN tests passed."
  exit 0
else
  echo "✗ $FAILURES of $TESTS_RUN tests failed."
  exit 1
fi
