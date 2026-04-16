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

# Helper: compute a unix-timestamp string in git's epoch format for N
# seconds ago. Avoids macOS/Linux `date -d` portability issues.
ts_seconds_ago() {
  local secs="$1"
  local now
  now=$(date +%s)
  echo "@$((now - secs)) +0000"
}

# Initialize a git repo with a BACKDATED root commit (3 days ago).
# The backdate is important: it gives the 24h-cap ancestor a commit to
# anchor on in tests that should exercise the "pass" path. A fresh init
# would leave no commits older than 24h, and the new bounded-window
# rule would skip (correctly) every time.
init_repo() {
  local dir="$1"
  git -C "$dir" init -q --initial-branch=main
  git -C "$dir" config user.email "test@local"
  git -C "$dir" config user.name "Test Harness"
  local when
  when=$(ts_seconds_ago $((3 * 86400)))
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$dir" commit -q --allow-empty -m "chore: initial commit (backdated >24h)"
}

# Initialize a repo with NO backdated history — all commits will be fresh.
# Used to test the "brand-new repo / no eligible window" skip path.
init_fresh_repo() {
  local dir="$1"
  git -C "$dir" init -q --initial-branch=main
  git -C "$dir" config user.email "test@local"
  git -C "$dir" config user.name "Test Harness"
  git -C "$dir" commit -q --allow-empty -m "chore: initial commit (fresh)"
}

# Append an empty commit (present-dated) with a given message.
# Used for mate-authored / release-automation markers where file content
# doesn't matter — only the commit message trips the self-loop guards.
add_commit() {
  local dir="$1"
  local msg="$2"
  git -C "$dir" commit -q --allow-empty -m "$msg"
}

# Append a present-dated commit that modifies an in-scope file for the
# docs mate (docs/guide.md). Creates the file if needed. Use this to
# produce a non-empty REVIEW_SET so runner.sh reaches Phase 0 complete.
add_in_scope_change() {
  local dir="$1"
  local msg="${2:-fix: human edit to docs/guide.md}"
  mkdir -p "$dir/docs"
  echo "content-$(date +%s%N)" >> "$dir/docs/guide.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$msg"
}

# Append a present-dated commit that modifies an OUT-of-scope file for
# the docs mate (app/Foo.php). Use to verify the runner skips when
# nothing in-scope changed.
add_out_of_scope_change() {
  local dir="$1"
  local msg="${2:-fix: human edit to app/Foo.php}"
  mkdir -p "$dir/app"
  echo "content-$(date +%s%N)" >> "$dir/app/Foo.php"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$msg"
}

# Append a backdated in-scope commit. Default: 3 days ago. Pass an
# explicit seconds-ago value as $3 if you need a different age.
# Simulates "old unreviewed burst" — used to exercise cursor-fallback.
add_backdated_in_scope_change() {
  local dir="$1"
  local msg="${2:-fix: docs tweak (backdated)}"
  local secs_ago="${3:-$((3 * 86400))}"
  mkdir -p "$dir/docs"
  echo "backdated-$(date +%s%N)" >> "$dir/docs/guide.md"
  git -C "$dir" add -A
  local when
  when=$(ts_seconds_ago "$secs_ago")
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$dir" commit -q -m "$msg"
}

# ─── Test runner ────────────────────────────────────────────────────────────

# run_test <test-name> <event-name> <head-ref> <expected: skip|skip-delta|pass> <skip-reason-regex-or-empty> <setup-fn> [init-fn]
# The setup function receives the tmpdir path and populates it with commits.
# Optional init-fn lets a test pick init_fresh_repo (no backdated root)
# instead of the default init_repo (3-day-old backdated root).
run_test() {
  local name="$1"
  local event_name="$2"
  local head_ref="$3"
  local expected="$4"
  local skip_reason_regex="$5"
  local setup_fn="$6"
  local init_fn="${7:-init_repo}"

  TESTS_RUN=$((TESTS_RUN + 1))
  echo ""
  echo "━━━ Test $TESTS_RUN: $name"
  echo "    event=$event_name head_ref=${head_ref:-<empty>} expected=$expected init=$init_fn"

  local tmpdir
  tmpdir=$(mktemp -d -t runner-test-XXXXXX)
  local github_output_file="$tmpdir/.gh_output"
  local step_summary_file="$tmpdir/.gh_step_summary"
  local stdout_file="$tmpdir/.stdout"
  : > "$github_output_file"
  : > "$step_summary_file"

  # Initialize repo and apply per-test commit history
  "$init_fn" "$tmpdir"
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
      # Self-loop guard fired → banner in stdout, outcome=none in $GITHUB_OUTPUT
      if ! grep -qi "self-loop guard" "$stdout_file"; then
        fail "$name" "expected self-loop guard to fire, but stdout has no 'self-loop guard' banner" "$stdout_file" "$github_output_file"
      elif [ -n "$skip_reason_regex" ] && ! grep -qE "$skip_reason_regex" "$stdout_file"; then
        fail "$name" "skip reason didn't match pattern '$skip_reason_regex'" "$stdout_file" "$github_output_file"
      elif ! grep -q "outcome=none" "$github_output_file"; then
        fail "$name" "GITHUB_OUTPUT missing outcome=none" "$stdout_file" "$github_output_file"
      else
        pass "$name"
      fi
      ;;
    skip-delta)
      # Delta-window fast-path fired → window resolved to empty, no API call
      if ! grep -q "bounded delta window has nothing to review" "$stdout_file"; then
        fail "$name" "expected delta-window skip, but stdout has no 'bounded delta window has nothing to review' banner" "$stdout_file" "$github_output_file"
      elif [ -n "$skip_reason_regex" ] && ! grep -qE "$skip_reason_regex" "$stdout_file"; then
        fail "$name" "delta-skip reason didn't match pattern '$skip_reason_regex'" "$stdout_file" "$github_output_file"
      elif ! grep -q "outcome=none" "$github_output_file"; then
        fail "$name" "GITHUB_OUTPUT missing outcome=none" "$stdout_file" "$github_output_file"
      elif ! grep -q "status=clean" "$github_output_file"; then
        fail "$name" "GITHUB_OUTPUT missing status=clean" "$stdout_file" "$github_output_file"
      else
        pass "$name"
      fi
      ;;
    pass)
      # Guard did NOT fire → reached the end-of-Phase-0 marker
      if grep -qi "self-loop guard" "$stdout_file" && grep -q "exiting cleanly" "$stdout_file"; then
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
  add_in_scope_change "$dir" "feat: add docs/guide.md"
  add_in_scope_change "$dir" "fix: tweak docs/guide.md"
}

setup_mate_then_human() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: initial docs"
  add_commit "$dir" "docs: docs mate findings [claude-mate:docs]"
  add_in_scope_change "$dir" "fix: human edit AFTER the mate commit"
}

setup_human_then_mate() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: initial docs"
  add_commit "$dir" "docs: docs mate findings [claude-mate:docs]"
  # No human commit after the mate's — the guard should fire
}

setup_head_is_mate_bracketed() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: initial docs"
  add_commit "$dir" "docs: cleanup [claude-mate:docs]"
}

setup_head_is_mate_merge() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: initial docs"
  # Simulate a merge commit referencing a claude-mate/ branch
  add_commit "$dir" "Merge pull request #42 from vlad-ko/claude-mate/docs/2026-04-12"
}

setup_head_is_skip_release() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: initial docs"
  add_commit "$dir" "docs: Update CHANGELOG for v0.6.1 [skip release]"
}

setup_head_is_changelog_docs() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: initial docs"
  # This commit starts with 'docs: Update CHANGELOG for v' — defense-in-depth guard
  add_commit "$dir" "docs: Update CHANGELOG for v0.7.0"
}

# Schedule + HEAD=[skip release] + human commit below.
# The delta guard should look past the bot HEAD and find the human work.
setup_schedule_skip_release_with_human_below() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: human added docs/guide.md"
  add_commit "$dir" "docs: Update CHANGELOG for v1.4.1 [skip release]"
}

# Schedule + HEAD=CHANGELOG (no [skip release]) + human commit below.
setup_schedule_changelog_with_human_below() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: human added docs/guide.md"
  add_commit "$dir" "docs: Update CHANGELOG for v1.4.0"
}

# Schedule + HEAD=[skip release] + NO human commits (only backdated root + bot).
# Delta guard should find nothing to review and skip cleanly.
setup_schedule_skip_release_no_human() {
  local dir="$1"
  add_commit "$dir" "docs: Update CHANGELOG for v1.0.0 [skip release]"
}

# ─── Delta-scope setups (touch actual files in/out of docs mate scope) ──────
# docs mate's allowed_paths: docs/**, CLAUDE.md, README.md, *.md

# Mate contribution + later human commits that touch ONLY out-of-scope files.
# Delta scope should skip: nothing in docs mate's scope changed since cursor.
setup_delta_out_of_scope() {
  local dir="$1"
  # Initial state: an in-scope file exists but won't be touched after the cursor
  mkdir -p "$dir/docs" "$dir/app"
  echo "initial docs" > "$dir/docs/guide.md"
  echo "initial code" > "$dir/app/Foo.php"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "feat: initial state"

  # Mate contribution — sets the cursor
  echo "mate touched" > "$dir/docs/guide.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "docs: mate finding [claude-mate:docs]"

  # Human commits AFTER cursor, but only outside docs mate's scope
  echo "updated code" > "$dir/app/Foo.php"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fix: update app (out of docs scope)"

  echo "more code" >> "$dir/app/Foo.php"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fix: more code changes (still out of docs scope)"
}

# Mate contribution + later human commits that touch IN-scope files.
# Delta scope should pass through — review set is non-empty.
setup_delta_in_scope() {
  local dir="$1"
  mkdir -p "$dir/docs"
  echo "initial" > "$dir/docs/guide.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "docs: add initial guide"

  # Mate contribution — sets the cursor
  echo "mate edit" > "$dir/docs/guide.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "docs: mate finding [claude-mate:docs]"

  # Human commit AFTER cursor, IN scope
  echo "human edit" > "$dir/docs/guide.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fix: human updates docs/guide.md"

  # Another out-of-scope change, but review_set is still non-empty because
  # of the docs/guide.md change above. Delta scope should still proceed.
  mkdir -p "$dir/app"
  echo "unrelated" > "$dir/app/Bar.php"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fix: unrelated app change"
}

# Cursor exists but is OLD (> 24h). Recent burst of in-scope commits
# happened BEFORE 24h, then repo went idle. The 24h cap primary window
# is empty → fallback to cursor should fire → review the 2-day-old burst.
#
# Timeline (all before "now"):
#   T-5d:  mate cursor (initial docs + mate finding [claude-mate:docs])
#   T-2d:  in-scope burst (unreviewed since cursor, before 24h window)
#   now:   HEAD = T-2d (nothing in last 24h)
setup_cap_empty_cursor_has_work() {
  local dir="$1"
  # Backdated mate cursor (5 days ago)
  local five_days
  five_days=$(ts_seconds_ago $((5 * 86400)))
  mkdir -p "$dir/docs"
  echo "initial" > "$dir/docs/guide.md"
  git -C "$dir" add -A
  GIT_AUTHOR_DATE="$five_days" GIT_COMMITTER_DATE="$five_days" \
    git -C "$dir" commit -q -m "docs: initial guide"
  GIT_AUTHOR_DATE="$five_days" GIT_COMMITTER_DATE="$five_days" \
    git -C "$dir" commit -q --allow-empty -m "docs: mate finding [claude-mate:docs]"

  # Unreviewed burst 2 days ago — still OUTSIDE the 24h primary window
  add_backdated_in_scope_change "$dir" "fix: docs tweak (2 days ago)" $((2 * 86400))
}

# Cursor exists, cursor is OLD, NO commits since cursor. Primary 24h
# window empty, fallback cursor window ALSO empty → skip.
#
# Timeline:
#   T-10d: mate cursor
#   now:   HEAD = T-10d (nothing since)
setup_cap_empty_cursor_empty() {
  local dir="$1"
  local ten_days
  ten_days=$(ts_seconds_ago $((10 * 86400)))
  mkdir -p "$dir/docs"
  echo "initial" > "$dir/docs/guide.md"
  git -C "$dir" add -A
  GIT_AUTHOR_DATE="$ten_days" GIT_COMMITTER_DATE="$ten_days" \
    git -C "$dir" commit -q -m "docs: initial guide"
  GIT_AUTHOR_DATE="$ten_days" GIT_COMMITTER_DATE="$ten_days" \
    git -C "$dir" commit -q --allow-empty -m "docs: mate finding [claude-mate:docs]"
  # An empty present-dated commit on top of the cursor moves HEAD past
  # the mate marker (so the self-loop guard doesn't preempt) without
  # adding any file changes (so the delta-window skip path is exercised).
  # cap = the 10-day-old commit older than 24h; cursor = mate finding;
  # HEAD = this empty commit. Diff cap..HEAD = empty, fallback diff
  # cursor..HEAD = empty → skip-delta.
  add_commit "$dir" "chore: noop (HEAD past cursor, no file changes)"
}

# Brand-new repo: pairs with init_fresh_repo. No backdated history, no
# cursor. All commits are within the 24h horizon → cap empty, no
# fallback target → skip clean.
setup_brand_new_repo() {
  local dir="$1"
  add_in_scope_change "$dir" "feat: first commit on a brand-new repo"
}

# ─── Test cases ─────────────────────────────────────────────────────────────

echo "Running Phase 0 integration tests against $RUNNER"
echo ""

# Schedule events
run_test "schedule: no prior mate commit → pass" \
  "schedule" "" "pass" "" setup_human_only

run_test "schedule: mate commit with newer in-scope human commit → pass" \
  "schedule" "" "pass" "" setup_mate_then_human
# Human commit after the cursor edits an in-scope file → REVIEW_SET
# non-empty → run proceeds past delta check to Phase 0 complete.

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

# workflow_dispatch — bypasses self-loop guards, but still applies delta scope
run_test "workflow_dispatch with mate-authored HEAD (no later changes) → skip-delta (window_empty)" \
  "workflow_dispatch" "" "skip-delta" "kind: window_empty" setup_head_is_mate_bracketed
# Note: self-loop guard is bypassed on workflow_dispatch (manual intent),
# but delta scope still fires — cursor exists, nothing changed since,
# nothing to review. The skip is honest and costs zero API dollars.

run_test "workflow_dispatch from claude-mate/ branch → pass (manual bypass)" \
  "workflow_dispatch" "claude-mate/docs/2026-04-12" "pass" "" setup_human_only

# ─── Bounded delta window tests ─────────────────────────────────────────────
# Cover the "review only files changed since last run OR last 24h" contract.

run_test "workflow_dispatch: cursor exists, only out-of-scope changes → skip-delta (none_in_scope)" \
  "workflow_dispatch" "" "skip-delta" "kind: none_in_scope" setup_delta_out_of_scope

run_test "workflow_dispatch: cursor exists, in-scope changes → pass" \
  "workflow_dispatch" "" "pass" "" setup_delta_in_scope

run_test "schedule: cursor exists, in-scope changes → pass" \
  "schedule" "" "pass" "" setup_delta_in_scope

# No cursor: window falls back to the 24h cap (the backdated root from init_repo
# is 3 days old, so it anchors the cap). Fresh in-scope commits fall in the
# cap..HEAD window → REVIEW_SET non-empty → pass via 24h-fallback.
run_test "schedule: no cursor + in-scope changes → pass (24h fallback)" \
  "schedule" "" "pass" "" setup_human_only

# Brand-new repo: init_fresh_repo (NO backdated root) + commits all within
# 24h. No cursor, no cap → WINDOW_START empty → skip clean. This is the
# "brand-new or idle repo" skip path.
run_test "schedule: brand-new repo (no old commits, no cursor) → skip-delta (no_window)" \
  "schedule" "" "skip-delta" "kind: no_window" setup_brand_new_repo init_fresh_repo

# Cursor-fallback: cursor is older than 24h, NO commits in last 24h, but
# there IS unreviewed work between cursor and HEAD (e.g., a 2-day-old
# burst). Primary window (cap) is empty → fallback to cursor → pass.
# This is the rule "if no commits in last 24h, fall back to last mate run."
run_test "schedule: cap empty + cursor has unreviewed work → pass (cursor-fallback)" \
  "schedule" "" "pass" "" setup_cap_empty_cursor_has_work

# Skip case: cursor exists but BOTH windows are empty. Truly idle since
# the last review. The fallback is computed but yields nothing → skip.
run_test "schedule: cap empty + cursor empty (fully idle since last review) → skip-delta (window_empty)" \
  "schedule" "" "skip-delta" "kind: window_empty" setup_cap_empty_cursor_empty

# ─── Schedule + release-automation HEAD (regression tests for #93) ──────────
# Direct-push CHANGELOG flow leaves a bot commit as HEAD on main. The Phase 0
# HEAD check used to bail immediately; now on schedule events it falls through
# to the delta guard which looks past bot commits for human work.

run_test "schedule: HEAD=[skip release] + human commit below → pass (delta guard finds human work)" \
  "schedule" "" "pass" "" setup_schedule_skip_release_with_human_below

run_test "schedule: HEAD=CHANGELOG + human commit below → pass (delta guard finds human work)" \
  "schedule" "" "pass" "" setup_schedule_changelog_with_human_below

run_test "schedule: HEAD=[skip release] + no human commit → skip-delta (delta guard catches it)" \
  "schedule" "" "skip-delta" "" setup_schedule_skip_release_no_human

# Verify PR events STILL bail on release-automation HEAD (unchanged behavior)
run_test "pull_request: HEAD=[skip release] → skip (unchanged)" \
  "pull_request" "" "skip" "skip release" setup_head_is_skip_release

run_test "pull_request: HEAD=CHANGELOG → skip (unchanged)" \
  "pull_request" "" "skip" "auto-generated CHANGELOG" setup_head_is_changelog_docs

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
