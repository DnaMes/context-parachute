#!/bin/bash
# context-parachute — uninstaller.
#
# Removes the two hook blocks (matched by their command paths), removes the skill
# symlink, and leaves the config file in place (so a reinstall keeps your settings).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${HOME}/.claude/settings.json"
SKILL_LINK="${HOME}/.claude/skills/context-parachute"
WATCH_CMD="bash ${REPO_DIR}/hooks/parachute-watch.sh"
PRECOMPACT_CMD="bash ${REPO_DIR}/hooks/parachute-precompact.sh"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

command -v jq >/dev/null 2>&1 || err "jq is required but not found."

if [[ -f "$SETTINGS" ]]; then
    jq empty "$SETTINGS" 2>/dev/null || err "${SETTINGS} is not valid JSON; aborting."
    BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$BACKUP"
    info "Backed up settings.json -> ${BACKUP}"

    tmp="$(mktemp)"
    # Drop any hook block whose hooks[] contains one of our command strings, then
    # drop event arrays that became empty.
    jq --arg w "$WATCH_CMD" --arg p "$PRECOMPACT_CMD" '
        if .hooks then
          .hooks |= with_entries(
            .value |= map(select((.hooks // []) | any(.command == $w or .command == $p) | not))
          ) |
          .hooks |= with_entries(select(.value | length > 0))
        else . end
    ' "$SETTINGS" > "$tmp" || err "jq failed while removing hooks"
    mv "$tmp" "$SETTINGS"
    jq empty "$SETTINGS" 2>/dev/null || err "settings.json became invalid — restore from ${BACKUP}"
    info "Removed context-parachute hook entries."
else
    info "No settings.json found — nothing to unregister."
fi

if [[ -L "$SKILL_LINK" ]]; then
    rm "$SKILL_LINK"
    info "Removed skill symlink ${SKILL_LINK}"
elif [[ -e "$SKILL_LINK" ]]; then
    info "WARNING: ${SKILL_LINK} exists but is not a symlink — leaving it alone." >&2
fi

info "Config at ${HOME}/.claude/parachute.json was kept. Remove it manually if desired."
info "context-parachute uninstalled."
