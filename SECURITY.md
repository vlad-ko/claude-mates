# Security Policy

## API Key Safety

Claude Mates runs AI agents that consume API tokens. The `CLAUDE_MATES_API_KEY` secret is protected by GitHub's built-in security model:

- **Fork PRs never receive secrets** — GitHub strips all secrets from fork-originated workflow runs
- **Only `push: main` and `workflow_dispatch` trigger the workflow** — not `pull_request`
- **Branch protection** requires review before merge to main — no direct pushes
- **CODEOWNERS** requires owner approval for workflow, runner, and config changes

## Spend Protection

Repository owners should:
1. Set a monthly spend limit on the API key via [console.anthropic.com](https://console.anthropic.com)
2. Use a **dedicated API key** for Claude Mates (not shared with production services)
3. Monitor usage via the Anthropic dashboard

## Supply Chain

- The Claude Code CLI is **pinned to a specific version** in the workflow
- When used as an external action, the checkout is **pinned to a commit SHA**
- Branch protection prevents tampering with pinned references

## Reporting Vulnerabilities

If you discover a security issue, please report it via GitHub Security Advisories (not public issues):
https://github.com/vlad-ko/claude-mates/security/advisories/new

## What Claude Mates Cannot Do

- **Never merges PRs** — all changes require human approval
- **Never accesses secrets directly** — Claude Code CLI has no `Bash(env *)` or `Bash(echo $*)` tools
- **Never modifies workflow files** — CODEOWNERS blocks this
- **Never runs on fork PRs** — workflow only triggers on push to main
- **Max 1 PR per mate per day** — prevents spam even if compromised
