# HANDOFF — context-parachute

## Goal

Keep the handoff reliable for long, unattended Claude Code sessions. v1.3.0
(resume after auto-compaction, requested-vs-saved reminder, 1M window
auto-grow, doctor size check) is the current release.

## Current Progress

- **v1.2.0 shipped (2026-10-20, tagged).** `./install.sh --doctor` (read-only
  health check), PreCompact re-arm (clears `.fired` and advisory markers on
  auto and manual compaction), compaction log
  (`${XDG_STATE_HOME:-~/.local/state}/context-parachute/compactions.log`),
  opt-in PostToolUse mode (`--with-posttool`), `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
  fallback, local git exclude for `emergency.md`.
- **v1.2.1 shipped (2026-10-20, tagged).** Doctor window precedence (config
  beats env), paths with spaces in doctor, nested git exclude pattern.
- **Test baseline (this pass, HEAD `32cba28`):** `bash tests/run-tests.sh` →
  `96 passed, 0 failed`. The tag-consistency check passes because `v1.2.1`
  exists.
- **v1.3.2 (2026-10-20)** installer accepts indirect skill links. **v1.3.1 (2026-10-20)** fixed two v1.3.0 review notes (output_dir warning, helper timeout exemption). **v1.3.0 (2026-10-20):**
  (a) `hooks/parachute-resume.sh`, a SessionStart(compact) hook that injects a
  bounded (≤ 3 KB) card from `.parachute/continue-claude.md` or `HANDOFF.md`
  after auto-compaction; opt-in via `install.sh --with-resume`.
  (b) Watcher sends ONE follow-up reminder when the directive fired but
  `HANDOFF.md` was not updated afterwards ("requested vs saved").
  (c) Window auto-grows to 1M when observed tokens exceed 200k and no window is
  configured (an explicit window is never overridden).
  (d) `--doctor` warns when `HANDOFF.md` exceeds 40 KB.
- **PostCompact feature is superseded.** The 2026-07-09 spec planned a
  PostCompact re-arm. PostCompact hooks cannot inject context; the PreCompact
  re-arm shipped in 1.2.0 instead. The spec now carries a historical note.
- **Session analysis (4 weeks, 99 sessions, 2026-10):**
  - 33 auto-compactions, 0 manual. Sessions are long and largely unattended.
  - The watcher was removed from the owner's global `settings.json` by a
    harness diet on 2026-09-28, so 0 advisories fired for three weeks. Doctor
    exists to catch exactly this.
  - Effective window dropped from 1M to about 200k around 2026-10-15.
- **Docs refreshed in this pass:** `docs/DESIGN.md`, `docs/RELIABILITY.md`
  (evidence labelled as fixture / documentation / live), the 2026-07-09 spec
  note, and a HANDOFF size budget in `skill/SKILL.md`.
- **Tests before commit:** `.githooks/pre-commit` calls the new
  `.githooks/run-tests-on-commit` (runs the suite only when `hooks/`,
  `install.sh`, `uninstall.sh`, `tests/` or `skill/` is staged;
  `PARACHUTE_SKIP_TESTS=1` skips; exempts exactly the tag-consistency line).
  Simulated in a scratch clone: docs-only → silent; VERSION+skill bump without
  tag → allowed; extra failure → blocked; skip var → passed; all green → silent
  pass. `.githooks/pre-push` never blocks (documented in the file).
  Active only where `git config core.hooksPath .githooks` is set.
- **Decision record:** lore memory `context-parachute-v1-3-scope` (decision).

## Next Steps

1. v1.3.2 is released (commit, tag and GitHub release are standing-authorized).
2. Enable the repo hooks per clone with `git config core.hooksPath .githooks`
   (done in the maintainer clone, 2026-10-20).
3. **Canonical identity guard drift:** `.githooks/pre-commit` is a copy of the
   canonical guard in claude-setup. Apply the same 3-line addition there, or the
   copies drift.
4. **NOT VERIFIED — live resume:** whether SessionStart(compact) stdout reaches
   the model in a real session. Documentation and fixtures only so far.
5. **Check doctor on every machine:** confirm the watcher and PreCompact hooks
   are registered (the 2026-09-28 gap).
6. **Keep HANDOFF.md small:** follow the size budget in `skill/SKILL.md`
   (≤ 20 KB, current state in the first ~3 KB, older sections archived).

## What Worked / Decisions

- **Scope decisions for v1.3 (recorded in lore):** no statusline bridge; no
  semantic PreCompact card (PreCompact has no model turn, so the snapshot stays
  mechanical); no secret redaction (regexes cannot guarantee sanitization, so
  the docs make no such claim); no cross-tool adapters; no Stop-hook handoff
  forcing; never block compaction (PreCompact always exits 0); single injection
  owner per event (UserPromptSubmit/PostToolUse → watcher, SessionStart(compact)
  → resume, PreCompact never injects).
- **Does not work:** PostCompact cannot inject context. PreCompact stdout is not
  a model-context channel. Reading the destination project's `VERSION` for the
  footer identifies the wrong product, so artifacts use the loaded skill's
  `metadata.version`.
- **Test isolation is load-bearing.** An ambient `~/.claude/parachute.json`
  (`context_window: 1000000`) made 6 tests fail on 2026-08-29. Every watcher and
  PreCompact run uses a scratch `HOME` and `TMPDIR`; keep it that way.
- **Tag-consistency is by design.** A VERSION bump before its tag fails
  `git tag (X) matches VERSION (Y)`. The helper exempts only that exact line.
  Do not edit `tests/` to make it pass.
- Verification means real runs: root-cause with `bash -x` before changing
  assertions; update an assertion only when the behavior change is intended.

## Files Changed (this pass)

- `HANDOFF.md` — rewritten: stale v1.1.0-untagged, host-drift, backup-file and
  "ask before pushing" items removed; v1.2.x and v1.3.0 state recorded.
- `docs/DESIGN.md` — PostToolUse no longer a non-goal; re-arm, log, doctor,
  resume design (planned 1.3.0), single-injection-owner and never-block rules;
  test description corrected (bash runner, not bats).
- `docs/RELIABILITY.md` — re-arm and "no rearm" limit corrected; doctor, log,
  owner and never-block rules; evidence levels labelled.
- `docs/superpowers/specs/2026-07-09-v1.0.1-and-v1.1.0-design.md` — historical
  note: the PostCompact re-fire shipped as a PreCompact re-arm in 1.2.0.
- `skill/SKILL.md` — HANDOFF.md size-budget rule in artifact 1 (body only;
  `metadata.version` untouched).
- `.githooks/run-tests-on-commit` (new) — "tests before commit" helper.
- `.githooks/pre-commit` — 3-line call to the helper before the final `exit 0`.
- Not touched by this pass: `hooks/`, `install.sh`, `uninstall.sh`, `tests/`,
  `README.md`, `CHANGELOG.md`, `VERSION`. Parent-session edits to some of these
  are visible in `git status` and are not part of this pass.

---
_generated by context-parachute v1.3.2 (updated by hand, dogfooding the format)_
