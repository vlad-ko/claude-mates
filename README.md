# Claude Mates

Autonomous maintenance agents for your codebase, shipped as a GitHub composite action.

Each mate is a specialized Claude Code agent that runs on a schedule, analyzes your repo, and either files an issue or opens a PR with fixes. Mates never merge — humans decide.

Inspired by [AI Daemons](https://ai-daemons.com/spec/), built on [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## The mates

Two classes:

**Drift mates** — nightly state-query over HEAD. Each is a Claude Code prompt tuned for one concern.

| Mate | Purpose | Default model | Trigger |
|---|---|---|---|
| `docs` | Documentation quality, staleness, drift | Haiku | nightly |
| `tests` | Outdated/redundant tests, weak assertions | Haiku | nightly |
| `dead-code` | Unused symbols, orphaned files | Haiku | nightly |
| `logic` | TODOs, deprecated APIs, hardcoded values | Haiku | nightly |

**Policy gate** — PR-scoped, wraps a specialized tool.

| Mate | Purpose | Engine | Trigger |
|---|---|---|---|
| `security` | Security review, diff-aware, inline PR comments | [`anthropics/claude-code-security-review`](https://github.com/anthropics/claude-code-security-review) (Opus 4.1 default) | `pull_request` only |

The security mate is a thin wrapper over Anthropic's specialized scanner: you keep the `mate: security` interface, the scanner does the analysis. See [examples/README.md](examples/README.md) for the PR-scoped invocation pattern.

## Quick start

### 1. Add a secret

```bash
gh secret set CLAUDE_MATES_API_KEY --repo your-org/your-repo
# Paste your Anthropic API key
```

### 2. Enable "Allow GitHub Actions to create and approve pull requests"

Repo **Settings → Actions → General → Workflow permissions**. Without this, the mate can open issues but not PRs.

### 3. Create `.claude-mates.yml` in your repo root

```yaml
mates:
  docs:
    enabled: true
  tests:
    enabled: true
  dead-code:
    enabled: true
  logic:
    enabled: false
  security:
    enabled: false  # Consider PR-scoped claude-code-security-review instead

deny:
  - "NEVER merge PRs — always require human approval"
  - "NEVER modify .env files or infrastructure config"

labels:
  prefix: "claude-mate"
```

Full schema in [`.claude-mates.yml`](.claude-mates.yml) of this repo.

### 4. Add a workflow

Pick one pattern from [examples/README.md](examples/README.md). The matrix-over-mates pattern is the simplest:

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
        mate: [docs, tests, dead-code]
    concurrency:
      group: mate-${{ matrix.mate }}
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v5
        with: { fetch-depth: 100 }
      - uses: vlad-ko/claude-mates@v0.3.0
        with:
          mate: ${{ matrix.mate }}
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
```

### 5. Trigger manually for the first time

```bash
gh workflow run mates.yml
```

## Action reference

```yaml
- uses: vlad-ko/claude-mates@v0.3.0
  with:
    mate: docs                   # required: one of docs, tests, dead-code, logic, security
    api-key: ${{ ... }}          # required: Anthropic API key
    config-path: .claude-mates.yml     # optional (default shown)
    claude-cli-version: 2.1.97         # optional — pin for reproducibility
```

| Output | Values |
|---|---|
| `outcome` | `none` \| `issue` \| `pr` |
| `status` | `ok` \| `clean` \| `error` \| `empty` |
| `issue-url` | URL of created issue, or empty |
| `pr-url` | URL of created PR, or empty |

## How it works

```
schedule / workflow_dispatch
        │
        ▼
action.yml (composite)
        │ ├─ installs @anthropic-ai/claude-code CLI (pinned)
        │ └─ invokes runner.sh with MATE_NAME + MATES_ROOT = github.action_path
        ▼
runner.sh
        │ ├─ Phase 0: self-loop guard — skip if no human commits since last mate run
        │ ├─ Phase 1: Claude analyzes repo, edits files (tool-scoped via --allowedTools)
        │ └─ Phase 2: shell validates, commits, opens branch/issue/PR
        ▼
$GITHUB_OUTPUT surfaces outcome + URLs for downstream steps
```

## Design principles

1. **Mates never merge.** They propose. Humans decide.
2. **Code enforces, prompts guide.** Hard rules (scope, protected paths, git isolation) live in `runner.sh`. Prompts guide behavior only.
3. **No file copying.** The action IS the integration — no `.claude-mates-framework/` checkout, no per-release template bumps.
4. **No self-loops.** runner.sh skips scheduled runs when no human commit has landed since the mate's last contribution (prevents echo-chamber review of the mate's own output).
5. **Cost-bounded.** Per-mate model selection, per-mate max-turns, nightly cadence (no per-merge waste).
6. **Observable.** Every run writes `/tmp/mate-*-summary.json` (uploaded as artifact) and populates GitHub Job Summary + action outputs.

## Upgrading

Pin `uses: vlad-ko/claude-mates@vX.Y.Z` to a specific release tag. Check [CHANGELOG.md](CHANGELOG.md) before bumping — patch versions are safe; minor versions may add features; major versions document breaking changes.

## Cost

| Model | Typical run | Monthly (5 mates, weekdays) |
|---|---|---|
| Haiku 4.5 | $0.08–$0.15 | $8–$15 |
| Sonnet 4.6 | $0.30–$0.50 | $30–$50 |
| Mixed (Haiku default, Sonnet for security) | — | $15–$25 |

The self-loop guard brings real cost down further on quiet repos — mates with no human work to analyze exit in seconds and skip the Claude API entirely.

## License

MIT — see [LICENSE](LICENSE).
