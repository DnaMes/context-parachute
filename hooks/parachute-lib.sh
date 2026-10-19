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
