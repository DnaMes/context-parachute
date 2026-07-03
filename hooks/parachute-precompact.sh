#!/bin/bash
# context-parachute — PreCompact fallback hook.
#
# WHY: the UserPromptSubmit watcher only fires on user input. A single huge turn
# (70 -> 96% in one step) or a long autonomous run with no prompts can reach
# auto-compact without the watcher ever firing. This hook is the belt-and-
# suspenders fallback: on an AUTO compaction with no fired-marker, it injects an
# emergency brain-dump prompt AND writes a bash-only repo snapshot so at least
# raw state survives even if the model produces nothing.
#
# CONTRACT: stdin JSON. Fields used: .trigger ("auto"|"manual"), .session_id.
# PreCompact stdout on exit 0 is injected before compaction runs.
#
# Manual compaction (trigger=="manual") -> do nothing; the user is in control.
# FAIL-OPEN: internal errors -> exit 0. Diagnostics to stderr with WARN: prefix.
set -euo pipefail

warn() { printf 'WARN: context-parachute/precompact: %s\n' "$1" >&2; }

STDIN_JSON=""
if [[ ! -t 0 ]]; then
    STDIN_JSON="$(cat 2>/dev/null || true)"
fi

TRIGGER=""
SESSION_ID=""
if [[ -n "$STDIN_JSON" ]] && command -v jq >/dev/null 2>&1; then
    TRIGGER="$(printf '%s' "$STDIN_JSON" | jq -r '.trigger // empty' 2>/dev/null || true)"
    SESSION_ID="$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi

# Manual compaction: the user knows what they're doing. Stay silent.
[[ "$TRIGGER" == "manual" ]] && exit 0

# Watcher already handled this session -> skill has run, don't double up.
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"
MARKER="${TMPDIR:-/tmp}/context-parachute/${SESSION_ID}.fired"
[[ -e "$MARKER" ]] && exit 0

# --- bash-only snapshot (no model needed) -----------------------------------
# Load output_dir from config so the snapshot lands where the rest goes.
OUTPUT_DIR=".parachute"
for cfg in "${HOME}/.claude/parachute.json" "$(pwd)/.parachute/config.json"; do
    [[ -r "$cfg" ]] || continue
    if command -v jq >/dev/null 2>&1 && jq empty "$cfg" 2>/dev/null; then
        o="$(jq -r '.output_dir // empty' "$cfg" 2>/dev/null || true)"
        [[ -n "$o" ]] && OUTPUT_DIR="$o"
    fi
done

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
if mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
    EMERGENCY="${OUTPUT_DIR}/emergency.md"
    {
        printf '# context-parachute — emergency snapshot\n\n'
        printf '_Auto-written on auto-compaction at %s (the watcher never fired)._\n\n' "$TIMESTAMP"
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            printf '## git status\n\n```\n%s\n```\n\n' "$(git status 2>&1)"
            printf '## git diff --stat\n\n```\n%s\n```\n\n' "$(git diff --stat 2>&1)"
            printf '## git log --oneline -10\n\n```\n%s\n```\n' "$(git log --oneline -10 2>&1)"
        else
            printf '_Not a git repository — no VCS snapshot available._\n'
        fi
    } > "$EMERGENCY" 2>/dev/null || warn "could not write $EMERGENCY"
else
    warn "could not create output dir: $OUTPUT_DIR"
fi

# --- emergency brain-dump prompt (evolution of claude-hook-pre-compact.sh) ---
PROJECT="$(basename "$(pwd)" 2>/dev/null || echo project)"
cat <<EOF
=== CONTEXT-PARACHUTE EMERGENCY BRAIN DUMP — ${PROJECT} — ${TIMESTAMP} ===

Auto-compaction is about to run and the parachute watcher never fired. Before
compacting, output a structured summary covering all six sections:

1. CURRENT TASK: What exact task is being worked on right now?
2. DECISIONS MADE: What architectural/approach decisions were made and WHY?
3. FILES CHANGED: Which files were modified and what changed?
4. DISCOVERIES: What non-obvious things were learned (bugs, constraints, gotchas)?
5. BLOCKERS: What is unresolved or blocking progress?
6. NEXT STEPS: What is the exact next action after compaction resumes?

Then update HANDOFF.md in the project root with this same information so a fresh
session (any agent) can pick up the work. A raw snapshot was written to
${OUTPUT_DIR}/emergency.md.

=== END CONTEXT-PARACHUTE EMERGENCY PROMPT ===
EOF

exit 0
