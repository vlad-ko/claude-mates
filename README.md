# Claude Mates

Autonomous background agents for codebase maintenance, powered by Claude Code CLI.

Inspired by [AI Daemons](https://ai-daemons.com/spec/) but built natively on Claude Code's skills, tools, and CLAUDE.md conventions.

## What Are Mates?

Mates are specialized background agents that handle maintenance tasks humans tend to defer: documentation quality, security reviews, dead code cleanup, test hygiene, and business logic audits.

Each mate:
1. **Activates** on merge to main or nightly schedule
2. **Analyzes** the blast radius of recent changes (or scans the full codebase)
3. **Creates a GitHub issue** describing its findings
4. **Opens a PR** with fixes (or flags issues requiring human judgment)
5. **Never merges its own PRs** — human approval required

## Mates

| Mate | Purpose | Model | Trigger |
|------|---------|-------|---------|
| `docs` | Documentation quality & staleness | Haiku | Post-merge |
| `security` | Security architecture review | Sonnet | Post-merge |
| `dead-code` | Unused code, orphaned files | Haiku | Nightly |
| `tests` | Outdated/redundant tests | Haiku | Nightly |
| `logic` | TODOs, deprecated APIs, hardcoded values | Haiku | Nightly |

## Quick Start

### 1. Add secrets to your repo

```bash
# Separate API key for mates (recommended for cost tracking)
gh secret set CLAUDE_MATES_API_KEY --repo your-org/your-repo

# GitHub token (or use default GITHUB_TOKEN)
# Only needed if you want mates to create PRs with a custom identity
```

### 2. Add mate workflows

Copy only the mates you want from `examples/` to `.github/workflows/` in your repo:

```bash
# Just docs mate
cp examples/mate-docs.yml .github/workflows/

# Or all mates
cp examples/mate-*.yml .github/workflows/
```

Each mate is a separate workflow — independent triggers, logs, and concurrency.

> **Important:** Example workflows reference `ref: v0.1.0`. Pin to the latest [release tag](https://github.com/vlad-ko/claude-mates/releases) for stability. Check the releases page for upgrade instructions.

### 3. Add project config

Create `.claude-mates.yml` in your repo root:

```yaml
mates:
  docs:
    enabled: true
    model: haiku
    schedule: post-merge
    # Override default scope (optional — defaults come from mate.yml)
    allowed_paths:
      - "docs/**"
      - "CLAUDE.md"
      - "README.md"
  security:
    enabled: true
    model: sonnet
    schedule: post-merge
  dead-code:
    enabled: true
    model: haiku
    schedule: nightly
  tests:
    enabled: false
  logic:
    enabled: false

deny:
  - "NEVER merge PRs"
  - "NEVER modify .env files or infrastructure config"
  - "NEVER push directly to main"

labels:
  prefix: "claude-mate"
```

### 4. Run manually (first time)

```bash
gh workflow run mate-docs.yml
```

## How It Works

```
GitHub Actions trigger (merge / cron / manual)
        |
        v
Dispatcher (reads .claude-mates.yml, determines which mates to run)
        |
        v
Runner (for each mate):
  1. Checks out repo
  2. Installs Claude Code CLI
  3. Runs: claude -p "<mate prompt>" --allowedTools "..." --max-turns 15
  4. Claude reads the repo's CLAUDE.md (project rules auto-enforced)
  5. If changes made → creates branch, commits, opens PR
  6. If findings only → creates GitHub issue
  7. Uploads run summary as artifact
```

## Cost

| Model | Typical mate run | Monthly (5 mates, weekdays) |
|-------|-----------------|---------------------------|
| Haiku 4.5 | $0.08-0.15 | $8-15 |
| Sonnet 4.6 | $0.30-0.50 | $30-50 |
| Mixed (Haiku default, Sonnet for security) | — | $15-25 |

## Design Principles

1. **Mates never merge** — they propose, humans decide
2. **Narrow scope** — each mate has a single responsibility
3. **Project-aware** — reads the target repo's CLAUDE.md for conventions
4. **Cost-bounded** — max turns per run, model selection per mate
5. **Observable** — every run produces a structured summary
6. **Safe** — deny rules prevent destructive actions

## Versioning

Claude Mates follows [semantic versioning](https://semver.org/). Pin your workflows to a release tag:

```yaml
# In your workflow file
- uses: actions/checkout@v5
  with:
    repository: vlad-ko/claude-mates
    ref: v0.1.0  # Pin to release tag
    path: .claude-mates-framework
```

Check [CHANGELOG.md](CHANGELOG.md) for what changed between versions.

## Repo Settings

For mates to create PRs, enable this repo setting:

**Settings > Actions > General > Workflow permissions > Allow GitHub Actions to create and approve pull requests**

## License

MIT
