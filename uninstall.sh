#!/bin/bash
# context-parachute — uninstaller.
#
# Removes the two hook blocks (matched by their command paths), removes the skill
# symlink, and leaves the config file in place (so a reinstall keeps your settings).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
SETTINGS="${CLAUDE_DIR}/settings.json"
SKILL_LINK="${CLAUDE_DIR}/skills/context-parachute"
LEGACY_WATCH_CMD="bash ${REPO_DIR}/hooks/parachute-watch.sh"
LEGACY_PRECOMPACT_CMD="bash ${REPO_DIR}/hooks/parachute-precompact.sh"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

command -v jq >/dev/null 2>&1 || err "jq is required but not found."
# Claude passes command strings through sh -c: quote paths for that boundary.
WATCH_CMD="bash $(printf '%s' "${REPO_DIR}/hooks/parachute-watch.sh" | jq -Rrs @sh)"
PRECOMPACT_CMD="bash $(printf '%s' "${REPO_DIR}/hooks/parachute-precompact.sh" | jq -Rrs @sh)"

if [[ -f "$SETTINGS" ]]; then
    jq empty "$SETTINGS" 2>/dev/null || err "${SETTINGS} is not valid JSON; aborting."
    BACKUP="$(mktemp "${SETTINGS}.bak.XXXXXXXX")"
    cp "$SETTINGS" "$BACKUP"
    info "Backed up settings.json -> ${BACKUP}"

    tmp="$(mktemp "${SETTINGS}.tmp.XXXXXXXX")"
    # Remove only our commands; users may have added siblings to the same block.
    jq --arg w "$WATCH_CMD" --arg p "$PRECOMPACT_CMD" \
        --arg lw "$LEGACY_WATCH_CMD" --arg lp "$LEGACY_PRECOMPACT_CMD" '
        if .hooks then
          .hooks |= with_entries(
            .value |= map(
                if any(.hooks[]?; .command == $w or .command == $p or .command == $lw or .command == $lp) then
                    .hooks |= map(select(.command != $w and .command != $p and .command != $lw and .command != $lp)) |
                    select(.hooks | length > 0)
                else . end
            )
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

if [[ -L "$SKILL_LINK" && "$(readlink "$SKILL_LINK")" == "${REPO_DIR}/skill" ]]; then
    rm "$SKILL_LINK"
    info "Removed skill symlink ${SKILL_LINK}"
elif [[ -e "$SKILL_LINK" || -L "$SKILL_LINK" ]]; then
    info "WARNING: ${SKILL_LINK} is not this installation's symlink — leaving it alone." >&2
fi

info "Config at ${CLAUDE_DIR}/parachute.json was kept. Remove it manually if desired."
info "context-parachute uninstalled."
