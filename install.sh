#!/bin/bash
# context-parachute — installer.
#
# Registers the two hooks in ~/.claude/settings.json (APPENDING blocks, never
# clobbering existing ones), symlinks the skill, and seeds the global config.
# Idempotent: re-running skips entries that already point at this clone.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${HOME}/.claude/settings.json"
SKILL_LINK="${HOME}/.claude/skills/context-parachute"
CONFIG_DEST="${HOME}/.claude/parachute.json"
WATCH_CMD="bash ${REPO_DIR}/hooks/parachute-watch.sh"
PRECOMPACT_CMD="bash ${REPO_DIR}/hooks/parachute-precompact.sh"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

# --- hard dependency check --------------------------------------------------
command -v jq >/dev/null 2>&1 || err "jq is required but not found. Install jq and re-run."

mkdir -p "${HOME}/.claude/skills"

# --- settings.json: create if missing, then back up -------------------------
if [[ ! -f "$SETTINGS" ]]; then
    info "No ${SETTINGS} — creating an empty one."
    printf '{}\n' > "$SETTINGS"
fi
jq empty "$SETTINGS" 2>/dev/null || err "existing ${SETTINGS} is not valid JSON; aborting."

BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
info "Backed up settings.json -> ${BACKUP}"

# --- append hook blocks idempotently ----------------------------------------
# Adds a {matcher,hooks:[{type,command,timeout?}]} block to an event array only
# if no existing entry already registers the same command string.
append_hook() {
    local event="$1" cmd="$2" timeout="$3"
    local tmp
    tmp="$(mktemp)"
    jq \
        --arg event "$event" --arg cmd "$cmd" --argjson timeout "$timeout" '
        .hooks //= {} |
        .hooks[$event] //= [] |
        if (.hooks[$event] | any(.[].hooks[]?; .command == $cmd)) then .
        else .hooks[$event] += [{
            "matcher": "",
            "hooks": [ ({ "type": "command", "command": $cmd } + (if $timeout > 0 then {"timeout": $timeout} else {} end)) ]
        }] end
    ' "$SETTINGS" > "$tmp" || err "jq failed while registering ${event} hook"
    mv "$tmp" "$SETTINGS"
}

if jq -e --arg cmd "$WATCH_CMD" '.hooks.UserPromptSubmit // [] | any(.[].hooks[]?; .command == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    info "UserPromptSubmit watcher already registered — skipping."
else
    append_hook "UserPromptSubmit" "$WATCH_CMD" 5
    info "Registered UserPromptSubmit watcher (timeout 5s)."
fi

if jq -e --arg cmd "$PRECOMPACT_CMD" '.hooks.PreCompact // [] | any(.[].hooks[]?; .command == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    info "PreCompact fallback already registered — skipping."
else
    append_hook "PreCompact" "$PRECOMPACT_CMD" 0
    info "Registered PreCompact fallback."
fi

jq empty "$SETTINGS" 2>/dev/null || err "settings.json became invalid after edit — restore from ${BACKUP}"

# --- symlink skill ----------------------------------------------------------
if [[ -L "$SKILL_LINK" || -e "$SKILL_LINK" ]]; then
    info "Skill link/dir already exists at ${SKILL_LINK} — leaving as-is."
else
    ln -s "${REPO_DIR}/skill" "$SKILL_LINK"
    info "Linked skill -> ${SKILL_LINK}"
fi

# --- seed global config -----------------------------------------------------
if [[ -f "$CONFIG_DEST" ]]; then
    info "Config already exists at ${CONFIG_DEST} — leaving as-is."
else
    cp "${REPO_DIR}/config/parachute.default.json" "$CONFIG_DEST"
    info "Seeded config -> ${CONFIG_DEST}"
fi

info ""
info "context-parachute installed. Threshold + options: ${CONFIG_DEST}"
info "Uninstall with: ${REPO_DIR}/uninstall.sh"
