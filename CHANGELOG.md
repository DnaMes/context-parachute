# Changelog

All notable changes to context-parachute are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The canonical version lives in the [`VERSION`](VERSION) file at the repo root.
The top entry here, the `VERSION` file, and the latest git tag always match —
`tests/run-tests.sh` enforces it.

## [Unreleased]

## [1.0.0] - 2026-07-09

First tagged release. The system was already built and in daily use; this release
adds versioning, a changelog, and artifact provenance stamping.

### Added

- **Auto-eject session handoff.** `UserPromptSubmit` watcher (`parachute-watch.sh`)
  reads the transcript, computes context usage as a percent of the window from the
  last assistant message's token totals, and injects a one-shot directive when it
  crosses the threshold (default 80%). A per-session fired-marker prevents nagging.
- **PreCompact fallback** (`parachute-precompact.sh`). On auto-compaction with no
  prior fire — a single huge turn, or a long autonomous run with no user prompts —
  injects an emergency brain-dump prompt and writes a bash-only git snapshot to
  `.parachute/emergency.md`, so raw state survives even if the model produces nothing.
- **Cross-agent artifacts.** `HANDOFF.md` (repo root), `.parachute/continue.md`
  (generic paste prompt), `.parachute/continue-claude.md` (fresh Claude session),
  and a marker-delimited `AGENTS.md` block for zero-paste pickup by Codex / OpenCode.
- **Idempotent installer/uninstaller.** Appends two hook blocks to
  `~/.claude/settings.json` without clobbering existing hooks, backs up first,
  symlinks the skill, seeds `~/.claude/parachute.json`. Uninstall reverses
  everything except the user-owned config.
- **Config.** Global `~/.claude/parachute.json` with optional per-project override
  at `.parachute/config.json`; invalid config warns to stderr and falls back to
  defaults (never a silent failure).
- **Provenance.** Generated artifacts and the emergency snapshot are stamped with
  the producing version, read fail-open from the `VERSION` file (missing/unreadable
  → `unknown`, never an error).
- **Test suite** (`tests/run-tests.sh`): threshold matrix, token-sum correctness
  (cache / sidechain / corrupt handling), fail-open paths, PreCompact fallback,
  installer idempotency, version consistency, and shellcheck on every shipped script.

### Notes

- v1 limitation: `UserPromptSubmit` only fires on user input; the PreCompact
  fallback covers the autonomous-run gap rather than preventing it.

[Unreleased]: https://github.com/DnaMes/context-parachute/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/DnaMes/context-parachute/releases/tag/v1.0.0
