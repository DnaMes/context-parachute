#!/bin/bash
# context-parachute — helpers shared by the hooks (sourced, never executed).

# Print the main-chain input tokens (input + cache creation + cache read) of the
# last usable assistant record in the transcript tail, or nothing.
# Tail-read only the last 500 lines; -R + fromjson? skips corrupt/truncated
# lines; .isSidechain==true (subagent) records are ignored.
parachute_last_tokens() {
    tail -n 500 "$1" 2>/dev/null \
        | jq -c -R 'fromjson? | objects | select(.type=="assistant" and (.isSidechain != true)) |
            .message.usage | objects |
            select(.input_tokens | type == "number") |
            select([.input_tokens, (.cache_creation_input_tokens // 0), (.cache_read_input_tokens // 0)] |
                all(.[]; type == "number" and . >= 0 and . == floor))' 2>/dev/null \
        | tail -n 1 \
        | jq -r '(.input_tokens + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' 2>/dev/null \
        || true
}

# Modification time (epoch seconds) of a file, 0 if missing. GNU stat, then BSD.
parachute_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# The configured output_dir (global config, then project config), default
# ".parachute". Invalid values are ignored, like the watcher's loader does.
parachute_output_dir() {
    local out=".parachute" cfg o
    for cfg in "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/parachute.json" "$(pwd)/.parachute/config.json"; do
        [[ -r "$cfg" ]] || continue
        o="$(jq -r 'if type == "object" and (.output_dir | type == "string" and length > 0
            and (explode | all(.[]; . >= 32 and . != 127))) then .output_dir else empty end' "$cfg" 2>/dev/null || true)"
        if [[ -n "$o" ]]; then
            out="$o"
        elif [[ "$(jq -r 'if type == "object" and has("output_dir") then "set" else empty end' "$cfg" 2>/dev/null || true)" == "set" ]]; then
            printf 'WARN: context-parachute: invalid output_dir in %s, ignoring\n' "$cfg" >&2
        fi
    done
    printf '%s' "$out"
}
