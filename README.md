# context-parachute 🪂

**Auto-eject session handoff for AI coding agents.**

When Claude Code's context window fills up, context-parachute automatically writes
a session summary, a `HANDOFF.md`, and ready-to-paste continuation prompts into your
project folder. Any agent (Codex, Gemini, OpenCode, Cursor, or a fresh Claude
session) can then pick up the work without losing the thread.

No daemon, no database, no runtime dependencies beyond `bash` + `jq`. Two fail-open
hooks and a skill.

## The problem

Claude Code auto-compacts around 95% context. By then two things have already gone
wrong:

1. **Compaction flattens the specifics.** Failed approaches, the exact next step,
   the reason behind a decision: the details that made the session productive get
   summarized away.
2. **Quality has already degraded.** Most people hand off at **70–85%**, not 95%.

Existing tools each solve half of this:

- Auto-trigger handoff tools only go **Claude → Claude**. They can't hand off to
  another agent.
- Cross-agent handoff tools are **manual**. You have to remember to run them, which
  is the first thing you drop when you're deep in a task.

context-parachute is the intersection: **automatic trigger + cross-agent,
repo-local continuation artifacts.**

## How it works

```
                    every user prompt
                          │
                          ▼
        ┌──────────────────────────────────┐
        │  parachute-watch.sh               │   UserPromptSubmit hook
        │  reads transcript, computes % of  │   (fail-open, <50ms)
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

        Belt-and-suspenders: parachute-precompact.sh (PreCompact hook) catches
        the case where the watcher never fired — a single huge turn, or a long
        autonomous run with no user prompts — and injects an emergency brain
        dump plus a bash-only git snapshot before auto-compaction runs.
```

### Artifacts written

| Artifact | Location | For |
|---|---|---|
| `HANDOFF.md` | repo root | Agent-agnostic session state: Goal, Progress, What Worked, What Didn't Work, Decisions + why, Files Changed, Next Steps. |
| `continue.md` | `.parachute/` | Generic ready-to-paste prompt. Works in Cursor, aider, Gemini, ChatGPT, any tool. |
| `continue-claude.md` | `.parachute/` | Fresh Claude Code session prompt. `/clear` + paste beats compaction on quality and tokens. |
| `AGENTS.md` block | repo root | Marker-delimited block. Codex and OpenCode read `AGENTS.md` natively at startup → **zero-paste pickup.** |

Artifacts are English and committed to the repo by default, so cross-device handoff
via git comes for free. Nothing is auto-gitignored; you decide.

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
- backs up `settings.json` first (timestamped);
- symlinks the skill to `~/.claude/skills/context-parachute`;
- seeds `~/.claude/parachute.json` with defaults.

Uninstall reverses everything except the config file:

```bash
./uninstall.sh
```

## Configuration

Global config at `~/.claude/parachute.json`, with an optional per-project override
at `.parachute/config.json` (cwd). Invalid config → warn to stderr and fall back to
defaults (never a silent failure).

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
| `threshold_percent` | `80` | Fire when context reaches this % of the window. |
| `context_window` | `200000` | Token budget to measure against. |
| `update_agents_md` | `true` | Maintain the marker-delimited `AGENTS.md` block. |
| `create_agents_md` | `false` | Create `AGENTS.md` if it doesn't exist yet. |
| `output_dir` | `.parachute` | Where `continue*.md` and `emergency.md` go. |

## Comparison to existing tools

As of 2026-07-03, no other tool combines an **automatic** context-threshold trigger
with **cross-agent, repo-local** continuation artifacts.

| Tool | Auto-trigger | Cross-agent handoff | Repo-local artifacts |
|---|---|---|---|
| **context-parachute** | ✅ 80% watcher + PreCompact fallback | ✅ generic + AGENTS.md + Claude-resume | ✅ HANDOFF.md + `.parachute/` |
| f3kpclon/claude-code-handoff | ✅ | ❌ Claude→Claude | ✅ |
| marcelkraemer89-web | ✅ | ❌ Claude→Claude | ✅ |
| Sonovore (per-turn state) | ✅ (continuous) | ❌ Claude→Claude | ✅ |
| willseltzer/claude-handoff (115★) | ❌ manual | ✅ | ✅ |
| REMvisual/claude-handoff | ❌ manual | ✅ | ✅ |
| agent-work-mem | ❌ manual | ✅ | ✅ |
| OpenMOSS/claude-codex-handoff | ❌ manual | ✅ Claude↔Codex | ✅ |
| mjbarefo/baton | ❌ manual | ✅ | ✅ |
| Sting25 | ✅ | ❌ Claude→Claude | ✅ |

That intersection cell, auto-trigger plus cross-agent, is what context-parachute
fills. (claude-mem discussion #1329 requests exactly this; Anthropic feature request
#25689 for a native threshold hook was closed unimplemented.)

## v1 limitations

- **`UserPromptSubmit` only fires on user input.** During a fully autonomous run
  with no prompts, the watcher can't run. The `PreCompact` fallback covers this:
  on auto-compaction with no prior fire, it injects an emergency brain dump and
  writes a `git status` / `diff --stat` / `log` snapshot to
  `.parachute/emergency.md`. It covers the gap rather than preventing it, and nothing is lost.
- No per-agent tailored prompts (`continue-codex.md`, etc.) in v1. The generic
  prompt plus the native `AGENTS.md` block already cover Codex and OpenCode.

## Design

Full design rationale, verified platform constraints, and the decisions log live in
[`docs/DESIGN.md`](docs/DESIGN.md).

Hooks are pure `bash` + `jq`, `shellcheck`-clean, and **fail-open**: any internal
error exits 0 and never blocks your session; it only logs a `WARN:` to stderr.
Run the test suite:

```bash
./tests/run-tests.sh
```

## License

MIT. See [LICENSE](LICENSE).
