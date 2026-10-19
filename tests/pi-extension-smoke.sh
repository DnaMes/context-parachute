#!/usr/bin/env bash
# context-parachute — smoke test for the Pi extension (integrations/pi/context-parachute.ts).
#
# Proves that the watcher directive injected by before_agent_start reaches the
# model. Two `pi --print` runs share one persisted session: run 1 only records
# assistant usage, run 2 is the probe. That is two model calls in total.
# Self-skips with exit 0 when pi is not installed.
#
# MODEL: PARACHUTE_SMOKE_MODEL (default deepseek/deepseek-flash). Its window is
# 1M, so a 1% threshold needs ~10k input tokens: run 1 pads its prompt to clear it.
set -euo pipefail

if ! command -v pi >/dev/null 2>&1; then
  echo "SKIP: pi not found on PATH; Pi extension smoke test not run"
  exit 0
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${PARACHUTE_SMOKE_MODEL:-deepseek/deepseek-flash}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/config" "$TMP/tmp" "$TMP/project" "$TMP/sessions" "$TMP/ext"
printf '{"threshold_percent": 1}\n' > "$TMP/config/parachute.json"
# Load through a symlink, as an install does: the extension must resolve the repo through it.
ln -s "$REPO/integrations/pi/context-parachute.ts" "$TMP/ext/context-parachute.ts"

# PARACHUTE_TICK_SECONDS keeps the turn_end (PostToolUse) path silent, so the
# directive can only come from before_agent_start. Otherwise run 1 would consume
# the one-shot directive and the probe would prove nothing.
run_pi() {
  (
    cd "$TMP/project"
    CLAUDE_CONFIG_DIR="$TMP/config" TMPDIR="$TMP/tmp" PARACHUTE_TICK_SECONDS=4000000000 \
      pi --print --no-extensions -e "$TMP/ext/context-parachute.ts" \
      --model "$MODEL" --session-dir "$TMP/sessions" "$@"
  )
}

# ~100 KB of filler (about 20k tokens) so run 1's usage clears the 1% threshold on
# a 1M window. Stays under the Linux per-argument limit of 128 KiB.
FILLER="$(printf 'word %.0s' {1..20000})"
echo "run 1: record assistant usage in the persisted session"
run_pi "Reply with the single word OK. Ignore this filler: ${FILLER}" >/dev/null

# Pi delivers the injected message to the model as a user-role message that
# follows the prompt, so the probe must not say "earlier". It also must not
# contain the matched string "of the 1000000-token window": the echoed prompt would pass.
PROBE="Quote verbatim the first line of the note in this conversation that reports how full the context window is, or reply NONE."
REPLY="$(run_pi --continue "$PROBE")"
echo "run 2 reply: ${REPLY}"

SESSION_FILE="$(find "$TMP/sessions" -name '*.jsonl' | head -n 1)"
PERSISTED=0
if [[ -n "$SESSION_FILE" ]] && grep -q '"customType": *"context-parachute"' "$SESSION_FILE"; then
  PERSISTED=1
  echo "session: context-parachute custom message persisted"
else
  echo "session: no context-parachute custom message found"
fi

if (( PERSISTED )) && [[ "$REPLY" == *"-token window"* ]]; then
  echo "PASS: model reply quotes the directive (injection reached the model)"
else
  echo "FAIL: model reply does not quote the CONTEXT-PARACHUTE directive"
  exit 1
fi
