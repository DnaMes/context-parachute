# Recovery contract

Reviewed 2026-09-21. This describes the working implementation; changes remain
unreleased until a maintainer cuts a release.

## Two different kinds of state

The UserPromptSubmit watcher can add a directive to the next model request.
Its `.fired` marker acknowledges that directive, **not successful completion** of
the skill. The model must still write and verify `HANDOFF.md`, continuation
prompts, and the optional AGENTS block. Those files capture semantic state.

PreCompact saves mechanical state before every **automatic** compaction: git
status, diff statistics, recent commits, timestamp, and plugin version. Manual
compaction is left alone. Missing or invalid triggers warn and do nothing.
A temporary file in the output directory is renamed after writing, retaining the
previous snapshot on ordinary write failures. The snapshot is not a backup of
working file contents or a substitute for the model's decisions and next steps.

PreCompact stdout is not a supported model-context channel. The previous
implementation emitted an emergency writing prompt and tested its shell output;
that did not prove delivery to Claude. The current hook makes no model call and
does not block compaction. See the
[official hook contract](https://code.claude.com/docs/en/hooks#precompact).

## Provenance across installations

`VERSION` is the release authority for this repository. Hooks locate it relative
to themselves. The skill bundles the same value in its supported
[`metadata.version`](https://agentskills.io/specification#metadata-field) field.
The test suite checks synchronization at release time. A copied skill can thus
identify itself without the source repository or a watcher directive.

Reading `VERSION` in the destination project was wrong: it either yielded no
version or silently identified a different product. Manual handoffs now use the
loaded skill's metadata. Legacy copies may use a concrete current watcher
version; without either source they report `version unavailable`. Old handoffs
are historical evidence and are not retroactively assigned a version.

## Runtime and installation boundaries

- Hooks read at most the last 500 transcript lines. The latest usable main-chain
  usage supplies input/cache tokens; missing, partial, and malformed usage is
  skipped. Context size does not measure a plan's remaining quota.
- Global config comes from `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/parachute.json`.
  Project overrides come from the event's `cwd`, or process cwd when omitted.
  Invalid watcher config layers warn and leave earlier values intact.
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

`./tests/run-tests.sh` exercises actual shell hooks and installation in temporary
homes, including profile configuration, legacy upgrades, path quoting, failure
cases, and release metadata. ShellCheck runs when installed.

A separate agent exercised a copied skill in projects with no `VERSION` and
with an unrelated `9.9.9` version: all four artifact types used the bundled
`1.1.0` version and preserved existing AGENTS rules. This validates those prompt
scenarios, not every model or future host release.

No live Claude compaction was triggered by this review. Snapshot publication is
atomic but not a multi-session history or a filesystem durability guarantee.
Settings installation is not coordinated with simultaneous external editors.
Watch/advisory markers do not rearm after compaction. These remain explicit
limits rather than claims of lossless recovery.
