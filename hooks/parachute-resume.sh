#!/bin/bash
# context-parachute — SessionStart(compact) resume hook (opt-in: install.sh --with-resume).
#
# WHY: after an auto-compaction nothing re-surfaces the handoff (PostCompact
# stdout does not reach the model). This injects ONE bounded card, only for
# source=compact: startup/resume/clear are left to whatever already injects
# HANDOFF.md there, so a handoff is never injected twice.
#
# USAGE: parachute-resume.sh [--tool NAME]  (NAME picks continue-NAME.md)
# CONTRACT: stdin JSON, fields used: .source, .cwd. SessionStart stdout on exit 0
# is injected as context. FAIL-OPEN: every internal error -> exit 0, no output.
set -euo pipefail

warn() { printf 'WARN: context-parachute/resume: %s\n' "$1" >&2; }

# shellcheck source=parachute-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/parachute-lib.sh" 2>/dev/null || { warn "cannot load parachute-lib.sh"; exit 0; }

TOOL="claude"
if [[ "${1:-}" == "--tool" && "${2:-}" =~ ^[a-z0-9-]+$ ]]; then TOOL="$2"; fi

STDIN_JSON=""
[[ -t 0 ]] || STDIN_JSON="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || { warn "jq not found"; exit 0; }
[[ "$(printf '%s' "$STDIN_JSON" | jq -r '.source // empty' 2>/dev/null || true)" == "compact" ]] || exit 0

PROJECT_DIR="$(printf '%s' "$STDIN_JSON" | jq -r '.cwd | select(type == "string" and length > 0)' 2>/dev/null || true)"
[[ -z "$PROJECT_DIR" ]] || cd -- "$PROJECT_DIR" 2>/dev/null || { warn "cannot enter event cwd: $PROJECT_DIR"; exit 0; }

MAX_BYTES="${PARACHUTE_RESUME_MAX_BYTES:-3000}"
MAX_AGE_DAYS="${PARACHUTE_RESUME_MAX_AGE_DAYS:-7}"
[[ "$MAX_BYTES" =~ ^[1-9][0-9]*$ && "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || { warn "invalid PARACHUTE_RESUME_* value"; exit 0; }

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
out_dir="$(parachute_output_dir)"
[[ "$out_dir" == /* ]] || out_dir="${root}/${out_dir}"

# Prefer the continuation prompt the skill wrote for this tool (the generic
# continue.md for tools without a dedicated one), then HANDOFF.md.
card=""
cands=("${out_dir}/continue-${TOOL}.md")
[[ "$TOOL" == "claude" ]] || cands+=("${out_dir}/continue.md")
for f in "${cands[@]}" "${root}/HANDOFF.md"; do
    [[ -r "$f" ]] && { card="$f"; break; }
done
[[ -n "$card" ]] || exit 0

age_days=$(( ( $(date +%s) - $(parachute_mtime "$card") ) / 86400 ))
stale=""
(( age_days <= MAX_AGE_DAYS )) || stale=" STALE (${age_days}d old): read it as a claim, verify against the live state."

printf 'CONTEXT-PARACHUTE resume card (context was just compacted; %s, %dd old).%s\n' "$(basename "$card")" "$age_days" "$stale"
printf -- '---\n'
head -c "$MAX_BYTES" "$card"
printf '\n---\n'
[[ ! -r "${out_dir}/emergency.md" ]] || printf 'Mechanical pre-compaction snapshot: %s\n' "${out_dir}/emergency.md"
exit 0
