# Recovery contract

Reviewed 2026-10-20 against v1.2.1. Evidence labels: **[fixture]** = checked by
`tests/run-tests.sh` on fixtures in temporary homes; **[docs]** = official Claude
Code hook documentation, not re-tested here; **[live]** = observed in real
sessions; **[planned]** = not shipped. Design rationale is in
[DESIGN.md](DESIGN.md).

## Two different kinds of state

The UserPromptSubmit watcher can add a directive to the next model request.
Its `.fired` marker acknowledges that the directive was **emitted**, not that the
skill **completed**. The model must still write and verify `HANDOFF.md`,
continuation prompts, and the optional AGENTS block. Those files capture semantic
state. **[fixture]** for the marker; the model's writing is a prompt, not a tested
behavior.

PreCompact saves mechanical state before every **automatic** compaction: git
status, diff statistics, recent commits, timestamp, and plugin version. The
snapshot is not a backup of working file contents and not a substitute for the
model's decisions and next steps. **[fixture]**

## What PreCompact does (shipped 1.2.0)

PreCompact runs for both `auto` and `manual` compaction and always exits 0.
**[fixture]**

- **Re-arm:** clears the session's `.fired` and advisory markers, so the watcher
  warns again after the context has shrunk. Without this a session stayed silent
  for the rest of its life after its first compaction.
- **Compaction log:** one line per compaction in
  `${XDG_STATE_HOME:-~/.local/state}/context-parachute/compactions.log`
  (`epoch, session, trigger, tokens`), bounded to 500 lines. Doctor compares the
  last logged level with the configured window.
- **Snapshot:** only for `auto`. Written to a temporary file and renamed, so an
  ordinary write failure keeps the previous snapshot. Not multi-session history.

PreCompact stdout is not a supported model-context channel **[docs]**. The
PreCompact hook therefore makes no model call and injects nothing. It does not
block compaction. See the
[official hook contract](https://code.claude.com/docs/en/hooks#precompact).

## Never block compaction

No hook may block compaction, including the PreCompact hook (no exit 2). A handoff
failure must never stop the user's work, so every failure is a warning on stderr
and exit 0. **[fixture]** for PreCompact; the rule applies to all hooks.

## One injection owner per event

Each event has at most one hook that injects text into the model context:

| Event | Injector |
|---|---|
| UserPromptSubmit, PostToolUse | watcher (advisories, directive, planned reminder) |
| SessionStart with matcher `compact` | resume card (planned 1.3.0) |
| PreCompact | none (writes files and markers only) |

Two injectors on the same event would double the context and could race. A new
injection needs a new event or a change to this table.

## Doctor (shipped 1.2.0)

`./install.sh --doctor` is read-only. It reports whether the watcher and PreCompact
hooks are registered and their scripts readable, the effective context window
(config first, then `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, then the 200k default), and
whether the last auto-compaction happened far below the configured window, which
would mean the watcher stayed silent. It exits 1 only when a required hook is
missing. **[fixture]** The motivation is live: the watcher was absent from one
machine's settings for three weeks with no visible symptom. **[live]**

Planned 1.3.0: doctor warns when `HANDOFF.md` exceeds 40 KB. **[planned]**

## Window and advisories

- The watcher reads `context_window` from the global config, then the project's
  `.parachute/config.json`. If neither is set, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
  is used. **[fixture]**
- With no window configured and observed tokens above 200k, the watcher warns on
  stderr and assumes 1,000,000. An explicit window is never overridden. **[fixture]**
  Planned 1.3.0 makes this auto-grow rule the documented behavior. **[planned]**
- Advisories fire at 50/70/85% with per-stage markers. The parachute directive
  fires at `threshold_percent` (default 80) once per session. **[fixture]**
- The effective window changed in the 4-week session data (about 1M to about 200k
  around 2026-10-15). **[live]** Keep the window configurable; do not hard-code one.

## Resume after compaction (planned 1.3.0)

- `hooks/parachute-resume.sh` on `SessionStart` with matcher `compact`.
- Injects at most 3 KB from `.parachute/continue-claude.md`, else from the head of
  `HANDOFF.md`. It never injects the whole file.
- Opt-in via `install.sh --with-resume`.
- **NOT VERIFIED live.** Whether SessionStart stdout reaches the model after a real
  compaction rests on **[docs]** and fixtures only.

## Reminder: requested vs saved (planned 1.3.0)

If the directive fired but `HANDOFF.md` was not updated afterwards, the watcher
sends ONE follow-up reminder. It does not repeat. **[planned]**

## Provenance across installations

`VERSION` is the release authority for this repository. Hooks locate it relative
to themselves. The skill bundles the same value in its supported
[`metadata.version`](https://agentskills.io/specification#metadata-field) field.
The test suite checks synchronization at release time. A copied skill can thus
identify itself without the source repository or a watcher directive. **[fixture]**

Reading `VERSION` in the destination project was wrong: it either yielded no
version or silently identified a different product. Manual handoffs use the
loaded skill's metadata. Legacy copies may use a concrete current watcher
version; without either source they report `version unavailable`. Old handoffs
are historical evidence and are not retroactively assigned a version.

## Runtime and installation boundaries

- Hooks read at most the last 500 transcript lines. The latest usable main-chain
  usage supplies input/cache tokens; missing, partial, and malformed usage is
  skipped. Context size does not measure a plan's remaining quota. **[fixture]**
- Project overrides come from the event's `cwd`, or the process cwd when omitted.
  Invalid watcher config layers warn and leave earlier values intact. **[fixture]**
- Session IDs used in marker filenames must start with an alphanumeric character
  and contain only alphanumerics, dots, underscores, or hyphens (up to 128 bytes).
- Both installed hooks have a five-second host timeout. Reinstalling migrates
  exact legacy commands and applies the timeout without adding duplicate hooks.
- Hook command paths are POSIX-shell quoted, including spaces and apostrophes.
  Backups have unique names and settings temporaries share the destination
  filesystem. Uninstall filters individual handlers, preserving sibling hooks.
- A conflicting skill path aborts installation before settings change. Uninstall
  removes only the symlink created for this clone.

## Verification and limits

`./tests/run-tests.sh` exercises the shell hooks and installer in temporary homes:
profile configuration, legacy upgrades, path quoting, failure cases, PreCompact
re-arm and log, doctor, and release metadata. ShellCheck runs when installed.
**[fixture]** The suite passed 96/96 on 2026-10-20 at HEAD `32cba28`.

`.githooks/run-tests-on-commit` runs the suite before commits that stage `hooks/`,
`install.sh`, `uninstall.sh`, `tests/` or `skill/`. It is active only when
`core.hooksPath` points at `.githooks`. **[fixture]** (simulated in a scratch clone.)
`.githooks/pre-push` never blocks a push.

A separate agent exercised a copied skill in projects with no `VERSION` and
with an unrelated `9.9.9` version: all four artifact types used the bundled
`1.1.0` version and preserved existing AGENTS rules. That validates the prompt
scenarios at that time, not every model or future host release. Evidence: an
agent-run prompt check, 2026-07; not part of the suite and not a live session.

Limits that remain:

- **Re-arm after a real compaction is fixture-verified.** This review did not
  observe a live post-1.2.0 compaction with the re-arm.
- Snapshot publication is atomic but not a multi-session history or a filesystem
  durability guarantee.
- Settings installation is not coordinated with simultaneous external editors.
- The skill's behavior (what the model writes) is a prompt contract. The suite
  checks the hooks, not the model's text.
- No secret redaction. Regexes cannot guarantee sanitization, so the tool does not
  claim it. Keep secrets out of transcripts and repo files.

These remain explicit limits rather than claims of lossless recovery.
