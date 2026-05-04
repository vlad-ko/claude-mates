# Claude Mates — workflow examples

Claude Mates ships as a GitHub composite action (`vlad-ko/claude-mates`). Drop one of the patterns below into your consumer repo under `.github/workflows/` — no file copying, no `claude-mates-framework` checkout, no per-release template updates.

See the repo root [README.md](../README.md) for the `.claude-mates.yml` config schema and the list of available mates.

## Prerequisites

1. **Secret**: `CLAUDE_MATES_API_KEY` — an Anthropic API key.
2. **Repo setting**: Settings → Actions → General → Workflow permissions → enable *"Allow GitHub Actions to create and approve pull requests"*.
3. **Config file**: `.claude-mates.yml` in your repo root (enable/disable mates, override models, set scopes, deny rules).

## How mates review work (v0.9.0+) — bounded delta window

Each mate reviews a **bounded delta**, never the whole repo. For every run the framework computes:

- **Window start** = whichever is more recent of (a) the last commit this mate authored, or (b) `now - max_window_hours` (default 24h).
- **Fallback**: if the 24h window is empty AND a cursor exists, extend to cursor — catches unreviewed work that predates the horizon (e.g. a 3-day-old burst with nothing since).
- **Review set** = files changed in that window ∩ mate's `allowed_paths`.

If the review set is empty, the run **skips cleanly** (zero API cost). Skips surface with a structured banner tagged by **kind** so you can tell at a glance what happened:

| kind | Meaning | Operator action |
|---|---|---|
| `no_window` | No cursor AND no commits older than the horizon (brand-new repo) | Wait until commits accumulate; next run will pick up |
| `window_empty` | Window resolved but zero commits since → HEAD | Repo idle or fully reviewed; nothing to do |
| `none_in_scope` | Commits exist in window, none match `allowed_paths` | Activity real, outside this mate's domain |

Override the default with `max_window_hours` in `.claude-mates.yml` (no upper bound):

```yaml
mates:
  docs:
    max_window_hours: 168   # review the last week (e.g. catching up after an outage)
```

---

## Pattern 1 — one mate, one workflow (recommended for fine-grained control)

Use this when you want each mate to have its own cron, retention, and easily-togglable workflow in the GitHub UI.

```yaml
name: "Mate: Docs"

on:
  schedule:
    - cron: '0 6 * * 1-5'  # Weekdays 6am UTC
  workflow_dispatch: {}

concurrency:
  group: mate-docs
  cancel-in-progress: false

jobs:
  docs:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: write
      pull-requests: write
      issues: write

    steps:
      - uses: actions/checkout@v5
        with:
          # The self-loop guard in runner.sh looks back through recent commits
          # to find the last human-authored commit. 100 is a safe default.
          fetch-depth: 100

      - uses: vlad-ko/claude-mates@v0.9.5
        with:
          mate: docs
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
```

Duplicate the file and swap `docs` for `tests`, `dead-code`, `logic`, or `security` to add more mates.

## Pattern 2 — matrix, one workflow, N mates (recommended for most adopters)

One file, five mates, parallel execution, per-mate concurrency groups. Simpler to maintain.

```yaml
name: Mates

on:
  schedule:
    - cron: '0 6 * * 1-5'
  workflow_dispatch: {}

jobs:
  mate:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: write
      pull-requests: write
      issues: write

    strategy:
      fail-fast: false
      matrix:
        mate: [docs, tests, dead-code]  # enable whichever you want

    concurrency:
      group: mate-${{ matrix.mate }}
      cancel-in-progress: false

    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 100

      - uses: vlad-ko/claude-mates@v0.9.5
        with:
          mate: ${{ matrix.mate }}
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
```

Each matrix leg is an independent job — separate log stream, separate concurrency group, one mate's failure does not cancel the others (`fail-fast: false`).

---

## Reacting to the action's outputs

The action surfaces five outputs so downstream steps can branch on what the mate produced:

| Output | Values |
|---|---|
| `outcome` | `none` \| `findings` \| `pr` |
| `status` | `ok` \| `clean` \| `error` \| `empty` |
| `issue-url` | Always empty (drift mates render to Job Summary; security mate posts inline PR comments) |
| `pr-url` | URL of created PR, or empty (drift mates only) |
| `findings-count` | Number of findings reported (security mate only) |

```yaml
      - id: mate
        uses: vlad-ko/claude-mates@v0.9.0
        with:
          mate: docs
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}

      - name: Post to Slack when a PR lands
        if: steps.mate.outputs.outcome == 'pr'
        env:
          # Pass outputs via env:, NOT inline `${{ }}` in the run: body.
          # `${{ }}` substitution happens before bash sees the command,
          # so shell metacharacters in the value would execute. Env-var
          # references are inert.
          PR_URL: ${{ steps.mate.outputs.pr-url }}
          SLACK_WEBHOOK: ${{ secrets.SLACK_WEBHOOK }}
        run: |
          curl -XPOST "$SLACK_WEBHOOK" -d "{\"text\":\"Mate opened $PR_URL\"}"
```

---

## The security mate is PR-scoped (a thin wrapper over Anthropic's scanner)

Unlike the drift mates, `mate: security` is a **pre-merge policy gate**, not a nightly scan. Internally, the action delegates to [`anthropics/claude-code-security-review`](https://github.com/anthropics/claude-code-security-review) pinned to a specific commit — battle-tested by Anthropic, with Opus 4.1 as default, diff-aware analysis, false-positive filtering tuned for security, and line-accurate inline PR comments.

**Invoke it from a `pull_request` workflow, NOT from the nightly matrix.** The action fails early if invoked outside a `pull_request` event.

```yaml
name: Security
on:
  pull_request:
    branches: [main]

concurrency:
  group: security-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  security:
    runs-on: ubuntu-latest
    timeout-minutes: 25
    permissions:
      pull-requests: write   # For inline review comments
      contents: read
    steps:
      - uses: actions/checkout@v5
        with:
          ref: ${{ github.event.pull_request.head.sha || github.sha }}
          fetch-depth: 2
      - uses: vlad-ko/claude-mates@v0.9.5
        with:
          mate: security
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
```

Optional config in `.claude-mates.yml`:

```yaml
mates:
  security:
    exclude_directories:
      - vendor
      - node_modules
      - public/build
      - storage
```

If omitted, a sensible default exclude list is applied.

### Why is security a wrapper (and not a generic claude-mate)?

Earlier versions of this framework had `mates/security/PROMPT.md` — a generic Claude Code prompt for security review. That was removed in v0.5.0 because Anthropic publishes a specialized action that's strictly better for this concern:

- Diff-aware (only analyzes changed files, not the entire repo every run)
- False-positive filtering tuned specifically for security findings
- Line-accurate inline PR comments on the exact vulnerable line
- Uses Opus 4.1 by default for deeper semantic analysis
- Maintained by Anthropic — stays current with model upgrades

Wrapping it preserves the familiar `mate: security` interface while using the well-tested tool underneath. No prompts to tweak, no re-invention.

### Direct adoption (without claude-mates)

If you prefer to use Anthropic's action directly without going through claude-mates, that works too — the wrapper adds zero functionality over the raw action, just the unified `mate: X` surface. Example:

```yaml
      - uses: anthropics/claude-code-security-review@<pinned-sha>
        with:
          claude-api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
          comment-pr: true
```

Claude Mates intentionally does **not** bundle a PR-scoped security workflow; the dedicated `claude-code-security-review` action is maintained by Anthropic and stays current with their model lineup.

### Security aftermath — tracked issue on merge-with-findings (recommended companion)

The security mate's inline PR comments and required status check are durable only while the PR is open. If a repo admin bypasses the required check and merges a PR with unresolved findings, those findings are on `main` with no tracked work item. This companion workflow closes that gap: when a PR merges with findings still present, it **opens a GitHub issue** labeled `claude-mate:security` so the vulnerability shows up in issue searches, assignee workflows, and triage tooling.

**Key difference from the drift mates' pattern**: drift mates deliberately do NOT auto-file issues (too noisy). Security is the exception because merging with residual findings is a rare, high-signal event — exactly the case where issue tracking earns its keep.

Add this workflow alongside `security-review.yml`:

```yaml
# .github/workflows/security-aftermath.yml
name: Security Aftermath

on:
  pull_request_target:
    types: [closed]
    branches: [main]   # scope-match your security-review.yml trigger

permissions:
  issues: write
  contents: read
  actions: read   # Download artifacts from another workflow's run

env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
  aftermath:
    if: github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    steps:
      - name: Look up security scan for this PR
        id: lookup
        env:
          GH_TOKEN: ${{ github.token }}
          SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          RUN_ID=$(gh api "repos/${{ github.repository }}/actions/runs?head_sha=${SHA}&per_page=20" \
            --jq '.workflow_runs[] | select(.name == "Security Review") | .id' | head -1)
          echo "run_id=${RUN_ID}" >> "$GITHUB_OUTPUT"

      - name: Download findings artifact
        id: download
        if: steps.lookup.outputs.run_id != ''
        env:
          GH_TOKEN: ${{ github.token }}
          RUN_ID: ${{ steps.lookup.outputs.run_id }}
          PR: ${{ github.event.pull_request.number }}
        run: |
          mkdir -p /tmp/findings
          if gh run download "${RUN_ID}" --repo "${{ github.repository }}" \
               -n "security-findings-pr-${PR}" -D /tmp/findings 2>/dev/null; then
            echo "found=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Open issue if findings were merged
        if: steps.download.outputs.found == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
          PR: ${{ github.event.pull_request.number }}
          PR_URL: ${{ github.event.pull_request.html_url }}
          MERGE_COMMIT: ${{ github.event.pull_request.merge_commit_sha }}
          REPO: ${{ github.repository }}
        run: |
          COUNT=$(jq -r '.findings_count // 0' /tmp/findings/security-summary.json)
          [ "$COUNT" -eq 0 ] 2>/dev/null && exit 0

          gh issue create --repo "${REPO}" \
            --title "[claude-mate:security] ${COUNT} finding(s) merged via PR #${PR}" \
            --label "claude-mate:security" \
            --body "Security findings merged to main. See PR #${PR} inline comments, and commit ${MERGE_COMMIT}."
```

> **Note**: change the \`select(.name == "Security Review")\` filter if your main security workflow is named differently (this filters by workflow `name:`, not file path).

### Why this differs from other mates

Drift mates (docs, tests, dead-code, logic) render findings to the Job Summary panel and never auto-file issues — findings without a concrete fix would be tracker noise at nightly scale. Security is different on two axes:

1. **Rarity × severity**: a clean merge with residual security findings is a rare event, and each such event is high-stakes. Opening an issue per occurrence keeps the signal high.
2. **Persistence**: security findings that land on `main` must be remediated regardless of whether the PR that introduced them is still open. An issue outlives the PR.

So security alone gets the issue-opening treatment, and only in the narrow post-merge-with-findings case. All other security findings stay in inline PR comments where they're naturally resolved as the PR iterates.

---

## Running drift mates on pull requests (optional)

By default, drift mates (docs, tests, dead-code, logic) run on a nightly cron because drift is a staleness concern that batches well. But **your trigger is your choice**: if you want per-PR feedback — e.g., the docs mate reviewing documentation drift before a PR merges — point the mate at `pull_request` instead of (or in addition to) `schedule`.

```yaml
name: "Mate: Docs (on PR)"

on:
  pull_request:
    branches: [main]

concurrency:
  group: mate-docs-pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  docs:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: write
      pull-requests: write
      issues: write
    steps:
      - uses: actions/checkout@v5
        with:
          ref: ${{ github.event.pull_request.head.sha || github.sha }}
          fetch-depth: 100
      - uses: vlad-ko/claude-mates@v0.9.5   # or later
        with:
          mate: docs
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
```

### Loop protection (framework-level, no config needed)

The framework automatically refuses to run a drift mate on a PR when any of these hold:

- The PR's source branch starts with `claude-mate/` — i.e., it IS a mate's own PR
- The HEAD commit message contains `[claude-mate` — catches cherry-picked mate commits
- The HEAD commit message contains `[skip release]` — release/CHANGELOG automation
- The HEAD commit message starts with `docs: Update CHANGELOG for v` — defense-in-depth for the auto-CHANGELOG PR

If any guard fires, the mate exits with `outcome: none, status: clean` and writes a one-line Job Summary explaining why. No Claude API call is made.

### What it costs

Running drift mates on every PR scales with PR throughput. A rough rule of thumb:

| Cadence | Haiku (cheap) per mate | Sonnet per mate |
|---|---|---|
| Nightly (5 weekdays) | $2–$4 / month | $8–$12 / month |
| Every PR (20/day) | $30–$60 / month | $120–$200 / month |

If your repo is busy, prefer nightly batching. If it's low-throughput or docs-critical, per-PR gives faster feedback.

### Side-effect awareness

A drift mate that runs on a PR and finds things to fix will open its **own** PR (against `main`, not against the originating PR). You now have two PRs to manage — the original feature PR and the mate's cleanup PR. Some adopters find this useful (separation of concerns); others find it noisy. Choose the cadence that matches your workflow.

Your options if the behavior doesn't fit:

- Keep drift mates on `schedule` (simplest)
- Run drift mates on PRs but with `paths:` filters so they only fire for relevant changes (e.g., docs mate only when `docs/**` changes)
- Call the action from a composite step that routes the mate's findings to a PR comment instead of a new PR (requires custom wrapper — not built-in)
