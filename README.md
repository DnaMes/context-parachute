# context-parachute 🪂

**Auto-eject session handoff for AI coding agents.**

When Claude Code's context window fills up, context-parachute automatically writes
a session summary, a `HANDOFF.md`, and ready-to-paste continuation prompts into your
project folder. Any agent (Codex, Gemini, OpenCode, Cursor, or a fresh Claude
session) can then pick up the work without losing the thread.

No daemon, no database, no runtime dependencies beyond `bash` + `jq`. Two fail-open
hooks and a skill.

## The problem

Long coding sessions accumulate state that is easy to lose during compaction
or a tool switch: failed approaches, the next concrete action, and the reasons
behind decisions. context-parachute asks the model to save those details while
there is still room to do so, with a default threshold of 80%.

The handoff stays in ordinary project files that another agent can read. Hooks
currently automate the Claude Code side; the skill and artifacts are portable.

## How it works

```
                    every user prompt
                          │
                          ▼
        ┌──────────────────────────────────┐
        │  parachute-watch.sh               │   UserPromptSubmit hook
        │  reads transcript, computes % of  │   (fail-open, bounded tail read)
        │  the 200k window from the last    │
        │  assistant message's token usage  │
        └──────────────────────────────────┘
                          │
              percent >= threshold (default 80)?
                    │ yes        │ no
                    ▼            ▼
        inject a one-shot     do nothing
        directive → Claude
        invokes the skill
                    │
                    ▼
        ┌──────────────────────────────────┐
        │  context-parachute skill          │   the model writes, while
        │  writes handoff artifacts while   │   context is still fresh
        │  context is still fresh           │
        └──────────────────────────────────┘

        A fired-marker (one per session) prevents nagging.

        Belt-and-suspenders: parachute-precompact.sh (PreCompact hook) saves
        an atomic git snapshot before every automatic compaction, including
        long autonomous runs. A watcher marker does not prove a handoff was
        completed. PreCompact does not provide a model-writing turn.
```

### Escalating context advisories

The watcher reports the highest reached stage at 50%, 70%, or 85%, once per
stage per session. These markers are separate from the one-shot handoff marker.
The measurement is the latest usable main-chain input usage, including cache
reads and cache creation; partial assistant records without valid usage are
skipped. It is **not a billing estimate or subscription quota measurement**.

| Stage | Advice |
|---|---|
| 50% | Keep large reads focused and retain the next concrete step. |
| 70% | Preserve state and plan compaction at a natural break. |
| 85% | Save the handoff before compaction; continue the user's task. |

Advisories do not authorize delegation or require the agent to stop working.

### Artifacts written

| Artifact | Location | For |
|---|---|---|
| `HANDOFF.md` | repo root | Agent-agnostic session state: Goal, Progress, What Worked, What Didn't Work, Decisions + why, Files Changed, Next Steps. |
| `continue.md` | `.parachute/` | Generic ready-to-paste prompt. Works in Cursor, aider, Gemini, ChatGPT, any tool. |
| `continue-claude.md` | `.parachute/` | Fresh Claude Code session prompt. `/clear` + paste beats compaction on quality and tokens. |
| `AGENTS.md` block | repo root | Marker-delimited block. Codex and OpenCode read `AGENTS.md` natively at startup → **zero-paste pickup.** |

Artifacts are English and remain ordinary project files. They are neither
automatically committed nor gitignored; you decide what to track or share.

## Install

Requires `bash` and `jq`.

```bash
git clone https://github.com/DnaMes/context-parachute.git
cd context-parachute
./install.sh
```

The installer:

- **appends** its two hook blocks to `~/.claude/settings.json` (never clobbers
  your existing hooks), idempotent and safe to re-run;
- backs up `settings.json` first (unique names, including repeated operations);
- symlinks the skill to `~/.claude/skills/context-parachute`;
- seeds `~/.claude/parachute.json` with defaults;
- quotes hook paths for the shell, migrates this clone's older registrations in
  place, and bounds both hooks with a five-second timeout.

`CLAUDE_CONFIG_DIR` overrides `~/.claude` for settings, skills, and configuration.
A conflicting skill directory or symlink is reported before settings change.
Re-run the installer after upgrading to migrate registered commands and timeouts.

`./install.sh --with-posttool` additionally registers the watcher as a `PostToolUse`
hook (wrapped as `additionalContext`, one check per 30 s per session), which covers
long unattended tool loops where no prompt arrives. `./install.sh --doctor` is a
read-only health check: it verifies that the watcher and PreCompact hooks are
registered with a readable script, prints the effective window, and warns when the
last auto-compaction (recorded in
`${XDG_STATE_HOME:-~/.local/state}/context-parachute/compactions.log`) happened
far below the configured window. Every compaction also re-arms the session's
markers, so advisories fire again afterwards.

`./install.sh --with-resume` registers a `SessionStart` hook with matcher `compact`.
After an auto-compaction nothing else re-surfaces the handoff, so this injects one
bounded card (`<output_dir>/continue-claude.md`, else the repo's `HANDOFF.md`,
3000 bytes by default, labelled `STALE` after 7 days, plus a pointer to
`emergency.md`). It ignores `startup`, `resume` and `clear`, so a handoff is never
injected twice. The doctor also warns when `HANDOFF.md` exceeds 40 KB.

If the watcher asked for a handoff and `HANDOFF.md` was still not touched two
minutes later, it sends one reminder (once per compaction cycle).

Tunables (environment): `PARACHUTE_TICK_SECONDS` (PostToolUse throttle, 30),
`PARACHUTE_REMIND_AFTER` (reminder delay in seconds, 120), `PARACHUTE_RESUME_MAX_BYTES`
(3000), `PARACHUTE_RESUME_MAX_AGE_DAYS` (7).

Uninstall removes only this clone's commands and skill symlink, preserves other
handlers even within the same block, and keeps the config file:

```bash
./uninstall.sh
```

## Configuration

Global config at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/parachute.json`, with an
optional per-project override at `.parachute/config.json`. Hooks honor the event's
`cwd`, falling back to the process directory when it is omitted. Values merge in
order: defaults, global config, project override. Invalid config warns on stderr
and leaves the previous valid values in place.

```json
{
  "threshold_percent": 80,
  "context_window": 200000,
  "update_agents_md": true,
  "create_agents_md": false,
  "output_dir": ".parachute"
}
```

| Key | Default | Meaning |
|---|---|---|
| `threshold_percent` | `80` | Integer 1–100: fire when context reaches this % of the window. |
| `context_window` | `200000` | Positive integer up to 1,000,000,000: token budget to measure against. |
| `update_agents_md` | `true` | Maintain the marker-delimited `AGENTS.md` block. |
| `create_agents_md` | `false` | Create `AGENTS.md` if it doesn't exist yet. |
| `output_dir` | `.parachute` | Non-empty path without control characters for `continue*.md` and `emergency.md`. |

### 1M-context sessions

`context_window` defaults to `200000`. Set it to the actual window of your session.
**If you run a 1M-context session, you must set
`context_window: 1000000`** — the watcher cannot reliably detect the real window
from the transcript (the model string doesn't carry it, and inferring it from
observed tokens is circular at the trigger threshold). Left at the default on a
1M session, the parachute fires at ~16% actual fill instead of 80%.

Set it globally if you run 1M by default (`~/.claude/parachute.json`), or
per-project via `.parachute/config.json`:

```json
{
  "context_window": 1000000
}
```

Without a configured `context_window`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (if set) is
used as the window; an explicit config value always wins.

If no window is configured (no `context_window`, no env var) and observed tokens
exceed the 200000 default, the window is evidently larger: the watcher assumes
1000000 for that check and says so in a one-line `WARN:` on stderr. An explicitly
configured window is never overridden. This removes the false "parachute at 16%"
on 1M sessions, but setting `context_window` stays the reliable way.

## Other tools

The core hooks are tool-agnostic bash+jq. `./install-host.sh <codex|pi|gemini|cursor|agy|all>`
registers them with other agent CLIs (`--doctor` checks, `--uninstall` removes only
this clone's entries; foreign config files are backed up first, absent hosts are
skipped by `all`).

| Tool | Mechanism | Watcher | PreCompact snapshot | Resume card | Verified |
|---|---|---|---|---|---|
| Codex | `~/.codex/hooks.json`, core hooks directly | prompt + tool | yes | yes (SessionStart `compact`) | hook fires, rollout parsed; model-side injection NOT VERIFIED |
| Pi | extension `~/.pi/agent/extensions/context-parachute.ts` | prompt + turn end | yes | yes (next turn) | live: directive reached the model (`tests/pi-extension-smoke.sh`) |
| Gemini CLI | `~/.gemini/settings.json` via `hooks/parachute-host.sh` | prompt + tool | yes | at next prompt | unit tests only |
| Cursor | `~/.cursor/hooks.json` via `hooks/parachute-host.sh` | prompt + tool | yes | at next prompt | unit tests only; hooks did not fire in `cursor-agent -p` |
| agy | `~/.gemini/config/hooks.json` via `hooks/parachute-host.sh` | per model call (30 s throttle) | no (no event) | after a checkpoint | parser verified on a real transcript; hook NOT run live |

- **Codex** requires a one-time trust: run `/hooks` in Codex and trust the new entries.
- Non-Claude hosts get "read and follow `skill/SKILL.md`" in the directive instead of
  "invoke the skill", and the resume card prefers `continue-<tool>.md`, then `continue.md`.
- The agy hook is passive (no account rotation or agy automation). Cursor transcripts
  carry no token usage, so the adapter records `afterAgentResponse` usage itself.
- Environment: `PARACHUTE_HOST` (set by the adapters), `PARACHUTE_CONTEXT_WINDOW`
  (adapter-supplied window), `PARACHUTE_GEMINI_WINDOW` (default 524288, the auto-compress
  point), `PARACHUTE_AGY_WINDOW` (default 250000, the observed checkpoint size). The
  config `window` still wins over all of them.
- Hosts without a post-compaction injection event get a `<session>.compacted` marker;
  the next prompt event injects the resume card.

## Related tools

The landscape has changed since the original design. Similar projects now include
statusline monitoring, startup recovery, host adapters, and handoff validation.
See [the researched comparison](docs/RELATED-TOOLS.md) for primary sources and
concrete ideas worth evaluating; no exclusivity claim is made.

## Limitations

- `UserPromptSubmit` only fires on user input. During autonomous work, the
  PreCompact fallback saves git status, diff statistics, recent commits, and a
  timestamp. It **cannot capture unwritten decisions or guarantee lossless
  semantic recovery**. Its stdout is not a supported prompt-injection channel.
  See the [Claude Code hook reference](https://code.claude.com/docs/en/hooks#precompact).
- `emergency.md` is the latest automatic snapshot, replaced atomically. Concurrent
  sessions in one directory can replace each other's snapshots; session-specific
  history is not implemented.
- Handoff/advisory markers remain one-shot per session, including after compaction.
  A long session may therefore need a manual handoff later.
- Non-Claude tools are supported through `install-host.sh` (see "Other tools") with
  the verification levels listed there. Cursor, Gemini CLI and agy hooks have not been
  observed firing in a live session; agy has no PreCompact event, so no emergency
  snapshot. The portable skill, generic prompt and `AGENTS.md` block remain the manual path.

## Design

The historical rationale lives in [`docs/DESIGN.md`](docs/DESIGN.md). Current
recovery guarantees are documented in [`docs/RELIABILITY.md`](docs/RELIABILITY.md).

Hooks are pure `bash` + `jq`, `shellcheck`-clean, and **fail-open**: any internal
error exits 0 and never blocks your session; it only logs a `WARN:` to stderr.
Run the test suite:

```bash
./tests/run-tests.sh
```

## Versioning

[SemVer](https://semver.org/). The canonical version is the [`VERSION`](VERSION)
file at the repo root. Hooks read that file relative to their installation. The
portable skill carries the same version in `metadata.version`, so manual use in
an unrelated project never reads that project's `VERSION` or emits `vunknown`.
Legacy skills without metadata can use a concrete watcher version; otherwise they
report `version unavailable`. Existing historical artifacts are not restamped.
To cut a release:

1. Bump [`VERSION`](VERSION) and `metadata.version` in [`skill/SKILL.md`](skill/SKILL.md).
2. Move the `[Unreleased]` notes into a new dated section in [`CHANGELOG.md`](CHANGELOG.md).
3. `git tag -a "v$(cat VERSION)" -m "context-parachute v$(cat VERSION)"` — the test suite asserts VERSION, CHANGELOG top, and tag all match.

## License

MIT. See [LICENSE](LICENSE).
