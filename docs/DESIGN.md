# context-parachute — Design

**Target repo:** `github.com/DnaMes/context-parachute` (public, MIT)
**Status:** Describes the shipped behavior of v1.2.1 and the planned v1.3.0 items,
which are marked as such. Historical 2026-07-03 decisions are kept in the
decision log. For the recovery contract and evidence limits, see
[RELIABILITY.md](RELIABILITY.md). Competing tools are in
[RELATED-TOOLS.md](RELATED-TOOLS.md).

**Evidence labels used below:**
- **[fixture]** — checked by `tests/run-tests.sh` against shell hooks and
  JSONL fixtures in temporary homes. Not a live Claude Code session.
- **[docs]** — taken from the official Claude Code hook documentation. Not
  re-tested here.
- **[live]** — observed in real sessions (the 4-week session analysis, 99
  sessions, 2026-10). Only the events listed as live were seen in production.
- **[planned]** — designed, not shipped.

## One-liner

Auto-eject session handoff for AI coding agents: when the context window fills
up, write a session summary, `HANDOFF.md`, and ready-to-paste continuation
prompts into the project folder, so any agent (Codex, Gemini, OpenCode, Cursor,
or a fresh Claude session) can pick up the work.

## Problem

- Claude Code auto-compacts near the end of the window. Compaction loses detail,
  and by then output quality has already degraded (community consensus: act at
  70–85%). **[live]** 33 auto-compactions and 0 manual in the 4-week analysis:
  long sessions compact automatically and mostly unattended.
- Auto-trigger tools that exist are mostly Claude→Claude only. Cross-agent
  handoff tools are mostly manual. The intersection (automatic trigger,
  cross-agent artifacts, repo-local) is the niche this tool occupies.
- **[live]** The watcher was removed from one machine's global `settings.json`
  by a harness diet on 2026-09-28. For three weeks no advisory fired and nothing
  visible reported it. Doctor (below) exists for this failure mode.

## Verified platform constraints

1. No hook receives the context-usage percentage. Hooks receive `transcript_path`
   (JSONL) and can compute the context size from the last main-chain assistant
   record's `message.usage`: `input_tokens + cache_creation_input_tokens +
   cache_read_input_tokens`. **[fixture]**
2. `PreCompact` distinguishes `trigger: "auto" | "manual"`. **[docs]** It can
   block compaction. **We never block** (see rules below), and PreCompact cannot
   make the model write a rich summary because it runs without a model turn.
3. `UserPromptSubmit` stdout (exit 0) is injected as context before the model
   acts. **[docs]** This is the reliable channel for a directive.
4. Hook input is **stdin JSON**, not env vars (CC ≥ 2.1.187). **[docs]**
5. **PostCompact cannot inject context.** **[docs]** The 2026-07-09 plan to
   re-arm on PostCompact was therefore dropped. Re-arming happens in PreCompact.
6. PreCompact stdout is not a supported model-context channel. **[docs]** The
   PreCompact hook therefore writes files only.

## Architecture

### 1. Watcher (`hooks/parachute-watch.sh`, UserPromptSubmit; also PostToolUse)

- Pure bash + `jq`, fail-open: every internal error exits 0 with a `WARN:` line
  on stderr. It never blocks the session. **[fixture]**
- Reads stdin JSON (`transcript_path`, `session_id`, `cwd`). Tail-reads the last
  500 transcript lines and skips corrupt or partial JSON lines. Subagent
  (`isSidechain`) records are ignored. **[fixture]**
- **Window:** `context_window` from the global config, then the project's
  `.parachute/config.json`. If none is configured, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` or the `autoCompactWindow` key of `settings.json`
  is used. If none is set and the observed tokens already exceed 200k, the
  watcher warns on stderr and assumes 1,000,000. An explicit window is never
  overridden. **[fixture]** Doctor reports the effective window. **[fixture]**
- **Advisories:** escalating stages at 50/70/85% (wording gets stronger; each
  stage fires once per session; a stage does not nag twice; the highest stage
  wins). **[fixture]** Motivation: four parallel sessions reached 67–99% of a
  1M window on 2026-08-29. **[live]**
- **Directive:** at `threshold_percent` (default 80) the one-shot parachute
  directive is printed to stdout, telling the model to invoke the skill now.
  The `.fired` marker records that the directive was emitted. It does **not**
  prove the handoff was written. **[fixture]**
- **Markers** live in `$TMPDIR/context-parachute/<session_id>.fired` and per-stage
  advisory markers. PreCompact clears them (re-arm), see component 3.
- **PostToolUse mode** (opt-in, `install.sh --with-posttool`): the same watcher
  runs on PostToolUse for long tool loops with no prompt. It is throttled to one
  check per 30 s per session (`PARACHUTE_TICK_SECONDS`), and its output is
  wrapped as `additionalContext`. **[fixture]** Live use: not observed yet.
- **Planned 1.3.0 [planned]:** if the directive fired but `HANDOFF.md` was not
  updated afterwards, the watcher sends ONE follow-up reminder ("requested vs
  saved"). It sends no more than one.

### 2. Parachute skill (the payload; the model writes)

Invoked via the directive or manually (`/parachute`). While context is fresh the
model writes:

| Artifact | Location | Content |
|---|---|---|
| `HANDOFF.md` | repo root | Goal, Current Progress, What Worked, What Didn't Work, Decisions + why, Files Changed, Next Steps. Read existing first. Size budget: ≤ 20 KB, current state in the first ~3 KB, older sections archived to `.parachute/handoff-archive/<date>.md`. |
| `continue.md` | `.parachute/` | Generic ready-to-paste prompt, with a "verify state before trusting" preamble. Works in any tool. |
| `continue-claude.md` | `.parachute/` | Prompt for a fresh Claude Code session (`/clear` + paste). |
| AGENTS.md block | repo root | Marker-delimited (`<!-- parachute:begin -->` … `<!-- parachute:end -->`). Only the block is touched. Created only if `create_agents_md` is true. |

Every artifact carries the footer `generated by context-parachute v<VERSION>`
from the loaded skill's `metadata.version`, never from the project's `VERSION`.
Artifacts are English. Writing is Read-before-Write per file. **[docs]** (the
skill is a prompt; compliance is not tested by the suite).

### 3. PreCompact hook (`hooks/parachute-precompact.sh`)

Runs on every compaction, `auto` and `manual`. Always exits 0. **[fixture]**

- **Re-arm:** clears the session's `.fired` and advisory markers, so the watcher
  warns again after the context has shrunk. **[fixture]** (Shipped 1.2.0.)
- **Compaction log:** appends `epoch, session, trigger, tokens` to
  `${XDG_STATE_HOME:-~/.local/state}/context-parachute/compactions.log`, bounded to
  500 lines (trimmed to 200). Doctor reads it. **[fixture]**
- **Snapshot (auto only):** a mechanical `emergency.md` in `output_dir`: git
  status, diff stat, last 10 commits, timestamp. Written to a temporary file and
  renamed, so a failed write keeps the previous snapshot. The path is added to the
  repo's local `.git/info/exclude`. **[fixture]**
- **Manual compaction:** re-arm and log only, no snapshot. The user is in control.
- **No injection, no model call, no blocking.** The emergency brain-dump prompt
  of the original design was dropped: PreCompact stdout does not reach the model
  reliably. **[docs]**

### 4. Resume hook (`hooks/parachute-resume.sh`, shipped 1.3.0)

- Event: `SessionStart` with matcher `compact`, i.e. after an auto-compaction.
- Injects a bounded card, at most 3 KB, from `.parachute/continue-claude.md` if it
  exists, otherwise from the head of `HANDOFF.md`. It never injects the whole file.
- Opt-in: `install.sh --with-resume`. Not registered by default.
- The card is a pointer plus the current next step, not a summary generator.
- Status: shipped. Whether SessionStart(compact) stdout reaches the model is
  **[docs]**; this session's own post-compaction card is an observation, not a test.

### 5. Installer, uninstaller, doctor

- `install.sh` is idempotent. It backs up `settings.json`, merges hooks with `jq`
  (never replacing sibling hooks), sets a 5 s host timeout, and symlinks the skill
  to `~/.claude/skills/context-parachute/`. A conflicting skill path aborts before
  settings change. **[fixture]**
- Options: `--with-posttool` (shipped 1.2.0), `--doctor` (shipped 1.2.0),
  `--with-resume` (shipped 1.3.0).
- `--doctor` is read-only. It reports whether the watcher and PreCompact hooks are
  registered and their scripts readable, the effective window, and whether the
  last auto-compaction happened far below the window. It exits 1 only when a
  required hook is missing. **[fixture]** Planned 1.3.0: warn when `HANDOFF.md` is
  over 40 KB.
- `uninstall.sh` removes only the handlers and symlink this clone installed.
  **[fixture]**
- Config: `${CLAUDE_CONFIG_DIR:-~/.claude}/parachute.json` (global), then
  `.parachute/config.json` (project). Keys: `threshold_percent`, `context_window`,
  `output_dir`, `update_agents_md`, `create_agents_md`. Invalid files are ignored
  with a warning. Default values are in `config/parachute.default.json`.

## Rules

- **Never block compaction.** PreCompact always exits 0. No hook uses exit 2.
- **Fail-open.** Internal errors never block the session, and are reported on
  stderr, never swallowed silently.
- **Single injection owner per event.** Each event has at most one hook that
  injects text into the model context:
  - UserPromptSubmit and PostToolUse → the watcher (advisories and directive).
  - SessionStart(compact) → the resume hook (shipped 1.3.0).
  - PreCompact → never injects. It only writes files and markers.
  Two injectors on one event would double the context and race each other.
- **Mechanical hooks write files; the model writes meaning.** Hooks never claim to
  have written a semantic handoff.
- **No secret redaction.** Regexes cannot guarantee that a snapshot or handoff is
  free of secrets, so the tool does not claim to redact. Users keep secrets out of
  transcripts and repo files. Snapshots include only git metadata.

## Testing

- `tests/run-tests.sh` (bash runner; bats is not used). It covers the token sum
  on fixtures, the threshold and advisory matrix, fail-open cases, PreCompact
  re-arm, log and snapshot, installer idempotency and path quoting, doctor,
  version consistency and shellcheck. **[fixture]** Each run isolates `HOME` and
  `TMPDIR`, so the machine's own config cannot change results.
- `.githooks/run-tests-on-commit` runs the suite before commits that touch code,
  tests or the skill. It exempts exactly the tag-consistency line that fails
  between a VERSION bump and its tag. **[fixture]** (simulated in a scratch clone.)
- **Live verification is still needed** for SessionStart(compact) injection and for
  PostToolUse in practice. Until then those claims are **[docs]** or **[planned]**.

## Repo layout

```
context-parachute/
├── README.md, CHANGELOG.md, VERSION
├── install.sh / uninstall.sh
├── hooks/
│   ├── parachute-watch.sh        # UserPromptSubmit (+ PostToolUse mode)
│   ├── parachute-precompact.sh   # PreCompact: re-arm, log, auto snapshot
│   ├── parachute-lib.sh          # shared token measurement and config helpers
│   └── parachute-resume.sh       # SessionStart compact resume card
├── skill/SKILL.md                # the parachute skill (metadata.version)
├── config/parachute.default.json
├── .githooks/                    # pre-commit (tests), pre-push (never blocks)
├── docs/                         # DESIGN, RELIABILITY, RELATED-TOOLS, specs
└── tests/run-tests.sh + fixtures/
```

### 6. Other tools (1.4.0 — `install-host.sh`, `hooks/parachute-host.sh`, `integrations/pi/`)

One bash+jq code base; each host gets the thinnest possible adapter.

- Codex: the core hooks are registered directly (same hook schema as Claude) with
  `PARACHUTE_HOST=codex`; the one-time `/hooks` trust cannot be automated.
- Pi: a TypeScript extension spawns the same hooks (`before_agent_start` injects a hidden
  message, `session_before_compact` snapshots, `session_compact` queues the resume card).
- Gemini CLI, agy, Cursor: `parachute-host.sh <host> <Event>` normalises the payload,
  runs the core hook and wraps its text in the host's response format. Hosts without a
  post-compaction injection event get a `<sid>.compacted` marker; the next prompt event
  injects the resume card. agy detects compaction by `CHECKPOINT` records and has no
  PreCompact event (no emergency snapshot). Cursor transcripts have no token usage, so
  `afterAgentResponse` usage is recorded in an adapter file.
- Context window: `PARACHUTE_CONTEXT_WINDOW` from the adapter (gemini 524288, agy 250000,
  Cursor from `preCompact`, Pi from `ctx.getContextUsage()`); Codex's rollout carries its own.

## Out of scope

- **Statusline bridge** — decided against in the v1.3 scope review. The watcher
  measures from the transcript and does not depend on a statusline.
- **Semantic PreCompact card** — PreCompact has no model turn; semantic content
  stays in the skill-written artifacts.
- **Secret redaction** — not guaranteed by regexes (see Rules).
- **Stop-hook handoff forcing** — a forced write at stop would block or delay the
  session; the watcher's reminder is the bounded alternative.
- **Per-agent prompts** — only `continue.md` and `continue-claude.md` are generated;
  `parachute-resume.sh --tool NAME` also reads a hand-written `continue-NAME.md`.
- **Continuous per-turn state maintenance** — token cost on every turn.
- **Plugin marketplace packaging** — plain installer first.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Trigger | 80% directive + 50/70/85% advisories + PreCompact re-arm | 95% is too late (quality degraded); repeated stages suit long sessions |
| Re-arm point | PreCompact (not PostCompact) | PostCompact cannot inject context; PreCompact clears markers for both trigger kinds |
| Window | config → `CLAUDE_CODE_AUTO_COMPACT_WINDOW` → 1M guard above 200k | No reliable window signal in the transcript; explicit values always win |
| Compaction | never blocked | A handoff failure must not stop the user's work |
| Injection | one owner per event | Two injectors double the context and race |
| Mechanical snapshot | auto compaction only | Manual compaction is the user's decision |
| Targets | generic + AGENTS.md + Claude resume | AGENTS.md gives zero-paste pickup for Codex/OpenCode |
| Name | `context-parachute` | Metaphor matches the auto trigger; name was clear at the 2026-07-03 search |
| Language | pure bash + jq | zero runtime deps, shellcheck-able, matches the hook fleet |
| Artifact language | English | persisted artifacts are English regardless of chat language |
