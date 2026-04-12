#!/bin/bash
# shellcheck disable=SC2329  # Functions are invoked indirectly via "$setup_fn"
# Integration tests for runner.sh Phase 0 (self-loop guards + metadata enrichment).
#
# These tests create temp git repositories with known commit histories, set
# GitHub-Actions-like env vars, and invoke runner.sh in MATE_TEST_MODE=phase0-only.
# That env var early-exits runner.sh after Phase 0 — no Claude CLI, no gh, no
# API calls, fully deterministic.
#
# Runs via: bash tests/runner_phase0_test.sh
# CI: invoked from .github/workflows/pr-checks.yml as the runner-tests job.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/runner.sh"
MATE_DIR="$REPO_ROOT/mates/docs"  # Use the real docs mate — runner.sh needs a valid PROMPT.md

TESTS_RUN=0
FAILURES=0

if [ ! -f "$RUNNER" ]; then
  echo "FATAL: runner.sh not found at $RUNNER" >&2
  exit 1
fi

if [ ! -f "$MATE_DIR/PROMPT.md" ]; then
  echo "FATAL: mate PROMPT.md not found at $MATE_DIR/PROMPT.md" >&2
  exit 1
fi

# ─── Test scenario setup helpers ────────────────────────────────────────────

# Initialize a bare git repo with a single initial commit, so git log has something.
init_repo() {
  local dir="$1"
  git -C "$dir" init -q --initial-branch=main
  git -C "$dir" config user.email "test@local"
  git -C "$dir" config user.name "Test Harness"
  git -C "$dir" commit -q --allow-empty -m "chore: initial commit"
}

# Append a commit to the repo with a given message.
add_commit() {
  local dir="$1"
  local msg="$2"
  git -C "$dir" commit -q --allow-empty -m "$msg"
}

# ─── Test runner ────────────────────────────────────────────────────────────

# run_test <test-name> <event-name> <head-ref> <expected: skip|pass> <skip-reason-regex-or-empty> <setup-fn>
# The setup function receives the tmpdir path and populates it with commits.
run_test() {
  local name="$1"
  local event_name="$2"
  local head_ref="$3"
  local expected="$4"
  local skip_reason_regex="$5"
  local setup_fn="$6"

  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo "━━━ Test $TESTS_RUN: $name"
  echo "    event=$event_name head_ref=${head_ref:-<empty>} expected=$expected"

  local tmpdir
  tmpdir=$(mktemp -d -t runner-test-XXXXXX)
  local github_output_file="$tmpdir/.gh_output"
  local step_summary_file="$tmpdir/.gh_step_summary"
  local stdout_file="$tmpdir/.stdout"
  : > "$github_output_file"
  : > "$step_summary_file"

  # Initialize repo and apply per-test commit history
  init_repo "$tmpdir"
  "$setup_fn" "$tmpdir"

  # Run runner.sh in test mode (Phase 0 only)
  local exit_code=0
  (
    cd "$tmpdir"
    MATE_TEST_MODE=phase0-only \
    GITHUB_EVENT_NAME="$event_name" \
    GITHUB_HEAD_REF="$head_ref" \
    GITHUB_OUTPUT="$github_output_file" \
    GITHUB_STEP_SUMMARY="$step_summary_file" \
    TRIGGER_CONTEXT='{"event":"test"}' \
    bash "$RUNNER" "docs" "$MATE_DIR" "$tmpdir/.claude-mates.yml"
  ) > "$stdout_file" 2>&1 || exit_code=$?

  # All test cases should exit 0 (either clean skip or pass-through exit)
  if [ "$exit_code" -ne 0 ]; then
    fail "$name" "exit code $exit_code (expected 0)" "$stdout_file" "$github_output_file"
    rm -rf "$tmpdir"
    return
  fi

  case "$expected" in
    skip)
      # Guard fired → skip message in stdout, outcome=none in $GITHUB_OUTPUT
      if ! grep -q "Self-loop guard" "$stdout_file"; then
        fail "$name" "expected guard to fire, but stdout has no 'Self-loop guard' message" "$stdout_file" "$github_output_file"
      elif [ -n "$skip_reason_regex" ] && ! grep -qE "$skip_reason_regex" "$stdout_file"; then
        fail "$name" "skip reason didn't match pattern '$skip_reason_regex'" "$stdout_file" "$github_output_file"
      elif ! grep -q "outcome=none" "$github_output_file"; then
        fail "$name" "GITHUB_OUTPUT missing outcome=none" "$stdout_file" "$github_output_file"
      else
        pass "$name"
      fi
      ;;
    pass)
      # Guard did NOT fire → reached the end-of-Phase-0 marker
      if grep -q "Self-loop guard" "$stdout_file" && grep -q "skipping" "$stdout_file"; then
        fail "$name" "expected guard to pass, but stdout shows a skip" "$stdout_file" "$github_output_file"
      elif ! grep -q "Phase 0 complete — exiting in MATE_TEST_MODE=phase0-only" "$stdout_file"; then
        fail "$name" "didn't reach Phase-0-complete marker" "$stdout_file" "$github_output_file"
      else
        pass "$name"
      fi
      ;;
    *)
      fail "$name" "unknown expected value: $expected" "$stdout_file" "$github_output_file"
      ;;
  esac

  rm -rf "$tmpdir"
}

pass() {
  echo "    ✓ PASS: $1"
}

fail() {
  local name="$1"
  local reason="$2"
  local stdout_file="$3"
  local output_file="$4"
  echo "    ✗ FAIL: $name"
  echo "      reason: $reason"
  echo "      --- stdout ---"
  sed 's/^/      /' "$stdout_file" | head -40
  echo "      --- GITHUB_OUTPUT ---"
  sed 's/^/      /' "$output_file"
  FAILURES=$((FAILURES + 1))
}

# ─── Test scenario setups ───────────────────────────────────────────────────

setup_human_only() {
  local dir="$1"
  add_commit "$dir" "feat: add a thing"
  add_commit "$dir" "fix: correct a bug"
}

setup_mate_then_human() {
  local dir="$1"
  add_commit "$dir" "feat: initial human work"
  add_commit "$dir" "docs: docs mate findings [claude-mate:docs]"
  add_commit "$dir" "fix: human commit AFTER the mate commit"
}

setup_human_then_mate() {
  local dir="$1"
  add_commit "$dir" "feat: initial human work"
  add_commit "$dir" "docs: docs mate findings [claude-mate:docs]"
  # No human commit after the mate's — the guard should fire
}

setup_head_is_mate_bracketed() {
  local dir="$1"
  add_commit "$dir" "feat: human work"
  add_commit "$dir" "docs: cleanup [claude-mate:docs]"
}

setup_head_is_mate_merge() {
  local dir="$1"
  add_commit "$dir" "feat: human work"
  # Simulate a merge commit referencing a claude-mate/ branch
  add_commit "$dir" "Merge pull request #42 from vlad-ko/claude-mate/docs/2026-04-12"
}

setup_head_is_skip_release() {
  local dir="$1"
  add_commit "$dir" "feat: human work"
  add_commit "$dir" "docs: Update CHANGELOG for v0.6.1 [skip release]"
}

setup_head_is_changelog_docs() {
  local dir="$1"
  add_commit "$dir" "feat: human work"
  # This commit starts with 'docs: Update CHANGELOG for v' — defense-in-depth guard
  add_commit "$dir" "docs: Update CHANGELOG for v0.7.0"
}

# ─── Test cases ─────────────────────────────────────────────────────────────

echo "Running Phase 0 integration tests against $RUNNER"
echo ""

# Schedule events
run_test "schedule: no prior mate commit → pass" \
  "schedule" "" "pass" "" setup_human_only

run_test "schedule: mate commit with newer human commit → pass" \
  "schedule" "" "pass" "" setup_mate_then_human

run_test "schedule: mate commit with NO newer human commit → skip" \
  "schedule" "" "skip" "mate-authored|No human-authored work" setup_human_then_mate
# Note: this scenario is skipped by the event-agnostic HEAD-is-mate guard
# first (since HEAD matches [claude-mate). The nightly-specific "no human
# work since last mate run" guard would also fire but never runs because
# we've already exited. Both guards cover the case; event-agnostic wins.

# pull_request events — PR branch name
run_test "pull_request from claude-mate/* branch → skip" \
  "pull_request" "claude-mate/docs/2026-04-12" "skip" "PR branch.*is mate-originated" setup_human_only

run_test "pull_request from normal branch → pass" \
  "pull_request" "feature/add-thing" "pass" "" setup_human_only

# pull_request events — HEAD commit message patterns
run_test "pull_request with [claude-mate HEAD commit → skip" \
  "pull_request" "fix/squash-merged-mate" "skip" "mate-authored" setup_head_is_mate_bracketed

run_test "pull_request with 'Merge ... claude-mate/' HEAD → skip" \
  "pull_request" "fix/merge-commit" "skip" "mate-authored" setup_head_is_mate_merge

run_test "pull_request with [skip release] HEAD → skip" \
  "pull_request" "chore/changelog-v0.6.1" "skip" "skip release" setup_head_is_skip_release

run_test "pull_request with 'docs: Update CHANGELOG for v' HEAD → skip" \
  "pull_request" "some-branch" "skip" "CHANGELOG update" setup_head_is_changelog_docs

# push events — same HEAD commit guards
run_test "push of [claude-mate HEAD → skip" \
  "push" "" "skip" "mate-authored" setup_head_is_mate_bracketed

run_test "push of normal HEAD → pass" \
  "push" "" "pass" "" setup_human_only

# workflow_dispatch — always runs, bypasses guards
run_test "workflow_dispatch with mate-authored HEAD → pass (manual bypass)" \
  "workflow_dispatch" "" "pass" "" setup_head_is_mate_bracketed

run_test "workflow_dispatch from claude-mate/ branch → pass (manual bypass)" \
  "workflow_dispatch" "claude-mate/docs/2026-04-12" "pass" "" setup_human_only

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAILURES" -eq 0 ]; then
  echo "✓ All $TESTS_RUN tests passed."
  exit 0
else
  echo "✗ $FAILURES of $TESTS_RUN tests FAILED."
  exit 1
fi
