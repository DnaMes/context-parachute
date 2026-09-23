#!/bin/bash
# context-parachute — UserPromptSubmit watcher hook.
#
# WHY: Claude Code auto-compacts at ~95% context, by which point output quality
# has already degraded and detail is lost. This hook computes current context
# usage from the transcript and, once past a threshold (default 80%), injects a
# one-shot directive telling Claude to invoke the context-parachute skill NOW —
# while context is still fresh — to write cross-agent handoff artifacts.
#
# CONTRACT: input is stdin JSON (CC >= 2.1.187), NOT env vars. Fields used:
#   .transcript_path  (JSONL path)  .session_id
# UserPromptSubmit stdout on exit 0 is injected as context before the model acts.
#
# FAIL-OPEN: every internal error -> exit 0 (never blocks the session). All
# diagnostics go to stderr with a WARN: prefix, never swallowed silently.
set -euo pipefail

warn() { printf 'WARN: context-parachute/watch: %s\n' "$1" >&2; }

# Version from the VERSION file next to this script. Fail-open: missing or
# unreadable -> "unknown", never an error (stamped into artifacts for provenance).
VERSION_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/VERSION"
VERSION="unknown"
[[ -r "$VERSION_FILE" ]] && VERSION="$(head -n1 "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$VERSION" ]] || VERSION="unknown"

# --- read stdin JSON --------------------------------------------------------
STDIN_JSON=""
if [[ ! -t 0 ]]; then
    STDIN_JSON="$(cat 2>/dev/null || true)"
fi
[[ -z "$STDIN_JSON" ]] && { warn "empty stdin"; exit 0; }

command -v jq >/dev/null 2>&1 || { warn "jq not found"; exit 0; }

TRANSCRIPT="$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
[[ -z "$TRANSCRIPT" ]] && { warn "no transcript_path in input"; exit 0; }
[[ -r "$TRANSCRIPT" ]] || { warn "transcript not readable: $TRANSCRIPT"; exit 0; }
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] || { warn "missing or invalid session_id"; exit 0; }

# Hook launchers may retain a different working directory from the event.
PROJECT_DIR="$(printf '%s' "$STDIN_JSON" | jq -r '.cwd | select(type == "string" and length > 0)' 2>/dev/null || true)"
if [[ -n "$PROJECT_DIR" ]]; then
    cd -- "$PROJECT_DIR" 2>/dev/null || { warn "cannot enter event cwd: $PROJECT_DIR"; exit 0; }
fi

# --- load config (defaults -> global -> per-project override) ---------------
THRESHOLD=80
WINDOW=200000
OUTPUT_DIR=".parachute"
# Escalating advisory stages, checked before the parachute threshold.
# WHY: a single one-shot warning at 75% did not stop four parallel sessions
# reaching 67-99% of a 1M window on 2026-08-29, together burning ~1B tokens
# per hour in cache reads alone. Each stage fires once per session.
WARN_STAGES="50 70 85"

load_config() {
    local file="$1"
    [[ -r "$file" ]] || return 0
    if ! jq -e '
        type == "object" and
        (if has("threshold_percent") then (.threshold_percent |
            type == "number" and . == floor and . >= 1 and . <= 100) else true end) and
        (if has("context_window") then (.context_window |
            type == "number" and . == floor and . >= 1 and . <= 1000000000) else true end) and
        (if has("output_dir") then (.output_dir |
            type == "string" and length > 0 and (explode | all(.[]; . >= 32 and . != 127))) else true end)
    ' "$file" >/dev/null 2>&1; then
        warn "invalid config, ignoring: $file"
        return 0
    fi
    local t w o
    t="$(jq -r '.threshold_percent // empty' "$file" 2>/dev/null || true)"
    w="$(jq -r '.context_window // empty'   "$file" 2>/dev/null || true)"
    o="$(jq -r '.output_dir // empty'       "$file" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] && THRESHOLD="$t"
    [[ "$w" =~ ^[0-9]+$ ]] && WINDOW="$w"
    [[ -n "$o" ]] && OUTPUT_DIR="$o"
    # MUST stay: a function returns the status of its LAST command, and under
    # `set -e` a failing function call at top level kills the script. Without
    # this, a config that omits `output_dir` (the documented, common case —
    # `{"threshold_percent":65,"context_window":1000000}`) made the final test
    # false, so load_config returned 1 and the whole watcher died at the call
    # site with exit 1 and NO stderr. The hook then never reached the threshold
    # check: every advisory and every parachute trigger was silently dead,
    # while Claude Code showed only "UserPromptSubmit hook error / Failed with
    # non-blocking status code: No stderr output" on every single prompt.
    return 0
}
load_config "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/parachute.json"
load_config "$(pwd)/.parachute/config.json"
[[ "$WINDOW" -gt 0 ]] || { warn "context_window <= 0, using 200000"; WINDOW=200000; }

# --- fired-marker: one shot per session -------------------------------------
MARKER_DIR="${TMPDIR:-/tmp}/context-parachute"
MARKER="${MARKER_DIR}/${SESSION_ID}.fired"
# NOTE: the parachute marker stays one-shot (the handoff is written once), but
# the advisory stages below have their own per-stage markers, so a session that
# ignores the first warning is warned again at every later stage.
PARACHUTE_FIRED=0
[[ -e "$MARKER" ]] && PARACHUTE_FIRED=1

# --- compute context % from last main-chain assistant usage -----------------
# Sum input_tokens + cache_creation_input_tokens + cache_read_input_tokens of
# the LAST assistant line that is not a subagent turn (.isSidechain==false).
# Tail-read only the last 500 lines — do not parse the whole transcript.
# -R + fromjson? makes each line tolerant: a corrupt/truncated JSONL line
# becomes null and is skipped rather than aborting the whole jq stream.
# Portable reverse-read: take the LAST matching line from the last 500, instead
# of reversing the file to take the first. Avoids GNU-only and BSD-only reverse
# tools, so the watcher runs on Linux and macOS alike. Verified byte-identical
# output to previous reverse approach on all fixtures.
USAGE_LINE="$(tail -n 500 "$TRANSCRIPT" 2>/dev/null \
    | jq -c -R 'fromjson? | objects | select(.type=="assistant" and (.isSidechain != true)) |
        .message.usage | objects |
        select(.input_tokens | type == "number") |
        select([.input_tokens, (.cache_creation_input_tokens // 0), (.cache_read_input_tokens // 0)] |
            all(.[]; type == "number" and . >= 0 and . == floor))' 2>/dev/null \
    | tail -n 1 || true)"
[[ -z "$USAGE_LINE" ]] && { warn "no assistant usage found in transcript tail"; exit 0; }

TOKENS="$(printf '%s' "$USAGE_LINE" | jq -r \
    '((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' \
    2>/dev/null || true)"
[[ "$TOKENS" =~ ^[0-9]+$ ]] || { warn "could not parse token usage"; exit 0; }

PERCENT=$(( TOKENS * 100 / WINDOW ))

# --- guard: default window silently wrong on a 1M-context session -----------
# WINDOW==200000 means no context_window override was configured (default or
# explicit). If observed tokens already exceed that, the session is almost
# certainly running a larger window (e.g. Opus [1m]) and PERCENT is bogus.
# Warn, but never change the trigger decision below.
if [[ "$WINDOW" -eq 200000 ]] && (( TOKENS > WINDOW )); then
    warn "observed tokens ($TOKENS) exceed configured context_window ($WINDOW); if this is a 1M session set context_window: 1000000"
fi

# --- advisory stages --------------------------------------------------------
# The transcript measures input context, not billing or subscription quota.
# Keep advisories subordinate to the handoff and the user's active task.
# Pick the HIGHEST stage reached, not the first — iterating low-to-high and
# breaking on the first match would always print the mildest message.
STAGE=0
for s in $WARN_STAGES; do (( PERCENT >= s && s > STAGE )) && STAGE=$s; done

for stage in $STAGE; do
    (( stage > 0 )) || continue
    stage_marker="${MARKER_DIR}/${SESSION_ID}.warn${stage}"
    [[ -e "$stage_marker" ]] && continue
    mkdir -p "$MARKER_DIR" 2>/dev/null || break
    : > "$stage_marker" 2>/dev/null || true

    if (( stage >= 85 )); then
        cat <<EOF
CONTEXT-BUDGET (${PERCENT}% of ${WINDOW}): context is high (~${TOKENS} input tokens).
Save the handoff before compacting if a CONTEXT-PARACHUTE directive follows.
Prefer \`/compact focus on: <current task>\` at the next natural break, after
preserving decisions and the next step. Continue the user's task; this advisory
does not require stopping work. Context size is not a billing or quota estimate.
EOF
    elif (( stage >= 70 )); then
        cat <<EOF
CONTEXT-BUDGET (${PERCENT}% of ${WINDOW}): the latest input contains ~${TOKENS} tokens.
Plan to preserve task state and use \`/compact focus on: <task>\` at a natural break.
EOF
    else
        cat <<EOF
CONTEXT-BUDGET (${PERCENT}% of ${WINDOW}): context is growing (~${TOKENS} input tokens).
Keep large reads focused and retain the next concrete step for a later handoff.
EOF
    fi
    break
done

# --- decide -----------------------------------------------------------------
if (( PERCENT >= THRESHOLD )) && (( PARACHUTE_FIRED == 0 )); then
    mkdir -p "$MARKER_DIR" 2>/dev/null || { warn "cannot create marker dir"; exit 0; }
    : > "$MARKER" 2>/dev/null || warn "cannot write marker: $MARKER"
    cat <<EOF
CONTEXT-PARACHUTE (v${VERSION}): context is at ${PERCENT}% of the ${WINDOW}-token window (threshold ${THRESHOLD}%).
Invoke the context-parachute skill NOW to write the handoff artifacts (HANDOFF.md,
${OUTPUT_DIR}/continue.md, ${OUTPUT_DIR}/continue-claude.md, and the AGENTS.md block)
while context is still fresh — then continue with the user's request.
Stamp each generated artifact with a footer line: "generated by context-parachute v${VERSION}".
EOF
fi

exit 0
