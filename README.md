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

If the default is left in place and observed tokens exceed it, the watcher emits
a one-line `WARN:` to stderr as a nudge — it does not change the trigger decision.

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
- There is no native Codex/Gemini watcher or startup recovery hook in this repo.
  The portable skill, generic prompt, and `AGENTS.md` block cover manual transfer.

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
