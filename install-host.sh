#!/bin/bash
# context-parachute — install the watcher into hosts other than Claude Code.
#
# USAGE: ./install-host.sh [--uninstall|--doctor] <codex|pi|gemini|cursor|agy|all>...
#
#   codex   ~/.codex/hooks.json        core hooks directly (same payload as Claude Code)
#   pi      ~/.pi/agent/extensions/    symlink to integrations/pi/context-parachute.ts
#   gemini  ~/.gemini/settings.json    parachute-host.sh gemini <event>
#   cursor  ~/.cursor/hooks.json       parachute-host.sh cursor <event>
#   agy     ~/.gemini/config/hooks.json  named entry "context-parachute" (passive hook only)
#
# `all` means every host that is present on this machine. Foreign config files are
# edited by appending our entries only (idempotent) and backed up first. Codex
# additionally needs a one-time trust review: run `/hooks` in Codex.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="install"
HOSTS=()

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

for arg in "$@"; do
    case "$arg" in
        --uninstall) MODE="uninstall" ;;
        --doctor) MODE="doctor" ;;
        codex|pi|gemini|cursor|agy) HOSTS+=("$arg") ;;
        all) HOSTS+=(codex pi gemini cursor agy) ;;
        *) err "unknown argument: $arg (usage: $0 [--uninstall|--doctor] <codex|pi|gemini|cursor|agy|all>...)" ;;
    esac
done
(( ${#HOSTS[@]} )) || err "no host given (codex, pi, gemini, cursor, agy or all)"
command -v jq >/dev/null 2>&1 || err "jq is required but not found."

CODEX_FILE="${CODEX_HOME:-${HOME}/.codex}/hooks.json"
GEMINI_FILE="${HOME}/.gemini/settings.json"
CURSOR_FILE="${HOME}/.cursor/hooks.json"
AGY_FILE="${HOME}/.gemini/config/hooks.json"
PI_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}/extensions"
PI_LINK="${PI_DIR}/context-parachute.ts"
PI_SRC="${REPO_DIR}/integrations/pi/context-parachute.ts"

# Claude Code passes command strings through sh -c: quote paths for that boundary.
q() { printf '%s' "$1" | jq -Rrs @sh; }
WATCH_CMD="bash $(q "${REPO_DIR}/hooks/parachute-watch.sh")"
PRECOMPACT_CMD="bash $(q "${REPO_DIR}/hooks/parachute-precompact.sh")"
RESUME_CMD="bash $(q "${REPO_DIR}/hooks/parachute-resume.sh") --tool codex"
HOST_CMD="bash $(q "${REPO_DIR}/hooks/parachute-host.sh")"
MATCH="${REPO_DIR}/hooks/parachute-"

# Remove every entry whose command points into this clone (flat or grouped form).
STRIP='if (.hooks | type) == "object" then
  .hooks |= (with_entries(
      if (.value | type) == "array" then
        .value |= map(
          if (type == "object") and has("hooks") then (.hooks |= map(select((.command // "") | contains($m) | not))) | select(.hooks | length > 0)
          elif type == "object" then select((.command // "") | contains($m) | not)
          else . end)
      else . end)
    | with_entries(select((.value | type) != "array" or (.value | length) > 0)))
  else . end'

# apply_json FILE INIT ADD_FILTER [JQ_ARGS...]: strip our entries, then (install) add ours.
apply_json() {
    local file="$1" init="$2" add="$3"; shift 3
    local old new filter="$STRIP"
    if [[ ! -f "$file" ]]; then
        [[ "$MODE" == "install" ]] || return 0
        mkdir -p -- "$(dirname "$file")"
        printf '%s\n' "$init" > "$file"
    fi
    jq empty "$file" 2>/dev/null || err "${file} is not valid JSON; aborting."
    [[ "$MODE" == "install" ]] && filter="${STRIP} | ${add}"
    old="$(jq -S . "$file")"
    new="$(jq --arg m "$MATCH" "$@" "$filter" "$file")" || err "jq failed while editing ${file}"
    [[ "$(printf '%s' "$new" | jq -S .)" == "$old" ]] && { info "unchanged ${file}"; return 0; }
    cp -- "$file" "$(mktemp "${file}.bak.XXXXXXXX")"
    printf '%s\n' "$new" > "${file}.tmp.$$" && mv -f -- "${file}.tmp.$$" "$file"
    jq empty "$file" 2>/dev/null || err "${file} became invalid; restore from the .bak next to it"
    info "updated ${file}"
}

count_ours() { # FILE -> number of our commands registered
    [[ -f "$1" ]] || { printf '0'; return 0; }
    jq --arg m "$MATCH" '[.. | objects | select(has("command")) | .command | strings | select(contains($m))] | length' "$1" 2>/dev/null || printf '0'
}

doctor_json() { # LABEL FILE EXPECTED
    local n; n="$(count_ours "$2")"
    if (( n >= $3 )); then info "ok    $1: ${n} hook command(s) registered in $2"
    elif (( n > 0 )); then info "FAIL  $1: only ${n} of $3 hook commands registered in $2 (run ./install-host.sh $1)"
    else info "FAIL  $1: not registered in $2 (run ./install-host.sh $1)"; fi
}

present() { # HOST -> 0 if the host exists on this machine
    case "$1" in
        codex) [[ -d "$(dirname "$CODEX_FILE")" ]] ;;
        pi) [[ -d "$(dirname "$PI_DIR")" ]] ;;
        gemini) [[ -d "${HOME}/.gemini" ]] ;;
        cursor) [[ -d "${HOME}/.cursor" ]] ;;
        agy) [[ -d "${HOME}/.gemini/config" ]] ;;
    esac
}

do_host() {
    local h="$1"
    case "$h" in
        codex)
            case "$MODE" in
                doctor) doctor_json codex "$CODEX_FILE" 4
                    info "info  codex: hooks must be trusted once via /hooks (hash is stored in config.toml; not forgeable)" ;;
                *) apply_json "$CODEX_FILE" '{"hooks":{}}' '
                    .hooks = (.hooks // {})
                    | .hooks.UserPromptSubmit += [{hooks:[{type:"command", command:$w, timeout:5}]}]
                    | .hooks.PostToolUse += [{hooks:[{type:"command", command:$w, timeout:5}]}]
                    | .hooks.PreCompact += [{hooks:[{type:"command", command:$p, timeout:5}]}]
                    | .hooks.SessionStart += [{matcher:"compact", hooks:[{type:"command", command:$r, timeout:5}]}]' \
                    --arg w "PARACHUTE_HOST=codex ${WATCH_CMD}" --arg p "PARACHUTE_HOST=codex ${PRECOMPACT_CMD}" \
                    --arg r "PARACHUTE_HOST=codex ${RESUME_CMD}"
                    [[ "$MODE" != install ]] || info "NEXT  codex: open Codex and run /hooks to trust the 4 context-parachute hooks (one-time)" ;;
            esac ;;
        gemini)
            case "$MODE" in
                doctor) doctor_json gemini "$GEMINI_FILE" 3 ;;
                *) apply_json "$GEMINI_FILE" '{}' '
                    .hooks = (.hooks // {})
                    | .hooks.BeforeAgent += [{hooks:[{type:"command", name:"context-parachute", command:($c + " BeforeAgent"), timeout:5000}]}]
                    | .hooks.AfterTool += [{hooks:[{type:"command", name:"context-parachute", command:($c + " AfterTool"), timeout:5000}]}]
                    | .hooks.PreCompress += [{hooks:[{type:"command", name:"context-parachute", command:($c + " PreCompress"), timeout:5000}]}]' \
                    --arg c "${HOST_CMD} gemini" ;;
            esac ;;
        cursor)
            case "$MODE" in
                doctor) doctor_json cursor "$CURSOR_FILE" 4 ;;
                *) apply_json "$CURSOR_FILE" '{"version":1,"hooks":{}}' '
                    .version = (.version // 1) | .hooks = (.hooks // {})
                    | .hooks.beforeSubmitPrompt += [{command:($c + " beforeSubmitPrompt"), timeout:5}]
                    | .hooks.postToolUse += [{command:($c + " postToolUse"), timeout:5}]
                    | .hooks.afterAgentResponse += [{command:($c + " afterAgentResponse"), timeout:5}]
                    | .hooks.preCompact += [{command:($c + " preCompact"), timeout:5}]' \
                    --arg c "${HOST_CMD} cursor" ;;
            esac ;;
        agy)
            # agy keeps hooks as named top-level entries, not under a "hooks" key; leave the others alone.
            case "$MODE" in
                doctor) doctor_json agy "$AGY_FILE" 1 ;;
                *)
                    if [[ "$MODE" == install ]]; then
                        apply_json_agy_install
                    else
                        apply_json_agy_uninstall
                    fi ;;
            esac ;;
        pi)
            case "$MODE" in
                install)
                    [[ -f "$PI_SRC" ]] || err "missing ${PI_SRC}"
                    mkdir -p -- "$PI_DIR"
                    if [[ -L "$PI_LINK" && "$(readlink -f "$PI_LINK")" == "$(readlink -f "$PI_SRC")" ]]; then info "unchanged ${PI_LINK}"
                    elif [[ -e "$PI_LINK" || -L "$PI_LINK" ]]; then err "${PI_LINK} exists and is not this clone's extension; leaving it alone"
                    else ln -s "$PI_SRC" "$PI_LINK"; info "linked ${PI_LINK}"; fi ;;
                uninstall)
                    if [[ -L "$PI_LINK" && "$(readlink -f "$PI_LINK")" == "$(readlink -f "$PI_SRC")" ]]; then rm -- "$PI_LINK"; info "removed ${PI_LINK}"
                    else info "unchanged ${PI_LINK}"; fi ;;
                doctor)
                    if [[ -L "$PI_LINK" && "$(readlink -f "$PI_LINK")" == "$(readlink -f "$PI_SRC")" ]]; then info "ok    pi: extension linked at ${PI_LINK}"
                    else info "FAIL  pi: extension not linked (run ./install-host.sh pi)"; fi ;;
            esac ;;
    esac
}

apply_json_agy_install() {
    local file="$AGY_FILE" old new
    [[ -f "$file" ]] || { mkdir -p -- "$(dirname "$file")"; printf '{}\n' > "$file"; }
    jq empty "$file" 2>/dev/null || err "${file} is not valid JSON; aborting."
    old="$(jq -S . "$file")"
    new="$(jq --arg c "${HOST_CMD} agy PreInvocation" \
        '. + {"context-parachute": {enabled: true, PreInvocation: [{type: "command", command: $c, timeout: 5}]}}' "$file")" \
        || err "jq failed while editing ${file}"
    [[ "$(printf '%s' "$new" | jq -S .)" == "$old" ]] && { info "unchanged ${file}"; return 0; }
    cp -- "$file" "$(mktemp "${file}.bak.XXXXXXXX")"
    printf '%s\n' "$new" > "${file}.tmp.$$" && mv -f -- "${file}.tmp.$$" "$file"
    jq empty "$file" 2>/dev/null || err "${file} became invalid; restore from the .bak next to it"
    info "updated ${file}"
}

apply_json_agy_uninstall() {
    local file="$AGY_FILE" new
    [[ -f "$file" ]] || return 0
    jq empty "$file" 2>/dev/null || err "${file} is not valid JSON; aborting."
    jq -e 'has("context-parachute")' "$file" >/dev/null 2>&1 || { info "unchanged ${file}"; return 0; }
    new="$(jq 'del(."context-parachute")' "$file")"
    cp -- "$file" "$(mktemp "${file}.bak.XXXXXXXX")"
    printf '%s\n' "$new" > "${file}.tmp.$$" && mv -f -- "${file}.tmp.$$" "$file"
    info "updated ${file}"
}

[[ "$MODE" == doctor ]] && info "context-parachute $(head -n1 "${REPO_DIR}/VERSION" 2>/dev/null || echo unknown) — host doctor (read-only)"
for h in "${HOSTS[@]}"; do
    if ! present "$h"; then info "skip  ${h}: not found on this machine"; continue; fi
    do_host "$h"
done
