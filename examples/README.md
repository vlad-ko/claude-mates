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
      - uses: vlad-ko/claude-mates@v0.5.0
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
