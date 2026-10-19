#!/bin/bash
# context-parachute — host adapter for Gemini CLI, agy and Cursor.
#
# USAGE: parachute-host.sh <gemini|agy|cursor> <EventName>   (hook payload on stdin)
#
# WHY: these hosts speak different hook dialects (field names, output shape,
# events). This shim maps the payload to the Claude-style fields the core hooks
# read, runs them, and wraps their text in the host's output format. All logic
# (thresholds, markers, snapshot, resume card) stays in the core hooks.
#
#   Gemini CLI  BeforeAgent, AfterTool, PreCompress   -> JSON hookSpecificOutput
#   agy         PreInvocation                         -> {"injectSteps":[...]}
#   Cursor      beforeSubmitPrompt, postToolUse, afterAgentResponse, preCompact
#
# No host except Claude Code and Codex has a post-compaction event that can
# inject, so the compaction hook leaves a `<sid>.compacted` marker and the next
# prompt event injects the resume card.
# FAIL-OPEN: any error -> exit 0 with an empty (but valid) response.
set -euo pipefail

HOST="${1:-}"
EVENT="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${TMPDIR:-/tmp}/context-parachute"

warn() { printf 'WARN: context-parachute/host: %s\n' "$1" >&2; }

# Every host needs a parseable response even when there is nothing to say.
RESPONDED=0
empty_response() {
    case "$HOST:$EVENT" in
        gemini:*|agy:*) printf '{}\n' ;;
        cursor:beforeSubmitPrompt) printf '{"continue":true}\n' ;;
        *) ;;
    esac
}
finish() { (( RESPONDED )) || empty_response; }
trap finish EXIT

command -v jq >/dev/null 2>&1 || { warn "jq not found"; exit 0; }
case "$HOST" in gemini|agy|cursor) ;; *) warn "unknown host: $HOST"; exit 0 ;; esac

IN=""
[[ -t 0 ]] || IN="$(cat 2>/dev/null || true)"
[[ -n "$IN" ]] || { warn "empty stdin"; exit 0; }

# --- normalise the payload ---------------------------------------------------
case "$HOST" in
    gemini)
        SID="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)"
        TP="$(printf '%s' "$IN" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
        CWD="$(printf '%s' "$IN" | jq -r '.cwd // empty' 2>/dev/null || true)"
        DEFAULT_WINDOW="${PARACHUTE_GEMINI_WINDOW:-524288}" ;;  # auto-compress at 50 % of 1M
    agy)
        SID="$(printf '%s' "$IN" | jq -r '.conversationId // empty' 2>/dev/null || true)"
        TP="$(printf '%s' "$IN" | jq -r '.transcriptPath // empty' 2>/dev/null || true)"
        CWD="$(printf '%s' "$IN" | jq -r '.workspacePaths[0] // empty' 2>/dev/null || true)"
        DEFAULT_WINDOW="${PARACHUTE_AGY_WINDOW:-250000}" ;;     # checkpoints seen at ~233-276k
    cursor)
        SID="$(printf '%s' "$IN" | jq -r '.conversation_id // empty' 2>/dev/null || true)"
        CWD="$(printf '%s' "$IN" | jq -r '.workspace_roots[0] // empty' 2>/dev/null || true)"
        [[ -n "$CWD" ]] || CWD="${CURSOR_PROJECT_DIR:-}"
        # Cursor transcripts carry no token usage: usage lives in an adapter file.
        TP="${STATE}/cursor-${SID}.usage"
        DEFAULT_WINDOW="" ;;
esac
[[ "$SID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] || { warn "missing or invalid session id"; exit 0; }

MARKER="${STATE}/${SID}.compacted"
WINDOW_FILE="${STATE}/cursor-${SID}.window"
if [[ -z "${PARACHUTE_CONTEXT_WINDOW:-}" ]]; then
    if [[ -n "$DEFAULT_WINDOW" ]]; then
        PARACHUTE_CONTEXT_WINDOW="$DEFAULT_WINDOW"
    elif [[ -r "$WINDOW_FILE" ]]; then
        PARACHUTE_CONTEXT_WINDOW="$(head -n1 "$WINDOW_FILE" 2>/dev/null || true)"
    fi
fi
export PARACHUTE_HOST="$HOST" PARACHUTE_CONTEXT_WINDOW="${PARACHUTE_CONTEXT_WINDOW:-}"

core_payload() { # $1 = hook_event_name, $2 = trigger (optional)
    jq -nc --arg e "$1" --arg s "$SID" --arg t "$TP" --arg c "$CWD" --arg g "${2:-}" \
        '{hook_event_name:$e, session_id:$s, transcript_path:$t, cwd:$c} + (if $g == "" then {} else {trigger:$g} end)'
}

# Wrap text in the host's response format for the current event.
respond() {
    local text="$1"
    [[ -n "$text" ]] || return 0
    RESPONDED=1
    case "$HOST:$EVENT" in
        gemini:*) jq -nc --arg e "$EVENT" --arg t "$text" '{hookSpecificOutput:{hookEventName:$e, additionalContext:$t}}' ;;
        agy:*)    jq -nc --arg t "$text" '{injectSteps:[{ephemeralMessage:$t}]}' ;;
        cursor:beforeSubmitPrompt) jq -nc --arg t "${text:0:9000}" '{continue:true, additional_context:$t}' ;;
        cursor:*) jq -nc --arg t "${text:0:9000}" '{additional_context:$t}' ;;
    esac
}

# Skip a tool/invocation event if the last check was less than TICK seconds ago.
throttled() {
    local tick="${STATE}/${SID}.htick" last
    last="$(parachute_mtime "$tick")"
    (( $(date +%s) - last >= ${PARACHUTE_TICK_SECONDS:-30} )) && {
        mkdir -p "$STATE" 2>/dev/null && : > "$tick" 2>/dev/null || true
        return 1
    }
    return 0
}

# shellcheck source=parachute-lib.sh
source "${HERE}/parachute-lib.sh" 2>/dev/null || { warn "cannot load parachute-lib.sh"; exit 0; }

run_precompact() { core_payload PreCompact "$1" | bash "${HERE}/parachute-precompact.sh" || true; }

resume_text() {
    [[ -e "$MARKER" ]] || return 0
    rm -f -- "$MARKER" 2>/dev/null || true
    jq -nc --arg c "$CWD" --arg s "$SID" '{source:"compact", cwd:$c, session_id:$s}' \
        | bash "${HERE}/parachute-resume.sh" --tool "$HOST" || true
}

# agy has no compaction event: a new CHECKPOINT record in the transcript is the signal.
agy_checkpoint_rearm() {
    [[ -r "$TP" ]] || return 0
    local n prev store="${STATE}/${SID}.checkpoints"
    n="$(grep -c '"type":"CHECKPOINT"' "$TP" 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    prev="$(cat "$store" 2>/dev/null || true)"
    mkdir -p "$STATE" 2>/dev/null || return 0
    printf '%s\n' "$n" > "$store" 2>/dev/null || true
    if [[ "$prev" =~ ^[0-9]+$ ]] && (( n > prev )); then
        run_precompact auto
        : > "$MARKER" 2>/dev/null || true
    fi
}

prompt_event() {
    local text card watch
    [[ "$HOST" != agy ]] || agy_checkpoint_rearm
    card="$(resume_text)"
    # agy fires PreInvocation before every model call: throttle unless a card is pending.
    if [[ "$HOST" == agy && -z "$card" ]] && throttled; then return 0; fi
    watch="$(core_payload UserPromptSubmit | bash "${HERE}/parachute-watch.sh" || true)"
    text="$card"
    [[ -z "$watch" ]] || text="${text:+${text}$'\n\n'}${watch}"
    respond "$text"
}

tool_event() {
    throttled && return 0
    respond "$(core_payload UserPromptSubmit | bash "${HERE}/parachute-watch.sh" || true)"
}

case "$HOST:$EVENT" in
    gemini:BeforeAgent|agy:PreInvocation|cursor:beforeSubmitPrompt) prompt_event ;;
    gemini:AfterTool|cursor:postToolUse) tool_event ;;
    gemini:PreCompress)
        run_precompact "$(printf '%s' "$IN" | jq -r '.trigger // "auto"' 2>/dev/null || echo auto)"
        mkdir -p "$STATE" 2>/dev/null && : > "$MARKER" 2>/dev/null || true ;;
    cursor:afterAgentResponse)
        t="$(printf '%s' "$IN" | jq -r '[.input_tokens, (.cache_read_tokens // 0), (.cache_write_tokens // 0)]
            | if all(.[]; type == "number" and . >= 0) then add else empty end' 2>/dev/null || true)"
        if [[ "$t" =~ ^[0-9]+$ ]] && mkdir -p "$STATE" 2>/dev/null; then
            printf '{"parachute_usage":{"t":%s,"w":0}}\n' "$t" >> "$TP" 2>/dev/null || true
            if [[ "$(wc -l < "$TP" 2>/dev/null || echo 0)" -gt 200 ]]; then
                tail -n 50 "$TP" > "${TP}.tmp" 2>/dev/null && mv -f -- "${TP}.tmp" "$TP" 2>/dev/null || true
            fi
        fi ;;
    cursor:preCompact)
        w="$(printf '%s' "$IN" | jq -r '.context_window_size | select(type == "number" and . > 0 and . == floor)' 2>/dev/null || true)"
        mkdir -p "$STATE" 2>/dev/null || true
        [[ -z "$w" ]] || printf '%s\n' "$w" > "$WINDOW_FILE" 2>/dev/null || true
        run_precompact "$(printf '%s' "$IN" | jq -r '.trigger // "auto"' 2>/dev/null || echo auto)"
        # Usage before the compaction is stale; the next afterAgentResponse starts afresh.
        printf '{"type":"compacted"}\n' >> "$TP" 2>/dev/null || true
        : > "$MARKER" 2>/dev/null || true ;;
    *) ;;
esac
exit 0
