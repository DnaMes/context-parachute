# context-parachute — Design Spec

**Date:** 2026-07-03
**Status:** Approved design, pre-implementation
**Target repo:** `github.com/DnaMes/context-parachute` (public, MIT)

## One-liner

Auto-eject session handoff for AI coding agents: when Claude Code's context window
fills up, automatically generate a session summary, `HANDOFF.md`, and ready-to-paste
continuation prompts in the project folder — so any agent (Codex, Gemini, OpenCode,
Cursor, or a fresh Claude session) can pick up the work.

## Problem

- Claude Code auto-compacts at ~95% context. Compaction loses detail, and by that
  point output quality has already degraded (community consensus: act at 70–85%).
- Existing auto-trigger tools (f3kpclon/claude-code-handoff, marcelkraemer,
  Sonovore) are all Claude→Claude only.
- Existing cross-agent handoff tools (willseltzer/claude-handoff 115★,
  agent-work-mem, OpenMOSS) are all manual.
- The intersection — **automatic trigger + cross-agent continuation artifacts,
  repo-local** — is unclaimed as of 2026-07-03 (verified via GitHub search;
  claude-mem discussion #1329 requests exactly this; Anthropic feature request
  #25689 for a threshold hook was closed unimplemented).

## Verified platform constraints (from official hooks docs)

1. No hook receives context-usage percentage directly. Hooks receive
   `transcript_path` (JSONL) and can compute current context size from the last
   assistant message's `message.usage`:
   `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
2. `PreCompact` distinguishes `trigger: "auto" | "manual"` and can block
   compaction (exit 2), but cannot force the model to produce a rich summary and
   fires too late (quality already degraded).
3. `UserPromptSubmit` hook stdout is injected as context before the model acts —
   the reliable path to make the model do something at a chosen moment.
4. Hook input arrives as **stdin JSON**, not env vars (CC ≥ 2.1.187).

## Architecture — 4 components

### 1. Watcher hook (`UserPromptSubmit`)

- Pure bash + `jq`, target < 50 ms, **fail-open** (any internal error → exit 0,
  never blocks the session).
- Reads stdin JSON → `transcript_path`, `session_id`.
- Computes context % of the 200k window from the last assistant message usage
  (formula above). Tail-read the JSONL (last N lines), do not parse the whole file.
- If `percent >= threshold` (default **80**, configurable) AND no fired-marker for
  this session: print a one-shot directive to stdout instructing Claude to invoke
  the parachute skill immediately, then continue working. Create fired-marker.
- Fired-marker: `$TMPDIR/context-parachute/<session_id>.fired` — one shot per
  session, prevents nag loops.

### 2. Parachute skill (the payload — model does the writing)

Invoked via the injected directive (or manually via `/parachute`). While context
is still fresh, the model writes:

| Artifact | Location | Content |
|---|---|---|
| `HANDOFF.md` | repo root | Agent-agnostic: Goal, Current Progress, What Worked, What Didn't Work (failed approaches!), Decisions Made + why, Files Changed, Next Steps. Create or update (read existing first). |
| `continue.md` | `.parachute/` | Generic ready-to-paste continuation prompt: self-contained, points to HANDOFF.md, includes a "verify state before trusting this document" preamble. Works in Cursor, aider, Gemini, ChatGPT, any tool. |
| `continue-claude.md` | `.parachute/` | Prompt for a fresh Claude Code session (`/clear` + paste beats compaction in quality and tokens). |
| `AGENTS.md` block | repo root | Marker-delimited section (`<!-- parachute:begin -->` … `<!-- parachute:end -->`) with the current handoff. Codex/OpenCode read AGENTS.md natively at startup — zero paste. Only the block is touched; rest of file untouched. Created if file absent (config-gated). |

Artifacts are English, committed to the repo by default (cross-device via git is
a feature). Not auto-gitignored; user decides.

### 3. PreCompact(auto) fallback hook

Covers the case where the watcher never fired (e.g. one huge turn jumps 70→96%,
or a long autonomous run with no user prompts — `UserPromptSubmit` only fires on
user input; documented v1 limitation).

- On `trigger == "auto"` and no fired-marker:
  - Inject an emergency brain-dump prompt (6-section structured summary +
    "update HANDOFF.md") — evolution of the existing
    `claude-hook-pre-compact.sh`.
  - Additionally write a bash-only snapshot (no model needed):
    `git status`, `git diff --stat`, `git log --oneline -10`, timestamp →
    `.parachute/emergency.md`.
- On `trigger == "manual"`: do nothing (user knows what they're doing).

### 4. Installer / config

- `install.sh`: idempotent; backs up `~/.claude/settings.json`, merges hooks via
  `jq`, copies skill to `~/.claude/skills/context-parachute/`. `uninstall.sh`
  reverses it.
- Config file `~/.claude/parachute.json` (global) with optional per-project
  override `.parachute/config.json`:
  ```json
  {
    "threshold_percent": 80,
    "update_agents_md": true,
    "create_agents_md": false,
    "output_dir": ".parachute"
  }
  ```
- Validate config with `jq empty`; on invalid config fall back to defaults and
  log a warning to stderr (no silent failure).

## Error handling

- All hooks fail-open: internal errors never block the session (lesson from
  issue #26 — but log the failure to stderr, never swallow silently).
- Missing/unreadable transcript → exit 0 with stderr note.
- `jq` absent → installer refuses to install (hard dependency check up front,
  not a runtime surprise).
- AGENTS.md merge is marker-based; if markers are malformed/duplicated, append a
  fresh block and warn rather than corrupting user content.

## Testing

- `bats` test suite (hooks are never shipped untested — file-based matrix):
  - Token-sum script against fixture JSONLs (normal, cache-heavy, empty,
    truncated/corrupt lines).
  - Threshold matrix: 79% no-fire, 80% fire, second call no-fire (marker).
  - Fail-open: missing transcript, malformed JSON, unset `TMPDIR`.
  - PreCompact fallback: auto vs manual trigger, marker present vs absent.
  - AGENTS.md block insert/update/malformed-marker cases.
- Manual end-to-end verification in a real Claude Code session before v1 tag.

## Repo layout

```
context-parachute/
├── README.md            # incl. comparison table vs the 8 existing tools
├── LICENSE              # MIT
├── install.sh / uninstall.sh
├── hooks/
│   ├── parachute-watch.sh      # UserPromptSubmit
│   └── parachute-precompact.sh # PreCompact fallback
├── skill/
│   └── SKILL.md         # the parachute skill
├── config/
│   └── parachute.default.json
└── tests/
    ├── *.bats
    └── fixtures/*.jsonl
```

## Relationship to existing local setup

- Replaces `~/bin/claude-hook-pre-compact.sh` (its brain-dump becomes component 3).
- The manual `/handoff` skill remains as the manual sibling; parachute reuses the
  same HANDOFF.md format.
- Local install of the public repo becomes the source of truth; claude-setup only
  references it.

## Out of scope (v1)

- Per-agent tailored prompts (`continue-codex.md`, `continue-gemini.md`) — user
  deselected; generic + AGENTS.md covers the targets.
- Continuous per-turn state maintenance (Sonovore-style) — token cost every turn.
- PostToolUse-based watcher for autonomous runs — PreCompact fallback covers it;
  revisit if the gap proves painful in practice.
- Claude Code plugin marketplace packaging — plain installer first.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Trigger | 80% watcher + PreCompact fallback | 95% too late (quality degraded, model uncontrollable at compact time); belt-and-suspenders |
| Targets | generic + AGENTS.md + Claude-resume | AGENTS.md = zero-paste native pickup for Codex/OpenCode = strongest differentiator |
| Name | `context-parachute` | `context-baton` taken (wan-huiyan, same topic); parachute metaphor matches auto-trigger; GitHub search clean 2026-07-03 |
| Language of code | pure bash + jq | zero runtime deps, matches existing hook fleet, shellcheck-able |
| Artifact language | English | global rule: persisted artifacts English |
