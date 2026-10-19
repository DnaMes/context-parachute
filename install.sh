#!/bin/bash
# context-parachute — installer.
#
# Registers the two hooks in ~/.claude/settings.json (APPENDING blocks, never
# clobbering existing ones), symlinks the skill, and seeds the global config.
# Idempotent: re-running skips entries that already point at this clone.
#
#   ./install.sh                  install
#   ./install.sh --with-posttool  also register the watcher as a PostToolUse hook
#                                 (covers long tool loops without prompts)
#   ./install.sh --doctor         read-only health check, changes nothing
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
SETTINGS="${CLAUDE_DIR}/settings.json"
SKILL_LINK="${CLAUDE_DIR}/skills/context-parachute"
CONFIG_DEST="${CLAUDE_DIR}/parachute.json"
LEGACY_WATCH_CMD="bash ${REPO_DIR}/hooks/parachute-watch.sh"
LEGACY_PRECOMPACT_CMD="bash ${REPO_DIR}/hooks/parachute-precompact.sh"

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

VERSION="unknown"
[[ -r "${REPO_DIR}/VERSION" ]] && VERSION="$(head -n1 "${REPO_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$VERSION" ]] || VERSION="unknown"

DOCTOR=0
WITH_POSTTOOL=0
for arg in "$@"; do
    case "$arg" in
        --doctor) DOCTOR=1 ;;
        --with-posttool) WITH_POSTTOOL=1 ;;
        *) err "unknown option: ${arg} (use --doctor or --with-posttool)" ;;
    esac
done

# --- hard dependency check --------------------------------------------------
command -v jq >/dev/null 2>&1 || err "jq is required but not found. Install jq and re-run."

# Read-only health check: is each hook registered AND does its script exist?
# Exits 1 only when a required hook is missing; warnings never fail the run.
doctor() {
    local rc=0 spec event script need n path cfg w t tokens pct
    info "context-parachute v${VERSION} — doctor (read-only)"
    if [[ ! -r "$SETTINGS" ]] || ! jq empty "$SETTINGS" 2>/dev/null; then
        info "FAIL  ${SETTINGS} missing or not valid JSON"
        return 1
    fi
    for spec in UserPromptSubmit:parachute-watch.sh:required PreCompact:parachute-precompact.sh:required \
                PostToolUse:parachute-watch.sh:optional; do
        IFS=: read -r event script need <<< "$spec"
        n="$(jq --arg e "$event" --arg s "$script" \
            '[.hooks[$e][]?.hooks[]?.command | strings | select(contains($s))] | length' "$SETTINGS")"
        if (( n == 0 )); then
            if [[ "$need" == required ]]; then
                info "FAIL  ${event}: ${script} is not registered (run ./install.sh)"; rc=1
            else
                info "info  ${event}: ${script} not registered (optional; ./install.sh --with-posttool)"
            fi
            continue
        fi
        path="$(jq -r --arg e "$event" --arg s "$script" '[.hooks[$e][]?.hooks[]?.command | strings
            | select(contains($s)) | capture("\u0027(?<p>[^\u0027]*" + ($s | gsub("\\."; "\\.")) + ")\u0027").p] | first // empty' "$SETTINGS")"
        # Unquoted legacy form: `bash /path/to/script`.
        [[ -n "$path" ]] || path="$(jq -r --arg e "$event" --arg s "$script" '[.hooks[$e][]?.hooks[]?.command | strings
            | select(contains($s)) | split(" ") | map(select(endswith($s)))[]] | first // empty' "$SETTINGS")"
        if [[ -r "$path" ]]; then
            info "ok    ${event}: ${script} registered (${path})"
        else
            info "FAIL  ${event}: registered script not readable (${path})"; rc=1
        fi
    done
    [[ -e "$SKILL_LINK" ]] && info "ok    skill present" || info "warn  skill link missing: ${SKILL_LINK}"

    w=200000
    local configured=0
    for cfg in "$CONFIG_DEST" "$PWD/.parachute/config.json"; do
        [[ -r "$cfg" ]] || continue
        if jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
            t="$(jq -r '.context_window // empty' "$cfg")"
            [[ "$t" =~ ^[1-9][0-9]*$ ]] && { w="$t"; configured=1; }
        else
            info "warn  invalid config: ${cfg}"
        fi
    done
    (( configured )) || { [[ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" =~ ^[1-9][0-9]*$ ]] && w="$CLAUDE_CODE_AUTO_COMPACT_WINDOW"; }
    info "info  effective context window: ${w}"

    # The last AUTO compaction shows where this machine really compacts.
    tokens="$(awk -F'\t' '$3 == "auto" && $4 ~ /^[0-9]+$/ {t = $4} END {print t}' \
        "${XDG_STATE_HOME:-${HOME}/.local/state}/context-parachute/compactions.log" 2>/dev/null || true)"
    if [[ "$tokens" =~ ^[0-9]+$ ]]; then
        pct=$(( tokens * 100 / w ))
        if (( pct < 60 )); then
            info "warn  last auto-compaction was at ${tokens} tokens = ${pct}% of the window: context_window is probably too large (set ~${tokens}/0.9 or CLAUDE_CODE_AUTO_COMPACT_WINDOW), the watcher would stay silent"
        else
            info "ok    last auto-compaction at ${tokens} tokens = ${pct}% of the window"
        fi
    fi
    return "$rc"
}

if (( DOCTOR )); then
    doctor
    exit $?
fi
info "context-parachute v${VERSION} — installer"
# Claude passes command strings through sh -c: quote paths for that boundary.
WATCH_CMD="bash $(printf '%s' "${REPO_DIR}/hooks/parachute-watch.sh" | jq -Rrs @sh)"
PRECOMPACT_CMD="bash $(printf '%s' "${REPO_DIR}/hooks/parachute-precompact.sh" | jq -Rrs @sh)"

# Fail before touching settings if another installation owns the skill path.
if [[ -L "$SKILL_LINK" ]]; then
    [[ "$(readlink "$SKILL_LINK")" == "${REPO_DIR}/skill" ]] || err "skill link points elsewhere: $SKILL_LINK"
elif [[ -e "$SKILL_LINK" ]]; then
    err "skill path already exists and is not this installation's symlink: $SKILL_LINK"
fi

mkdir -p "${CLAUDE_DIR}/skills"

# --- settings.json: create if missing, then back up -------------------------
if [[ ! -f "$SETTINGS" ]]; then
    info "No ${SETTINGS} — creating an empty one."
    printf '{}\n' > "$SETTINGS"
fi
jq empty "$SETTINGS" 2>/dev/null || err "existing ${SETTINGS} is not valid JSON; aborting."

BACKUP="$(mktemp "${SETTINGS}.bak.XXXXXXXX")"
cp "$SETTINGS" "$BACKUP"
info "Backed up settings.json -> ${BACKUP}"

# --- append hook blocks idempotently ----------------------------------------
# Adds a {matcher,hooks:[{type,command,timeout?}]} block to an event array only
# if no existing entry already registers the same command string.
append_hook() {
    local event="$1" cmd="$2" timeout="$3"
    local tmp
    tmp="$(mktemp "${SETTINGS}.tmp.XXXXXXXX")"
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

# Migrate the exact commands written by older releases before appending.
# Sibling handlers and block settings are preserved.
tmp="$(mktemp "${SETTINGS}.tmp.XXXXXXXX")"
jq --arg w "$WATCH_CMD" --arg p "$PRECOMPACT_CMD" \
    --arg lw "$LEGACY_WATCH_CMD" --arg lp "$LEGACY_PRECOMPACT_CMD" '
    if .hooks then
        .hooks |= with_entries(.value |= map(
            if .hooks then .hooks |= map(
                if .command == $lw or .command == $w then .command = $w | .timeout = 5
                elif .command == $lp or .command == $p then .command = $p | .timeout = 5
                else . end
            ) else . end
        ))
    else . end
' "$SETTINGS" > "$tmp" || err "jq failed while migrating hook commands"
mv "$tmp" "$SETTINGS"
append_hook "UserPromptSubmit" "$WATCH_CMD" 5
append_hook "PreCompact" "$PRECOMPACT_CMD" 5
info "Registered watcher and snapshot hooks (timeout 5s, idempotent)."
if (( WITH_POSTTOOL )); then
    append_hook "PostToolUse" "$WATCH_CMD" 5
    info "Registered the watcher for PostToolUse as well (throttled to one check per 30s)."
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
