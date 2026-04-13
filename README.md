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

**Key architectural difference from the drift mates**:

| | Drift mates | Security mate |
|---|---|---|
| Findings go to | Job Summary panel (ephemeral, per-run) | Inline PR review comments (during PR lifecycle) |
| Opens a PR? | Yes, when there's a concrete fix | No — detection-only |
| Opens an issue? | **No** (avoids tracker noise at nightly scale) | **Only** when a PR merges with residual findings (via optional `security-aftermath.yml` companion). Rare × high-signal. |
| Blocks merge? | Never (advisory only) | Yes, when `security` is added as a required status check |

See [examples/README.md § Security aftermath](examples/README.md#security-aftermath--tracked-issue-on-merge-with-findings-recommended-companion) for the tracked-issue pattern — recommended for production app repos where a vulnerability landing without remediation is a real risk.

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
    # max_window_hours: 24    # default — review files changed in last 24h
                              # (override per-mate; e.g. 168 to "catch up
                              # over a week" after an outage. No upper bound.)
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
      - uses: vlad-ko/claude-mates@v0.6.1
        with:
          mate: ${{ matrix.mate }}
          api-key: ${{ secrets.CLAUDE_MATES_API_KEY }}
```

### 5. Trigger manually for the first time

```bash
gh workflow run mates.yml
```

### 6. (Recommended) Add the security mate as a required status check

The security mate is a PR-scoped wrapper over [`anthropics/claude-code-security-review`](https://github.com/anthropics/claude-code-security-review). Running it is one thing; **blocking merge on it** is how you actually prevent vulnerabilities from landing on `main`.

Add a PR-scoped workflow first (see [examples/README.md § The security mate is PR-scoped](examples/README.md#the-security-mate-is-pr-scoped-a-thin-wrapper-over-anthropics-scanner)), then promote its check to required:

**Repo Settings → Branches → Branch protection rule for `main`:**

1. Enable *"Require status checks to pass before merging"*
2. Add **`security`** (the workflow's job name) to the required-checks list

With this, merge is blocked until the scanner completes AND the PR addresses (or overrides) any findings. Recommended for production application repos where the cost of a vulnerability landing greatly exceeds the occasional false-positive friction.

Escape hatch: repo admins can override the required check on a per-PR basis when the scanner is clearly wrong. Document that override path in your repo's `CLAUDE.md` / contributing docs.

**Skip this for framework / library repos** where surface area is small (bash, YAML) and false-positive rate is high — advisory mode is fine.

## Action reference

```yaml
- uses: vlad-ko/claude-mates@v0.6.1
  with:
    mate: docs                   # required: one of docs, tests, dead-code, logic, security
    api-key: ${{ ... }}          # required: Anthropic API key
    config-path: .claude-mates.yml     # optional (default shown)
    claude-cli-version: 2.1.97         # optional — pin for reproducibility (drift mates only)
```

| Output | Values |
|---|---|
| `outcome` | `none` \| `findings` \| `pr` |
| `status` | `ok` \| `clean` \| `error` \| `empty` |
| `issue-url` | Always empty (drift mates write to Job Summary; security mate posts inline PR comments) |
| `pr-url` | URL of created PR, or empty (drift mates only) |
| `findings-count` | Number of findings (security mate only; empty otherwise) |

## How it works

```
schedule / pull_request / push / workflow_dispatch
        │
        ▼
action.yml (composite)
        │ ├─ if mate==security → delegates to anthropics/claude-code-security-review (pinned SHA)
        │ └─ else              → installs @anthropic-ai/claude-code CLI + invokes runner.sh
        ▼
runner.sh  (drift mates: docs/tests/dead-code/logic)
        │ ├─ Phase 0: self-loop guards + bounded delta window
        │ │           - self-loop guards: PR branch, HEAD commit patterns, CHANGELOG markers
        │ │           - window start = max(cursor, now - max_window_hours), default 24h
        │ │           - if 24h window empty AND cursor exists → fall back to cursor
        │ │           - review set = window ∩ mate's allowed_paths
        │ │           - skip-fast-path: review set empty → exit 0, zero API cost
        │ ├─ Phase 1: Claude reviews ONLY the review set (code-enforced in Phase 2)
        │ └─ Phase 2: shell validates, commits, opens branch/PR; reverts edits outside window
        ▼
$GITHUB_OUTPUT surfaces outcome + URLs + findings-count for downstream steps
```

**Trigger shape is your choice:**
- **Drift mates** (docs, tests, dead-code, logic): nightly cron is the default. Can also be invoked on `pull_request` — the framework prevents self-loops either way.
- **Security mate**: always `pull_request` (enforced by the action). It's a pre-merge policy gate, not a drift scan.

See [examples/README.md](examples/README.md) for both per-mate and matrix patterns, and the PR-trigger variants.

## Design principles

1. **Mates never merge.** They propose (PR or findings comment). Humans decide.
2. **Code enforces, prompts guide.** Hard rules (scope, protected paths, git isolation, self-loop detection) live in `runner.sh`. Prompts guide behavior only.
3. **Bounded delta review, never a full scan.** Each mate reviews files changed in the last `max_window_hours` (default 24, configurable per-mate via `.claude-mates.yml`), intersected with its `allowed_paths`. If the 24h window is empty AND a cursor (last mate contribution) exists, the window extends to the cursor — catches unreviewed bursts that predate the horizon. If both windows are empty, the run skips cleanly (zero API cost). Full-repo scans are forbidden by the framework — even on first run. Historical cleanup is for humans running Claude Code directly.
4. **No file copying.** The action IS the integration — no `.claude-mates-framework/` checkout, no per-release template bumps.
5. **No self-loops, across any trigger.** Framework-level guards fire on schedule, push, AND pull_request events. Mate-originated branches, automation-authored commits, and CHANGELOG PRs all skip cleanly. `workflow_dispatch` (manual) bypasses self-loop guards but still applies delta scope.
6. **No issue-tracker noise.** Findings without a concrete fix render to the workflow log + Job Summary panel, not auto-filed GitHub issues. Only human-filed issues are tracked long-term.
7. **Specialized tools for specialized jobs.** The security mate is a thin wrapper over Anthropic's `claude-code-security-review` — battle-tested, diff-aware, FP-filtered. We don't re-invent; we integrate.
8. **Cost-bounded.** Per-mate model selection, per-mate max-turns, `allowed_paths` scope cap, `--allowedTools` tool cap. Delta scope + self-loop guard skip any run that would produce no signal.
9. **Observable.** Every run writes `/tmp/mate-*-summary.json` (uploaded as artifact), populates GitHub Job Summary, and surfaces structured action outputs for downstream steps.

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
