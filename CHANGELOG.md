# Changelog

All notable changes to context-parachute are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The canonical version lives in the [`VERSION`](VERSION) file at the repo root.
The top entry here, the `VERSION` file, and the latest git tag always match —
`tests/run-tests.sh` enforces it.

## [Unreleased]

## [1.1.0] - 2026-08-29

Feature release: escalating context-cost warnings below the parachute threshold,
plus a test-isolation bugfix the previous release had already flagged as a risk.

### Added

- **Escalating context-cost advisories (50/70/85%).** Measured 2026-08-29: four
  parallel sessions sat at 67%, 67%, 93%, and 99% of a 1M window and together
  burned ~1 billion tokens/hour in cache reads alone — the watcher's single
  one-shot warning at 75% had already fired and did not help, because (a) one
  fired-marker per session meant exactly one warning ever, and (b) the message
  never stated what a turn actually costs. `parachute-watch.sh` now emits three
  advisory stages (50/70/85%), each with its own per-stage marker so ignoring
  the first warning doesn't buy silence for the rest of the session, and each
  states the per-turn token cost and an hourly estimate. At 85% the wording
  becomes a hard stop (**STOP AND COMPACT NOW**) rather than a suggestion. The
  parachute threshold and its one-shot marker are unchanged.
- Picks the *highest* stage reached on first observation, not the first match —
  a session already at 90% gets the 85%-tier message, not the mildest one.

### Fixed

- **85% wording preferred `/compact` over closing-and-reopening the session.**
  A restart re-pays ~80k tokens of system prompt; measured 2026-08-29, daily
  token volume tracks session *count* (15 sessions → 1.15Bn, 48 → 3.80Bn) with
  per-session cost flat, so offering "finish and close" as an equal alternative
  to compacting pointed at the more expensive option.
- **Test suite silently depended on the host's ambient `~/.claude/parachute.json`.**
  `run_watch`/`run_precompact` never isolated `HOME`, only `TMPDIR` — on a
  machine configured for 1M-context sessions (`context_window: 1000000`,
  a config this same README recommends), every threshold/WARN fixture computed
  against the wrong window and 6 of 32 tests failed with no code change at
  fault. Flagged as a known risk in `HANDOFF.md` on 2026-08-28 ("if this
  machine's global config is ever set to `context_window: 1000000` ... the
  threshold/WARN tests will break against real ambient state"); confirmed live
  2026-08-29 while auditing the repo. Fixed by isolating `HOME` to a scratch
  directory for every watcher/precompact invocation in the test runner, same
  pattern already used for the installer tests. Two of the newly-passing
  fixtures (`at-79`, `cache-heavy`) also needed their assertions updated: 79%
  now legitimately fires the 70% advisory added above, so "fully silent" was
  no longer the correct expectation.
- Added fixtures and 9 new assertions covering the escalation stages
  themselves (mildest/mid/hard-stop wording, per-stage marker suppression,
  highest-stage-wins). Full suite: **50 passed, 0 failed**.

## [1.0.2] - 2026-07-21

Bugfix release: a confirmed live Read-before-Write race on repos with a prior
`/parachute` run.

### Fixed

- **Read-before-Write race on re-run.** On a second `/parachute` in the same
  repo, `continue.md`/`continue-claude.md` already exist; the skill would Read
  and Write them in the same batched tool-call turn, and the harness's
  read-tracking doesn't carry into a same-turn Write, so the Write errored
  with "File has not been read yet." `skill/SKILL.md` now requires Read and
  Write of the same file to happen in separate, sequential steps, per file,
  immediately before that file's own Write.

## [1.0.1] - 2026-07-09

Bugfix release: a confirmed live misfire on 1M-context sessions, plus a
portability fix so the watcher runs on macOS/BSD.

### Fixed

- **1M-context misfire.** `context_window` defaults to `200000`; on a 1M-context
  session (e.g. Opus `[1m]`) the parachute fired at ~16% actual fill instead of
  80%. No reliable auto-detection signal exists (model string lacks `[1m]`;
  inferring from observed tokens is circular at the threshold), so the fix is a
  documented per-project `context_window: 1000000` override
  (`.parachute/config.json`), plus a one-line `WARN:` to stderr when the default
  window is left in place and observed tokens already exceed it. The trigger
  decision itself is unchanged — this is a visibility nudge, not new logic.
- **macOS/BSD portability.** `parachute-watch.sh` used `tac` (GNU-only) to
  reverse-read the transcript tail. Replaced with `tail -n 500 … | tail -n 1`
  (take the last match instead of reversing to take the first) — POSIX-portable,
  same 500-line window, byte-identical result on all fixtures.

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
