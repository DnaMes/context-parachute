#!/bin/bash
# context-parachute — PreCompact fallback hook.
#
# WHY: the UserPromptSubmit watcher only fires on user input. A single huge turn
# (70 -> 96% in one step) or a long autonomous run with no prompts can reach
# auto-compact without the watcher ever firing. On every AUTO compaction this
# hook saves a mechanical repo snapshot. A watcher marker only proves that a
# directive was emitted, not that the model completed a handoff.
#
# CONTRACT: stdin JSON. Fields used: .trigger ("auto"|"manual"), .cwd,
# .session_id, .transcript_path.
# PreCompact does not guarantee a model turn; recovery must live on disk.
#
# Every compaction (auto or manual) re-arms the session's watcher markers and is
# logged with its token level; only AUTO compaction writes the snapshot.
# Manual compaction (trigger=="manual") -> the user is in control, no snapshot.
# FAIL-OPEN: internal errors -> exit 0. Diagnostics to stderr with WARN: prefix.
set -euo pipefail

warn() { printf 'WARN: context-parachute/precompact: %s\n' "$1" >&2; }

# Version from the VERSION file next to this script. Fail-open -> "unknown".
VERSION_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/VERSION"
VERSION="unknown"
[[ -r "$VERSION_FILE" ]] && VERSION="$(head -n1 "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$VERSION" ]] || VERSION="unknown"

# shellcheck source=parachute-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/parachute-lib.sh" 2>/dev/null || { warn "cannot load parachute-lib.sh"; exit 0; }

STDIN_JSON=""
if [[ ! -t 0 ]]; then
    STDIN_JSON="$(cat 2>/dev/null || true)"
fi

command -v jq >/dev/null 2>&1 || { warn "jq not found"; exit 0; }
TRIGGER="$(printf '%s' "$STDIN_JSON" | jq -r '.trigger // empty' 2>/dev/null || true)"
[[ "$TRIGGER" == "auto" || "$TRIGGER" == "manual" ]] || { warn "missing or invalid compaction trigger"; exit 0; }

SESSION_ID="$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
if [[ "$SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]]; then
    # After a compaction the context is small again: the watcher must warn anew
    # instead of staying silent for the rest of the session.
    rm -f -- "${TMPDIR:-/tmp}/context-parachute/${SESSION_ID}".fired "${TMPDIR:-/tmp}/context-parachute/${SESSION_ID}".warn* "${TMPDIR:-/tmp}/context-parachute/${SESSION_ID}".remind 2>/dev/null || true
    # `install.sh --doctor` compares these levels with the configured window.
    TRANSCRIPT="$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    LOG_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/context-parachute"
    if [[ -r "$TRANSCRIPT" ]] && mkdir -p -- "$LOG_DIR" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$SESSION_ID" "$TRIGGER" "$(parachute_last_tokens "$TRANSCRIPT")" \
            >> "${LOG_DIR}/compactions.log" 2>/dev/null || true
        # Keep the log bounded.
        if [[ "$(wc -l < "${LOG_DIR}/compactions.log" 2>/dev/null || echo 0)" -gt 500 ]]; then
            tail -n 200 "${LOG_DIR}/compactions.log" > "${LOG_DIR}/compactions.log.tmp" 2>/dev/null \
                && mv -f -- "${LOG_DIR}/compactions.log.tmp" "${LOG_DIR}/compactions.log" 2>/dev/null || true
        fi
    fi
fi
[[ "$TRIGGER" == "manual" ]] && exit 0

PROJECT_DIR="$(printf '%s' "$STDIN_JSON" | jq -r '.cwd | select(type == "string" and length > 0)' 2>/dev/null || true)"
if [[ -n "$PROJECT_DIR" ]]; then
    cd -- "$PROJECT_DIR" 2>/dev/null || { warn "cannot enter event cwd: $PROJECT_DIR"; exit 0; }
fi

# --- bash-only snapshot (no model needed) -----------------------------------
# Load output_dir from config so the snapshot lands where the rest goes.
OUTPUT_DIR="$(parachute_output_dir)"

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo unknown)"
mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || { warn "could not create output dir: $OUTPUT_DIR"; exit 0; }
EMERGENCY="${OUTPUT_DIR}/emergency.md"
# Keep the snapshot out of `git status` of the project it lands in (local-only
# exclude, never a tracked file); unattended runs left it as untracked noise.
if [[ "$OUTPUT_DIR" != /* ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && ! git check-ignore -q -- "$EMERGENCY" 2>/dev/null; then
    excl="$(git rev-parse --git-path info/exclude 2>/dev/null || true)"
    if [[ -n "$excl" ]] && mkdir -p -- "$(dirname "$excl")" 2>/dev/null; then
        printf '%s\n' "**/${OUTPUT_DIR#./}/emergency.md" >> "$excl" 2>/dev/null || true
    fi
fi
[[ -d "$EMERGENCY" ]] && { warn "snapshot destination is a directory: $EMERGENCY"; exit 0; }
# Publish only a complete snapshot, retaining the old one on a failed write.
SNAPSHOT_TMP="$(mktemp "${OUTPUT_DIR}/.emergency.XXXXXX" 2>/dev/null)" || { warn "could not create snapshot temporary file"; exit 0; }
trap 'rm -f -- "$SNAPSHOT_TMP"' EXIT
if {
    printf '# context-parachute — emergency snapshot\n\n'
    printf '_Auto-written before auto-compaction at %s. This is a mechanical snapshot, not a semantic handoff._\n\n' "$TIMESTAMP"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '## git status\n\n```\n%s\n```\n\n' "$(git --no-optional-locks status 2>&1)"
        printf '## git diff --stat\n\n```\n%s\n```\n\n' "$(git diff --stat 2>&1)"
        printf '## git log --oneline -10\n\n```\n%s\n```\n\n' "$(git log --oneline -10 2>&1)"
    else
        printf '_Not a git repository — no VCS snapshot available._\n\n'
    fi
    printf 'generated by context-parachute v%s\n' "$VERSION"
} > "$SNAPSHOT_TMP" 2>/dev/null; then
    mv -f -- "$SNAPSHOT_TMP" "$EMERGENCY" 2>/dev/null || warn "could not publish $EMERGENCY"
else
    warn "could not write $EMERGENCY"
fi

exit 0
