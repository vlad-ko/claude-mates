# Claude Mates — workflow examples

Claude Mates ships as a GitHub composite action (`vlad-ko/claude-mates`). Drop one of the patterns below into your consumer repo under `.github/workflows/` — no file copying, no `claude-mates-framework` checkout, no per-release template updates.

See the repo root [README.md](../README.md) for the `.claude-mates.yml` config schema and the list of available mates.

## Prerequisites

1. **Secret**: `CLAUDE_MATES_API_KEY` — an Anthropic API key.
2. **Repo setting**: Settings → Actions → General → Workflow permissions → enable *"Allow GitHub Actions to create and approve pull requests"*.
3. **Config file**: `.claude-mates.yml` in your repo root (enable/disable mates, override models, set scopes, deny rules).

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

      - uses: vlad-ko/claude-mates@v0.3.0
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

      - uses: vlad-ko/claude-mates@v0.3.0
        with:
          mate: ${{ matrix.mate }}
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
```

Each matrix leg is an independent job — separate log stream, separate concurrency group, one mate's failure does not cancel the others (`fail-fast: false`).

---

## Reacting to the action's outputs

The action surfaces four outputs so downstream steps can branch on what the mate produced:

| Output | Values |
|---|---|
| `outcome` | `none` \| `issue` \| `pr` |
| `status` | `ok` \| `clean` \| `error` \| `empty` |
| `issue-url` | URL of created issue, or empty |
| `pr-url` | URL of created PR, or empty |

```yaml
      - id: mate
        uses: vlad-ko/claude-mates@v0.3.0
        with:
          mate: docs
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}

      - name: Post to Slack when a PR lands
        if: steps.mate.outputs.outcome == 'pr'
        run: |
          curl -XPOST "$SLACK_WEBHOOK" -d "{\"text\":\"Mate opened ${{ steps.mate.outputs.pr-url }}\"}"
        env:
          SLACK_WEBHOOK: ${{ secrets.SLACK_WEBHOOK }}
```

---

## PR-scoped runs

The drift mates (docs, tests, dead-code, logic) are designed for nightly batching — they find issues that accumulate over time. For **policy gates that must run pre-merge** (e.g., security review), use Anthropic's specialized PR-scoped action instead:

```yaml
on:
  pull_request:
    branches: [main]

jobs:
  security:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
      contents: read
    steps:
      - uses: actions/checkout@v5
        with:
          ref: ${{ github.event.pull_request.head.sha || github.sha }}
          fetch-depth: 2
      - uses: anthropics/claude-code-security-review@<pinned-sha>
        with:
          claude-api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
          comment-pr: true
```

Claude Mates intentionally does **not** bundle a PR-scoped security workflow; the dedicated `claude-code-security-review` action is maintained by Anthropic and stays current with their model lineup.

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
      - uses: vlad-ko/claude-mates@v0.5.0   # or later
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
