# Claude Mates Development Guidelines

## Core Principle: Code Enforces, Prompts Guide

**Hard rules MUST be implemented in code. Prompts are for behavioral guidance only.**

When deciding where a rule belongs, ask: "If the LLM ignores this instruction, does something bad happen?" If yes, enforce it in code (runner.sh, dispatcher.sh, workflow YAML). If it's a judgment call about quality or approach, keep it in the prompt.

| Rule Type | Enforcement | Examples |
|-----------|-------------|----------|
| **Hard constraint** | Code (runner.sh Phase 2) | Protected paths, scope boundaries, file type restrictions |
| **Tool restriction** | Code (`--allowedTools`) | No git, no gh, no arbitrary bash |
| **Behavioral guidance** | Prompt (PROMPT.md) | "Be conservative", "Focus on accuracy not style" |
| **Defense-in-depth** | Both code + prompt | Critical rules get both layers |

### What This Means in Practice

- **Don't tell the LLM "NEVER modify .env"** and hope it listens. Validate in Phase 2 that `.env` files are not in `git diff`, and revert them if they are.
- **Don't tell the LLM "only edit docs/"** and hope it stays in scope. Read `allowed_paths` from mate.yml and reject changes outside that list.
- **Do tell the LLM "be conservative with removals"** in the prompt — that's a judgment call code can't make.

## Architecture

### Two-Phase Design

```
Phase 1 (Claude):  Analyze and edit files
                   Constrained by --allowedTools (no git, no gh, no shell)
                   Guided by PROMPT.md (behavioral instructions)

Phase 2 (Shell):   Validate changes against hard rules
                   Create branch, commit, issue, PR deterministically
                   Reject/revert violations — LLM has no say
```

Phase 1 is the LLM's sandbox. Phase 2 is the guardrail. Never rely on Phase 1 compliance for safety — always verify in Phase 2.

### Mate Configuration (mate.yml)

Each mate declares its constraints in `mate.yml`:

```yaml
name: docs
description: Documentation quality and staleness reviewer
model: haiku
max_turns: 15
commit_prefix: docs        # Conventional commit prefix
allowed_paths:             # Files this mate MAY edit (glob patterns)
  - "docs/**"
  - "CLAUDE.md"
  - "README.md"
protected_paths:           # Files NO mate may edit (global, in runner.sh)
  # runner.sh, dispatcher.sh, action.yml, CODEOWNERS, SECURITY.md,
  # .github/workflows/*, .env*, mates/*/PROMPT.md, mates/*/mate.yml
```

- `allowed_paths`: Code-enforced in Phase 2. Changes outside these paths are reverted.
- `protected_paths`: Global list in runner.sh. Changes to these files are always reverted.
- `commit_prefix`: Used for conventional commit messages (not hard-coded to `docs:`).
- `description`: Used for issue titles and PR descriptions.

## File Structure

```
claude-mates/
  action.yml          # GitHub Action composite definition
  dispatcher.sh       # Reads config, runs selected mates
  runner.sh           # Two-phase runner: Claude (Phase 1) + Shell (Phase 2)
  CLAUDE.md           # This file — development guidelines
  .claude-mates.yml   # Self-dogfooding config
  mates/
    docs/
      PROMPT.md       # Behavioral guidance for the docs mate
      mate.yml        # Hard constraints (model, scope, allowed_paths)
    security/
    dead-code/
    tests/
    logic/
  examples/           # Example workflow files for consumers
  .github/workflows/  # CI workflows for this repo (self-dogfooding)
```

## Deny Rules

Deny rules in `.claude-mates.yml` are injected into prompts as defense-in-depth. They are NOT the primary enforcement mechanism. Every deny rule that can be validated in code MUST also be validated in runner.sh Phase 2.

Example: `.claude-mates.yml` says `NEVER modify .env files`. This is:
1. Injected into the prompt (defense-in-depth)
2. Validated in Phase 2: `git diff --name-only | grep '\.env'` triggers revert

## Adding a New Mate

1. Create `mates/<name>/mate.yml` with hard constraints
2. Create `mates/<name>/PROMPT.md` with behavioral guidance
3. Create `.github/workflows/mate-<name>.yml` using `_run-mate.yml`
4. Add to `.claude-mates.yml` in target repos

### mate.yml Required Fields

```yaml
name: <mate-name>           # Must match directory name
description: <one-line>     # Used in issue titles, PR descriptions
model: haiku|sonnet|opus    # Default model (can be overridden by project config)
max_turns: 15               # Maximum Claude turns
commit_prefix: <prefix>     # Conventional commit prefix (docs, security, chore, test, refactor)
allowed_paths:              # Glob patterns for files this mate may edit
  - "path/**"
```

### PROMPT.md Guidelines

Prompts should contain:
- What to analyze and how (the mate's purpose)
- Quality standards and judgment calls
- Output format expectations
- Behavioral guardrails that require LLM reasoning

Prompts should NOT be the primary enforcement for:
- File scope restrictions (use mate.yml `allowed_paths`)
- Protected paths (validated in runner.sh)
- Git/GitHub operations (handled by Phase 2)
- Issue/PR creation (handled by Phase 2 deterministically)

## Testing Changes

```bash
# Run a single mate locally (requires ANTHROPIC_API_KEY)
export ANTHROPIC_API_KEY=sk-...
export GITHUB_TOKEN=$(gh auth token)
bash runner.sh docs ./mates/docs .claude-mates.yml

# Run dispatcher (all enabled mates)
bash dispatcher.sh
```

## Commit Conventions

- `feat:` — New mate or major feature
- `fix:` — Bug fix in framework
- `chore:` — Config, CI, maintenance
- `docs:` — Documentation only
- Prefix scope: `fix(runner):`, `feat(mate-security):`
