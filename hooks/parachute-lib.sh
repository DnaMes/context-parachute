#!/bin/bash
# context-parachute — helpers shared by the hooks (sourced, never executed).

# Print "<tokens> <window>" for the last usable usage record in the transcript
# tail (window is 0 when the transcript does not carry one), or nothing.
# Tail-read only the last 500 lines; -R + fromjson? skips corrupt/truncated
# lines. Three transcript formats, told apart by record shape:
#   Claude Code  assistant record .message.usage (input + cache creation + cache
#                read); .isSidechain==true (subagent) records are ignored.
#   Codex        event_msg/token_count .payload.info.last_token_usage.total_tokens
#                (input already includes cached tokens) + .model_context_window.
#   Pi           assistant message .message.usage (input + cacheRead + cacheWrite).
#   Gemini CLI   {"type":"gemini"} message .tokens.input (the API prompt token count).
#   agy          PLANNER_RESPONSE .input_tokens + .cache_read_tokens.
#   adapter      {"parachute_usage":{"t":N,"w":N}} records the Cursor adapter writes
#                (Cursor transcripts carry no usage).
# A Codex "compacted" / Pi "compaction" / agy "CHECKPOINT" record makes every
# earlier usage stale.
parachute_last_usage() {
    tail -n 500 "$1" 2>/dev/null \
        | jq -c -R 'fromjson? | objects' 2>/dev/null \
        | jq -s -r '
            def nat: type == "number" and . >= 0 and . == floor;
            def claude: select(.type == "assistant" and (.isSidechain != true)) | .message | objects | .usage | objects
                | select(.input_tokens | type == "number")
                | select([.input_tokens, (.cache_creation_input_tokens // 0), (.cache_read_input_tokens // 0)] | all(.[]; nat))
                | {t: (.input_tokens + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)), w: 0};
            def codex: select(.type == "event_msg") | .payload | objects | select(.type == "token_count") | .info | objects
                | select(.last_token_usage | objects | .total_tokens | nat)
                | {t: .last_token_usage.total_tokens, w: (if (.model_context_window | nat) then .model_context_window else 0 end)};
            def pi: select(.type == "message") | .message | objects | select(.role == "assistant") | .usage | objects
                | select(.totalTokens | nat) | select([.input, (.cacheRead // 0), (.cacheWrite // 0)] | all(.[]; nat))
                | {t: (.input + (.cacheRead // 0) + (.cacheWrite // 0)), w: 0};
            def gemini: select(.type == "gemini") | .tokens | objects | select(.input | nat) | {t: .input, w: 0};
            def agy: select(.type == "PLANNER_RESPONSE") | select([.input_tokens, (.cache_read_tokens // 0)] | all(.[]; nat))
                | {t: (.input_tokens + (.cache_read_tokens // 0)), w: 0};
            def adapter: .parachute_usage | objects | select(.t | nat) | {t: .t, w: (if (.w | nat) then .w else 0 end)};
            (to_entries | map(select(.value.type == "compacted" or .value.type == "compaction" or .value.type == "CHECKPOINT") | .key) | last // -1) as $cut
            | [to_entries[] | select(.key > $cut) | .value | try (claude, codex, pi, gemini, agy, adapter) catch empty] | last
            | select(. != null) | "\(.t) \(.w)"' 2>/dev/null \
        || true
}

# Main-chain input tokens of the last usable usage record, or nothing.
parachute_last_tokens() {
    local u
    u="$(parachute_last_usage "$1")"
    [[ -n "$u" ]] && printf '%s\n' "${u%% *}"
    return 0
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
