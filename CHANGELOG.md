# Changelog

All notable changes to Claude Mates are documented here.

## [0.1.0] - 2026-04-11

First tagged release. Framework is feature-complete for single-repo use.

### Added
- **Code-enforced rules architecture** — Hard rules validated in runner.sh Phase 2, not prompt-only ([#18], [#19])
- **Protected paths** — Framework core files automatically reverted if modified by a mate
- **Scope enforcement** — Per-mate `allowed_paths` in mate.yml, validated with fnmatch
- **Project config overrides** — Consumer repos can override `allowed_paths` per mate in `.claude-mates.yml` ([#23])
- **Change size guardrails** — Warning if a mate modifies >20 files
- **Claude output classification** — Phase 1.5 detects API errors, empty outputs, and clean runs before issue creation ([#15], [#33])
- **Dynamic issue/PR text** — Titles and commit messages driven by mate.yml `description` and `commit_prefix` ([#13])
- **PR CI validation** — shellcheck and yamllint on PRs ([#25])
- **Job Summary output** — Workflow status visible in GitHub Actions summary panel ([#33])
- **5 mates** — docs, security, dead-code, tests, logic
- **Self-dogfooding** — All 5 mates run on the claude-mates repo itself
- **CLAUDE.md** — Project development guidelines
- **Example workflows** for consumer repos

### Fixed
- Wizard skill files no longer pollute git diff ([#12], [#17])
- Issue body uses Claude's actual analysis, not generic fallback ([#16])
- PR creation permission documented ([#14])
- Node.js 24 opt-in to eliminate deprecation warnings ([#21])
- Example workflows updated to v7 GitHub Actions and release tags ([#22], [#33])
- False-positive issues from empty/error outputs ([#33])

### Architecture
- **Two-phase design**: Phase 1 (Claude, sandboxed) + Phase 2 (Shell, enforced)
- **Tool isolation**: `--allowedTools` prevents git/gh/shell access
- **Defense-in-depth**: Deny rules in prompts + code validation in Phase 2

[#12]: https://github.com/vlad-ko/claude-mates/issues/12
[#13]: https://github.com/vlad-ko/claude-mates/issues/13
[#14]: https://github.com/vlad-ko/claude-mates/issues/14
[#15]: https://github.com/vlad-ko/claude-mates/issues/15
[#16]: https://github.com/vlad-ko/claude-mates/issues/16
[#17]: https://github.com/vlad-ko/claude-mates/issues/17
[#18]: https://github.com/vlad-ko/claude-mates/issues/18
[#19]: https://github.com/vlad-ko/claude-mates/pull/19
[#21]: https://github.com/vlad-ko/claude-mates/issues/21
[#22]: https://github.com/vlad-ko/claude-mates/issues/22
[#23]: https://github.com/vlad-ko/claude-mates/issues/23
[#25]: https://github.com/vlad-ko/claude-mates/issues/25
