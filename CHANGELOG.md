# Changelog

All notable changes to Claude Mates are documented here.

## [0.5.0] - 2026-04-12

### Added
- feat: Security mate becomes a thin wrapper over Anthropic's scanner

### Changed
- docs: Update CHANGELOG for v0.4.0 [skip release]

**Full Changelog**: https://github.com/vlad-ko/claude-mates/compare/v0.4.0...v0.5.0

## [0.4.0] - 2026-04-12

### Added
- feat: Render findings to CI output instead of filing GitHub issues

### Changed
- docs: Update CHANGELOG for v0.3.0 [skip release]

**Full Changelog**: https://github.com/vlad-ko/claude-mates/compare/v0.3.0...v0.4.0

## [0.3.0] - 2026-04-12

### Added
- feat: Enrich TRIGGER_CONTEXT with since/changed_files metadata

### Changed
- docs: Update CHANGELOG for v0.2.7 [skip release]

**Full Changelog**: https://github.com/vlad-ko/claude-mates/compare/v0.2.7...v0.3.0

## [0.2.7] - 2026-04-12

### Fixed
- fix: Update pr-checks.yml for v0.3.0 file layout

### Changed
- docs: Documentation quality and staleness reviewer findings [claude-mate:docs]
- docs: Update CHANGELOG for v0.2.6 [skip release]

**Full Changelog**: https://github.com/vlad-ko/claude-mates/compare/v0.2.6...v0.2.7

## [0.2.6] - 2026-04-12

### Fixed
- fix: Prevent CHANGELOG PR from re-triggering release workflow

**Full Changelog**: https://github.com/vlad-ko/claude-mates/compare/v0.2.5...v0.2.6

## [0.2.4] - 2026-04-12

### Changed
- docs: Update CHANGELOG for v0.2.3 [skip release]

**Full Changelog**: https://github.com/vlad-ko/claude-mates/compare/v0.2.3...v0.2.4

## [0.2.3] - 2026-04-12

### Fixed
- fix: Release workflow missing pull-requests: write permission

### Changed
- docs: Documentation quality and staleness reviewer findings [claude-mate:docs]

**Full Changelog**: https://github.com/vlad-ko/claude-mates/compare/v0.2.2...v0.2.3

## [0.2.0] - 2026-04-11

### Added
- **Automated release workflow** — `release.yml` auto-tags and publishes on merge to main. Reads conventional commit prefixes to determine version bump (`feat:` → minor, `fix:`/`chore:`/`docs:` → patch). Skip with `[skip release]`. ([#35])

### Changed
- Future releases are tagged automatically — no more manual `git tag` + `gh release create`.

[#35]: https://github.com/vlad-ko/claude-mates/pull/35

## [0.1.1] - 2026-04-11

### Fixed
- **False-positive issue prevention** — Runner no longer creates GitHub issues for clean runs, API errors, or empty output. Added `CLAUDE_STATUS` classification (ok/clean/error/empty) in Phase 1.5 ([#32], [#33])
- **Node.js 20 deprecation warning** — Upgraded `actions/upload-artifact` from v5 to v7 (native Node 24 target) ([#21], [#33])
- **Empty Job Summary on skipped runs** — Early-exit paths now write a "Skipped" message to the Job Summary panel ([#33])
- **Stale branch cleanup** — Deleted merged feature branch ([#33])

[#33]: https://github.com/vlad-ko/claude-mates/pull/33

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
