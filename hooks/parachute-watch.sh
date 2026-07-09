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
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

# --- load config (defaults -> global -> per-project override) ---------------
THRESHOLD=80
WINDOW=200000
OUTPUT_DIR=".parachute"

load_config() {
    local file="$1"
    [[ -r "$file" ]] || return 0
    if ! jq empty "$file" 2>/dev/null; then
        warn "invalid config JSON, ignoring: $file"
        return 0
    fi
    local t w o
    t="$(jq -r '.threshold_percent // empty' "$file" 2>/dev/null || true)"
    w="$(jq -r '.context_window // empty'   "$file" 2>/dev/null || true)"
    o="$(jq -r '.output_dir // empty'       "$file" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] && THRESHOLD="$t"
    [[ "$w" =~ ^[0-9]+$ ]] && WINDOW="$w"
    [[ -n "$o" ]] && OUTPUT_DIR="$o"
}
load_config "${HOME}/.claude/parachute.json"
load_config "$(pwd)/.parachute/config.json"
[[ "$WINDOW" -gt 0 ]] || { warn "context_window <= 0, using 200000"; WINDOW=200000; }

# --- fired-marker: one shot per session -------------------------------------
MARKER_DIR="${TMPDIR:-/tmp}/context-parachute"
MARKER="${MARKER_DIR}/${SESSION_ID}.fired"
[[ -e "$MARKER" ]] && exit 0

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
    | jq -c -R 'fromjson? | select(.type=="assistant" and (.isSidechain != true)) | .message.usage' 2>/dev/null \
    | tail -n 1 || true)"
[[ -z "$USAGE_LINE" ]] && { warn "no assistant usage found in transcript tail"; exit 0; }

TOKENS="$(printf '%s' "$USAGE_LINE" | jq -r \
    '((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' \
    2>/dev/null || true)"
[[ "$TOKENS" =~ ^[0-9]+$ ]] || { warn "could not parse token usage"; exit 0; }

PERCENT=$(( TOKENS * 100 / WINDOW ))

# --- decide -----------------------------------------------------------------
if (( PERCENT >= THRESHOLD )); then
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
