#!/bin/bash
# context-parachute — test runner (plain bash; bats not required).
#
# Covers: token-sum / threshold matrix / fail-open / precompact / installer
# idempotency, plus shellcheck on every shipped script.
set -uo pipefail
# Do not inherit a host-specific Claude profile into the isolated tests.
unset CLAUDE_CONFIG_DIR XDG_STATE_HOME CLAUDE_CODE_AUTO_COMPACT_WINDOW

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${REPO_DIR}/tests/fixtures"
WATCH="${REPO_DIR}/hooks/parachute-watch.sh"
PRECOMPACT="${REPO_DIR}/hooks/parachute-precompact.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# Isolated per-run TMPDIR so fired-markers never collide with the real machine.
RUN_TMP="$(mktemp -d)"
# Isolated per-run HOME (no ~/.claude/parachute.json) so an ambient global
# config on the machine running the suite (e.g. context_window: 1000000) can
# never change what a fixture's expected percentage/threshold works out to.
# Without this, run_watch reads the REAL ~/.claude/parachute.json via
# load_config, and every threshold/WARN assertion below silently depends on
# whatever this machine happens to have configured. Predicted in HANDOFF.md
# 2026-08-28, confirmed live 2026-08-29 (6 failures on a machine configured
# for 1M-context sessions).
RUN_HOME="$(mktemp -d)"
trap 'rm -rf "$RUN_TMP" "$RUN_HOME"' EXIT

# Run the watcher against a fixture with a given session id. Echoes stdout.
# Usage: run_watch <fixture> <session_id> [extra_json_fields]
run_watch() {
    local fixture="$1" sid="$2"
    local input
    input="$(jq -nc --arg t "${FIXTURES}/${fixture}" --arg s "$sid" '{transcript_path:$t, session_id:$s}')"
    TMPDIR="$RUN_TMP" HOME="$RUN_HOME" printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
section "Threshold matrix"

out="$(run_watch at-80.jsonl s-80)"
[[ "$out" == *"CONTEXT-PARACHUTE"* ]] && ok "80% fires directive" || bad "80% fires directive"
[[ -e "${RUN_TMP}/context-parachute/s-80.fired" ]] && ok "80% writes fired-marker" || bad "80% writes fired-marker"

# second call, same session -> silent (marker present)
out="$(run_watch at-80.jsonl s-80)"
[[ -z "$out" ]] && ok "second call is silent (marker)" || bad "second call is silent (marker)"

# 79% is below the 80% parachute threshold but inside the 70% advisory band,
# so a CONTEXT-BUDGET nudge is expected (added by the escalating-warnings
# feature) while the parachute directive itself must not fire.
out="$(run_watch at-79.jsonl s-79)"
[[ "$out" != *"CONTEXT-PARACHUTE"* ]] && ok "79% does not fire parachute directive" || bad "79% does not fire parachute directive"
[[ "$out" == *"CONTEXT-BUDGET"* ]] && ok "79% fires advisory warning" || bad "79% fires advisory warning (got: ${out:0:60})"
[[ -e "${RUN_TMP}/context-parachute/s-79.fired" ]] && bad "79% must NOT write parachute marker" || ok "79% writes no parachute marker"

# ---------------------------------------------------------------------------
section "Token-sum correctness"

# normal sums to 160000/200000 = 80% -> fires
out="$(run_watch normal.jsonl s-normal)"
[[ "$out" == *"at 80%"* ]] && ok "normal -> 80%" || bad "normal -> 80% (got: ${out:0:60})"

# cache-heavy sums to 158000 = 79% -> no parachute directive, but inside the
# 70% advisory band so a CONTEXT-BUDGET nudge is expected.
out="$(run_watch cache-heavy.jsonl s-cache)"
[[ "$out" != *"CONTEXT-PARACHUTE"* ]] && ok "cache-heavy -> 79% no parachute directive" || bad "cache-heavy -> 79% no parachute directive (got: ${out:0:60})"
[[ "$out" == *"CONTEXT-BUDGET"* ]] && ok "cache-heavy -> 79% fires advisory" || bad "cache-heavy -> 79% fires advisory (got: ${out:0:60})"

# sidechain line must be ignored: real usage = 20000 = 10% -> silent
out="$(run_watch sidechain-mixed.jsonl s-side)"
[[ -z "$out" ]] && ok "sidechain line ignored -> silent" || bad "sidechain line ignored (got: ${out:0:60})"

# corrupt: garbage lines skipped, valid line = 170000 = 85% -> fires
out="$(run_watch corrupt.jsonl s-corrupt)"
[[ "$out" == *"at 85%"* ]] && ok "corrupt lines skipped, valid line used" || bad "corrupt lines skipped (got: ${out:0:60})"

# Streaming/partial assistant records must not erase the last usable usage.
usage_fixture="${RUN_TMP}/partial-usage.jsonl"
cp "${FIXTURES}/at-80.jsonl" "$usage_fixture"
printf '%s\n' '{"type":"assistant","message":{"content":[]}}' \
    '{"type":"assistant","message":{"usage":{"input_tokens":"pending"}}}' > "${RUN_TMP}/partial-lines"
cat "${RUN_TMP}/partial-lines" >> "$usage_fixture"
input="$(jq -nc --arg t "$usage_fixture" '{transcript_path:$t, session_id:"s-partial-usage"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ "$out" == *"at 80%"* && $rc -eq 0 ]] && ok "partial usage preserves last valid measurement" || bad "partial usage preserves last valid measurement"

cp "${FIXTURES}/at-50.jsonl" "$usage_fixture"
printf '%s\n' '{"type":"assistant","message":[]}' \
    '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":"pending"}}}' >> "$usage_fixture"
cat "${FIXTURES}/at-80.jsonl" >> "$usage_fixture"
input="$(jq -nc --arg t "$usage_fixture" '{transcript_path:$t,session_id:"s-malformed-between"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"at 80%"* ]] && ok "malformed usage does not abort later measurements" || bad "malformed usage does not abort later measurements"

# portability: the shipped watcher must not depend on tac (GNU-only) or tail -r (BSD-only)
grep -qE '\btac\b|tail -r' "$WATCH" && bad "watcher uses non-portable reverse-read (tac/tail -r)" || ok "watcher reverse-read is portable"

# ---------------------------------------------------------------------------
section "1M context_window override (B2)"

# at-80.jsonl = 160000 tokens: 80% of the 200000 default (fires), but only 16%
# of a 1M window (must stay silent). Per-project .parachute/config.json override.
override_dir="$(mktemp -d)"
mkdir -p "${override_dir}/.parachute"
cat > "${override_dir}/.parachute/config.json" <<'EOF'
{"context_window": 1000000}
EOF
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-1m-override"}')"
out="$(cd "$override_dir" && TMPDIR="$RUN_TMP" HOME="$RUN_HOME" printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ -z "$out" ]] && ok "1M override: 160k/1M stays silent" || bad "1M override: 160k/1M stays silent (got: ${out:0:60})"
rm -rf "$override_dir"

# default window (200000, no override) + observed tokens already exceed it -> WARN to
# stderr, trigger decision unchanged (still fires, since 250000/200000 = 125% >= 80%).
warn_fixture="${RUN_TMP}/warn-exceeds.jsonl"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","usage":{"input_tokens":250000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' > "$warn_fixture"
input="$(jq -nc --arg t "$warn_fixture" '{transcript_path:$t, session_id:"s-warn-exceeds"}')"
err="$(TMPDIR="$RUN_TMP" HOME="$RUN_HOME" printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>&1 >/dev/null)"
[[ "$err" == *"WARN"*"exceed"* ]] && ok "default window + tokens exceed it -> WARN on stderr" || bad "default window + tokens exceed it -> WARN on stderr (got: ${err:0:80})"

# ---------------------------------------------------------------------------
section "Escalating advisory stages (50/70/85%)"

# 50%: mildest advisory, no compact/STOP wording, no parachute directive.
out="$(run_watch at-50.jsonl s-stage50)"
[[ "$out" == *"CONTEXT-BUDGET"* ]] && ok "50% fires mildest advisory" || bad "50% fires mildest advisory (got: ${out:0:60})"
[[ "$out" != *"STOP AND COMPACT"* ]] && ok "50% does not use STOP wording" || bad "50% does not use STOP wording"
[[ "$out" != *"CONTEXT-PARACHUTE"* ]] && ok "50% does not fire parachute directive" || bad "50% does not fire parachute directive"

# same session again -> the 50% stage marker suppresses a repeat at the same stage.
out="$(run_watch at-50.jsonl s-stage50)"
[[ -z "$out" ]] && ok "50% stage is silent on repeat (per-stage marker)" || bad "50% stage is silent on repeat (got: ${out:0:60})"

# 70%: mid-tier advisory, mentions compact + delegate, still below parachute threshold.
out="$(run_watch at-70.jsonl s-stage70)"
[[ "$out" == *"CONTEXT-BUDGET"* && "$out" == *"compact"* ]] && ok "70% fires mid-tier advisory" || bad "70% fires mid-tier advisory (got: ${out:0:80})"
[[ "$out" != *"STOP AND COMPACT"* ]] && ok "70% does not use STOP wording" || bad "70% does not use STOP wording"

# High-context advice must preserve the handoff before suggesting compaction.
out="$(run_watch at-90.jsonl s-stage90)"
[[ "$out" == *"context is high"* && "$out" == *"Save the handoff before compacting"* ]] && ok "90% prioritizes handoff before compaction" || bad "90% prioritizes handoff before compaction"
[[ "$out" == *"/compact focus on:"* && "$out" == *"Continue the user's task"* ]] && ok "90% advisory preserves task continuity" || bad "90% advisory preserves task continuity"
[[ "$out" != *"STOP AND COMPACT"* && "$out" != *"shared plan limit"* ]] && ok "90% emits no hard stop or quota claim" || bad "90% emits no hard stop or quota claim"

out="$(run_watch at-90.jsonl s-stage90-fresh)"
[[ "$out" == *"context is high"* && -e "${RUN_TMP}/context-parachute/s-stage90-fresh.warn85" ]] && ok "highest stage wins on first observation" || bad "highest stage wins on first observation"

# ---------------------------------------------------------------------------
section "Fail-open"

invalid_config_dir="${RUN_TMP}/invalid-config"
mkdir -p "${invalid_config_dir}/.parachute"
printf '%s\n' '{"context_window":"08","threshold_percent":101}' > "${invalid_config_dir}/.parachute/config.json"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" --arg cwd "$invalid_config_dir" '{transcript_path:$t,cwd:$cwd,session_id:"s-invalid-config"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>"${RUN_TMP}/invalid-config.err")"; rc=$?
[[ "$out" == *"at 80%"* && $rc -eq 0 && -s "${RUN_TMP}/invalid-config.err" ]] \
    && ok "invalid config values warn and preserve defaults" || bad "invalid config values warn and preserve defaults"

# Session identifiers must never become path traversal in marker filenames.
printf 'keep\n' > "${RUN_TMP}/outside.fired"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t,session_id:"../outside"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ "$rc" -eq 0 && -z "$out" && ! -e "${RUN_TMP}/outside.warn70" ]] \
    && ok "unsafe session id cannot escape marker directory" || bad "unsafe session id cannot escape marker directory"

# empty transcript file -> no usage -> silent, exit 0
out="$(run_watch empty.jsonl s-empty)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "empty transcript -> silent exit 0" || bad "empty transcript -> silent exit 0"

# missing transcript path
input="$(jq -nc '{transcript_path:"/nonexistent/x.jsonl", session_id:"s-miss"}')"
out="$(TMPDIR="$RUN_TMP" HOME="$RUN_HOME" printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "missing transcript -> silent exit 0" || bad "missing transcript -> silent exit 0"

# malformed stdin JSON
out="$(TMPDIR="$RUN_TMP" HOME="$RUN_HOME" printf '%s' 'not json {{{' | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "malformed stdin -> silent exit 0" || bad "malformed stdin -> silent exit 0"

# empty stdin
out="$(printf '' | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "empty stdin -> silent exit 0" || bad "empty stdin -> silent exit 0"

# no jq on PATH: symlink the core utils the hook needs (cat, tac, head, date,
# mkdir, basename) into a scratch dir but deliberately NOT jq, so the hook's
# `command -v jq` guard is what trips — not a missing coreutil or bash.
nojq_dir="$(mktemp -d)"
for u in cat tac head date mkdir basename pwd; do
    p="$(command -v "$u" 2>/dev/null)" && ln -s "$p" "${nojq_dir}/${u}" 2>/dev/null
done
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-nojq"}')"
out="$(printf '%s' "$input" | PATH="$nojq_dir" TMPDIR="$RUN_TMP" HOME="$RUN_HOME" /bin/bash "$WATCH" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "no jq -> silent exit 0" || bad "no jq -> silent exit 0 (rc=$rc out=${out:0:40})"
rm -rf "$nojq_dir"

# unset TMPDIR (marker dir falls back to /tmp) — must still fire without error
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-notmp-'$$'"}')"
out="$(env -u TMPDIR HOME="$RUN_HOME" printf '%s' "$input" | env -u TMPDIR HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ "$out" == *"CONTEXT-PARACHUTE"* && $rc -eq 0 ]] && ok "unset TMPDIR -> still fires" || bad "unset TMPDIR -> still fires (rc=$rc)"
rm -f "/tmp/context-parachute/s-notmp-$$.fired" 2>/dev/null

# ---------------------------------------------------------------------------
section "PreCompact fallback"

pc_scratch="$(mktemp -d)"
run_precompact() {
    local trigger="$1" sid="$2"
    local input
    input="$(jq -nc --arg tr "$trigger" --arg s "$sid" '{trigger:$tr, session_id:$s}')"
    ( cd "$pc_scratch" && TMPDIR="$RUN_TMP" HOME="$RUN_HOME" printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$PRECOMPACT" 2>/dev/null )
}

# manual -> silent
out="$(run_precompact manual s-pc-manual)"
[[ -z "$out" ]] && ok "precompact manual -> silent" || bad "precompact manual -> silent"

# The watcher marker acknowledges a directive, not a completed handoff.
mkdir -p "${RUN_TMP}/context-parachute"; : > "${RUN_TMP}/context-parachute/s-pc-marked.fired"
out="$(run_precompact auto s-pc-marked)"
[[ -z "$out" ]] && ok "precompact auto+marker -> silent" || bad "precompact auto+marker -> silent"
[[ -s "${pc_scratch}/.parachute/emergency.md" ]] && ok "precompact snapshots even after watcher fired" || bad "precompact snapshots even after watcher fired"

# auto + no marker -> emergency prompt to stdout AND emergency.md written
out="$(run_precompact auto s-pc-fire)"
[[ -z "$out" ]] && ok "precompact snapshot does not require model output" || bad "precompact snapshot does not require model output"
[[ -f "${pc_scratch}/.parachute/emergency.md" ]] && ok "precompact auto -> emergency.md written" || bad "precompact auto -> emergency.md written"

cp "${pc_scratch}/.parachute/emergency.md" "${RUN_TMP}/saved-emergency.md"
out="$(run_precompact unexpected s-pc-invalid)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && cmp -s "${pc_scratch}/.parachute/emergency.md" "${RUN_TMP}/saved-emergency.md" \
    && ok "unknown trigger leaves snapshot untouched" || bad "unknown trigger leaves snapshot untouched"

# Use the event's project directory, even if the shell starts elsewhere.
event_project="${RUN_TMP}/event-project"
mkdir -p "${event_project}/.parachute"
printf '%s\n' '{"context_window":1000000,"output_dir":"saved"}' > "${event_project}/.parachute/config.json"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" --arg cwd "$event_project" '{transcript_path:$t,cwd:$cwd,session_id:"s-event-cwd"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ -z "$out" ]] && ok "watcher uses event cwd for project config" || bad "watcher uses event cwd for project config"
input="$(jq -nc --arg cwd "$event_project" '{trigger:"auto",cwd:$cwd,session_id:"s-event-cwd"}')"
out="$(cd "$pc_scratch" && printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$PRECOMPACT" 2>/dev/null)"
[[ -s "${event_project}/saved/emergency.md" ]] && ok "precompact uses event cwd for snapshot" || bad "precompact uses event cwd for snapshot"

# A directory at the target must be treated as a failed publication, not as a
# destination into which mv silently places the snapshot under a random name.
rm "${event_project}/saved/emergency.md"
mkdir "${event_project}/saved/emergency.md"
printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$PRECOMPACT" 2>"${RUN_TMP}/publish.err"; rc=$?
leaked=("${event_project}/saved/emergency.md/".emergency.*)
[[ $rc -eq 0 && -s "${RUN_TMP}/publish.err" && ! -e "${leaked[0]}" ]] \
    && ok "snapshot destination directory fails open without false publication" || bad "snapshot destination directory fails open without false publication"
rm -rf "$pc_scratch"

# ---------------------------------------------------------------------------
section "Installer idempotency (append, never clobber)"

inst_scratch="$(mktemp -d)"
fake_settings="${inst_scratch}/settings.json"
cp "${FIXTURES}/settings-existing.json" "$fake_settings"
export HOME_ORIG="$HOME"
# Run install.sh against a fake HOME so it touches the scratch settings.
fake_home="$inst_scratch"
mkdir -p "${fake_home}/.claude/skills"
cp "${FIXTURES}/settings-existing.json" "${fake_home}/.claude/settings.json"

HOME="$fake_home" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1
S="${fake_home}/.claude/settings.json"

jq empty "$S" </dev/null 2>/dev/null && ok "settings.json valid after install" || bad "settings.json valid after install"

# pre-existing entries survive
jq -e '.hooks.UserPromptSubmit | any(.[].hooks[]?; .command == "node /home/user/existing-router.js")' "$S" </dev/null >/dev/null 2>&1 \
    && ok "existing UserPromptSubmit entry preserved" || bad "existing UserPromptSubmit entry preserved"
jq -e '.hooks.PreCompact | any(.[].hooks[]?; (.command | test("bd prime")))' "$S" </dev/null >/dev/null 2>&1 \
    && ok "existing PreCompact entry preserved" || bad "existing PreCompact entry preserved"

# our entries added
jq -e --arg c "bash '${REPO_DIR}/hooks/parachute-watch.sh'" '.hooks.UserPromptSubmit | any(.[].hooks[]?; .command == $c)' "$S" </dev/null >/dev/null 2>&1 \
    && ok "watcher entry added" || bad "watcher entry added"
jq -e --arg c "bash '${REPO_DIR}/hooks/parachute-precompact.sh'" '.hooks.PreCompact | any(.[].hooks[]?; .command == $c)' "$S" </dev/null >/dev/null 2>&1 \
    && ok "precompact entry added" || bad "precompact entry added"

# second install -> no duplicate entries
HOME="$fake_home" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1
cnt="$(jq --arg c "bash '${REPO_DIR}/hooks/parachute-watch.sh'" '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == $c)] | length' "$S" </dev/null 2>/dev/null)"
[[ "$cnt" == "1" ]] && ok "re-install is idempotent (no dup watcher)" || bad "re-install idempotent (count=$cnt)"

# A user can group another command beside our hook in the same block.
tmp="${RUN_TMP}/mixed-settings.json"
jq --arg c "bash '${REPO_DIR}/hooks/parachute-watch.sh'" '
    .hooks.UserPromptSubmit |= map(if any(.hooks[]?; .command == $c)
    then .hooks += [{"type":"command","command":"echo preserve-sibling"}] else . end)
' "$S" > "$tmp"
cp "$tmp" "$S"

# uninstall removes our entries, keeps existing
HOME="$fake_home" bash "${REPO_DIR}/uninstall.sh" >/dev/null 2>&1
jq -e --arg c "bash '${REPO_DIR}/hooks/parachute-watch.sh'" '.hooks.UserPromptSubmit // [] | any(.[].hooks[]?; .command == $c) | not' "$S" </dev/null >/dev/null 2>&1 \
    && ok "uninstall removes watcher" || bad "uninstall removes watcher"
jq -e '.hooks.UserPromptSubmit | any(.[].hooks[]?; .command == "node /home/user/existing-router.js")' "$S" </dev/null >/dev/null 2>&1 \
    && ok "uninstall keeps existing entry" || bad "uninstall keeps existing entry"
jq -e '.hooks.UserPromptSubmit | any(.[].hooks[]?; .command == "echo preserve-sibling")' "$S" >/dev/null 2>&1 \
    && ok "uninstall keeps sibling in shared block" || bad "uninstall keeps sibling in shared block"

ln -s "${RUN_TMP}/another-skill" "${fake_home}/.claude/skills/context-parachute"
HOME="$fake_home" bash "${REPO_DIR}/uninstall.sh" >/dev/null 2>&1
[[ -L "${fake_home}/.claude/skills/context-parachute" ]] && ok "uninstall preserves foreign skill symlink" || bad "uninstall preserves foreign skill symlink"
rm -rf "$inst_scratch"

# Execute the actual registered command through the same POSIX shell boundary
# used by Claude, in a clone whose path needs quoting.
quoted_repo="${RUN_TMP}/clone with 'quotes'"
mkdir -p "$quoted_repo"
cp -R "${REPO_DIR}/hooks" "${REPO_DIR}/skill" "${REPO_DIR}/config" "$quoted_repo/"
cp "${REPO_DIR}/install.sh" "${REPO_DIR}/install-host.sh" "${REPO_DIR}/uninstall.sh" "${REPO_DIR}/VERSION" "$quoted_repo/"
quoted_home="${RUN_TMP}/quoted-home"
HOME="$quoted_home" bash "${quoted_repo}/install.sh" >/dev/null 2>&1
HOME="$quoted_home" bash "${quoted_repo}/install.sh" >/dev/null 2>&1
quoted_settings="${quoted_home}/.claude/settings.json"
cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$quoted_settings")"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t,session_id:"s-quoted"}')"
out="$(printf '%s' "$input" | HOME="$quoted_home" TMPDIR="$RUN_TMP" sh -c "$cmd" 2>/dev/null)"; rc=$?
[[ "$out" == *"CONTEXT-PARACHUTE"* && $rc -eq 0 ]] && ok "installed command handles spaces and apostrophes" || bad "installed command handles spaces and apostrophes"
HOME="$quoted_home" bash "${quoted_repo}/uninstall.sh" >/dev/null 2>&1
jq -e '[.hooks[]?.[]?.hooks[]?] | length == 0' "$quoted_settings" >/dev/null \
    && ok "quoted clone uninstalls its commands" || bad "quoted clone uninstalls its commands"
backups=("${quoted_settings}".bak.*)
[[ ${#backups[@]} -eq 3 ]] && ok "every settings operation retains its own backup" || bad "every settings operation retains its own backup"

# A custom Claude profile owns settings, the skill, and global config.
profile_home="${RUN_TMP}/profile-home"
profile_dir="${RUN_TMP}/custom-claude"
HOME="$profile_home" CLAUDE_CONFIG_DIR="$profile_dir" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1
[[ -s "${profile_dir}/settings.json" && -L "${profile_dir}/skills/context-parachute" && ! -e "${profile_home}/.claude/settings.json" ]] \
    && ok "installer honors CLAUDE_CONFIG_DIR" || bad "installer honors CLAUDE_CONFIG_DIR"
mkdir -p "$profile_dir"
printf '%s\n' '{"context_window":1000000}' > "${profile_dir}/parachute.json"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t,session_id:"s-profile"}')"
out="$(printf '%s' "$input" | HOME="$profile_home" CLAUDE_CONFIG_DIR="$profile_dir" TMPDIR="$RUN_TMP" bash "$WATCH" 2>/dev/null)" && rc=0 || rc=$?
# Assert the EXIT CODE, not just empty output. This test passed for years while
# the hook was crashing: the config below omits `output_dir`, which used to make
# load_config return 1 and kill the watcher under `set -e`. Empty stdout looked
# like "correctly below threshold" and was indistinguishable from "died on line
# one of the config load".
[[ -z "$out" && "$rc" -eq 0 ]] && ok "watcher reads custom profile config" \
    || bad "watcher reads custom profile config (exit ${rc}, out=${#out} bytes)"
section "Config without output_dir must not kill the hook (regression)"
# A global parachute.json that sets only threshold/window — the shape the README
# documents and the shape that shipped in the wild — left `o` empty, so the final
# `[[ -n "$o" ]]` in load_config was false. A bash function returns the status of
# its last command, so load_config returned 1, and under `set -e` that killed the
# watcher at the CALL SITE: exit 1, no stderr, no advisory, no parachute, on every
# single prompt. Claude Code surfaced only "Failed with non-blocking status code:
# No stderr output".
noout_home="${RUN_TMP}/noout-home"
noout_dir="${RUN_TMP}/noout-claude"
mkdir -p "$noout_dir"
for cfg_json in '{"threshold_percent":65}' \
                '{"threshold_percent":65,"context_window":1000000}' \
                '{"context_window":200000}'; do
    printf '%s\n' "$cfg_json" > "${noout_dir}/parachute.json"
    input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t,session_id:"s-noout"}')"
    err_file="${RUN_TMP}/noout.err"
    printf '%s' "$input" | HOME="$noout_home" CLAUDE_CONFIG_DIR="$noout_dir" \
        TMPDIR="${RUN_TMP}/noout-tmp-$RANDOM" bash "$WATCH" >/dev/null 2>"$err_file" && rc=0 || rc=$?
    [[ "$rc" -eq 0 ]] && ok "exit 0 with config ${cfg_json}" \
        || bad "exit 0 with config ${cfg_json} (got ${rc}, stderr: $(head -c 120 "$err_file"))"
done

# The threshold path must actually be REACHED, not merely survived: 80% of the
# default 200000 window is over a 65% threshold, so the directive must appear.
printf '%s\n' '{"threshold_percent":65}' > "${noout_dir}/parachute.json"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t,session_id:"s-noout-fire"}')"
out="$(printf '%s' "$input" | HOME="$noout_home" CLAUDE_CONFIG_DIR="$noout_dir" \
    TMPDIR="${RUN_TMP}/noout-fire" bash "$WATCH" 2>/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && [[ "$out" == *"CONTEXT-PARACHUTE"* ]] \
    && ok "parachute still fires when output_dir is absent" \
    || bad "parachute still fires when output_dir is absent (exit ${rc})"

printf '%s\n' '{"output_dir":"profile-snapshots"}' > "${profile_dir}/parachute.json"
input="$(jq -nc --arg cwd "$event_project" '{trigger:"auto",cwd:$cwd}')"
rm "${event_project}/.parachute/config.json"
out="$(printf '%s' "$input" | HOME="$profile_home" CLAUDE_CONFIG_DIR="$profile_dir" TMPDIR="$RUN_TMP" bash "$PRECOMPACT" 2>/dev/null)"
[[ -s "${event_project}/profile-snapshots/emergency.md" ]] && ok "precompact reads custom profile config" || bad "precompact reads custom profile config"
HOME="$profile_home" CLAUDE_CONFIG_DIR="$profile_dir" bash "${REPO_DIR}/uninstall.sh" >/dev/null 2>&1
[[ -s "${profile_dir}/parachute.json" && ! -L "${profile_dir}/skills/context-parachute" ]] \
    && jq -e '[.hooks[]?.[]?.hooks[]?] | length == 0' "${profile_dir}/settings.json" >/dev/null 2>&1 \
    && ok "custom profile uninstall preserves config" || bad "custom profile uninstall preserves config"

# Upgrade an older registration in place, including a bounded timeout.
legacy_home="${RUN_TMP}/legacy-home"
mkdir -p "${legacy_home}/.claude"
jq -nc --arg w "bash ${REPO_DIR}/hooks/parachute-watch.sh" --arg p "bash ${REPO_DIR}/hooks/parachute-precompact.sh" \
    '{hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:$w}]}],PreCompact:[{hooks:[{type:"command",command:$p}]}]}}' > "${legacy_home}/.claude/settings.json"
HOME="$legacy_home" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1
jq -e '.hooks.UserPromptSubmit | length == 1 and (.[0].hooks | length == 1)' "${legacy_home}/.claude/settings.json" >/dev/null \
    && ok "legacy registrations migrate without duplicates" || bad "legacy registrations migrate without duplicates"
jq -e '.hooks.PreCompact[0].hooks[0].timeout == 5' "${legacy_home}/.claude/settings.json" >/dev/null \
    && ok "legacy precompact gains bounded timeout" || bad "legacy precompact gains bounded timeout"

foreign_home="${RUN_TMP}/foreign-home"
mkdir -p "${foreign_home}/.claude/skills"
cp "${FIXTURES}/settings-existing.json" "${foreign_home}/.claude/settings.json"
ln -s "${RUN_TMP}/foreign-target" "${foreign_home}/.claude/skills/context-parachute"
HOME="$foreign_home" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && cmp -s "${foreign_home}/.claude/settings.json" "${FIXTURES}/settings-existing.json" \
    && ok "conflicting skill aborts before settings mutation" || bad "conflicting skill aborts before settings mutation"

# ---------------------------------------------------------------------------
section "Compaction re-arm, log and snapshot hygiene (v1.2.0)"

rc_scratch="$(mktemp -d)"
git -C "$rc_scratch" init -q 2>/dev/null
mkdir -p "${RUN_TMP}/context-parachute"
rc_input() { jq -nc --arg tr "$1" --arg s "$2" --arg t "${FIXTURES}/at-80.jsonl" --arg cwd "$rc_scratch" \
    '{trigger:$tr, session_id:$s, transcript_path:$t, cwd:$cwd}'; }
rc_run() { rc_input "$1" "$2" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$PRECOMPACT" 2>/dev/null; }

: > "${RUN_TMP}/context-parachute/s-rearm.fired"; : > "${RUN_TMP}/context-parachute/s-rearm.warn70"
rc_run manual s-rearm
[[ ! -e "${RUN_TMP}/context-parachute/s-rearm.fired" && ! -e "${RUN_TMP}/context-parachute/s-rearm.warn70" ]] \
    && ok "manual compaction re-arms the session markers" || bad "manual compaction re-arms the session markers"
: > "${RUN_TMP}/context-parachute/s-rearm2.fired"
rc_run auto s-rearm2
[[ ! -e "${RUN_TMP}/context-parachute/s-rearm2.fired" ]] && ok "auto compaction re-arms the session markers" || bad "auto compaction re-arms the session markers"
out="$(run_watch at-80.jsonl s-rearm2)"
[[ "$out" == *"CONTEXT-PARACHUTE"* ]] && ok "watcher fires again after a compaction" || bad "watcher fires again after a compaction"

cl="${RUN_HOME}/.local/state/context-parachute/compactions.log"
grep -q "$(printf 's-rearm2\tauto\t160000')" "$cl" 2>/dev/null && ok "compaction log records trigger and token level" || bad "compaction log records trigger and token level"
[[ -z "$(git -C "$rc_scratch" status --porcelain)" ]] && ok "emergency snapshot stays out of git status" || bad "emergency snapshot stays out of git status"
rm -rf "$rc_scratch"

section "Effective window from CLAUDE_CODE_AUTO_COMPACT_WINDOW (v1.2.0)"

input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-envwin"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 bash "$WATCH" 2>/dev/null)"
[[ -z "$out" ]] && ok "env window 1M -> 16% is silent" || bad "env window 1M -> 16% is silent"
mkdir -p "${RUN_HOME}/.claude"; printf '%s\n' '{"context_window":200000}' > "${RUN_HOME}/.claude/parachute.json"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-envwin2"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"CONTEXT-PARACHUTE"* ]] && ok "explicit config window beats the env window" || bad "explicit config window beats the env window"
rm -f "${RUN_HOME}/.claude/parachute.json"
printf '%s\n' '{"autoCompactWindow":200000}' > "${RUN_HOME}/.claude/settings.json"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-envwin3"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"CONTEXT-PARACHUTE"* ]] && ok "settings.json autoCompactWindow sets the window" || bad "settings.json autoCompactWindow sets the window"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-envwin4"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"~160000 tokens, auto-compact window 200000"* && "$out" != *"% of the"* ]] && ok "compact window is reported as tokens, not a second percentage" || bad "compact window is reported as tokens, not a second percentage (got: ${out:0:80})"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-envwin5"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"auto-compact window 200000"* ]] && ok "env auto-compact window is reported as tokens" || bad "env auto-compact window is reported as tokens (got: ${out:0:80})"
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-envwin6"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" PARACHUTE_CONTEXT_WINDOW=200000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"80% of the 200000-token window"* ]] && ok "adapter window keeps the percentage even when equal to the compact window" || bad "adapter window keeps the percentage (got: ${out:0:80})"
rm -f "${RUN_HOME}/.claude/settings.json"

section "PostToolUse delivery (v1.2.0)"

pt_input() { jq -nc --arg t "${FIXTURES}/at-80.jsonl" --arg s "$1" '{hook_event_name:"PostToolUse", transcript_path:$t, session_id:$s}'; }
out="$(pt_input s-post | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" == "PostToolUse" \
    && "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)" == *"CONTEXT-PARACHUTE"* ]] \
    && ok "PostToolUse wraps the directive as additionalContext JSON" || bad "PostToolUse wraps the directive as additionalContext JSON (got: ${out:0:80})"
out="$(pt_input s-post | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ -z "$out" ]] && ok "PostToolUse is throttled within the tick window" || bad "PostToolUse is throttled within the tick window"
out="$(pt_input s-post | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" PARACHUTE_TICK_SECONDS=0 bash "$WATCH" 2>/dev/null)"
[[ -z "$out" ]] && ok "PostToolUse respects the fired marker once the throttle expires" || bad "PostToolUse respects the fired marker once the throttle expires"

section "Doctor (v1.2.0)"

doc_home="$(mktemp -d)"; mkdir -p "${doc_home}/.claude"; printf '{}\n' > "${doc_home}/.claude/settings.json"
out="$(HOME="$doc_home" bash "${REPO_DIR}/install.sh" --doctor 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"FAIL  UserPromptSubmit"* ]] && ok "doctor fails when the watcher is not registered" || bad "doctor fails when the watcher is not registered (rc=$rc)"
[[ "$(cat "${doc_home}/.claude/settings.json")" == "{}" ]] && ok "doctor does not create or change settings" || bad "doctor does not create or change settings"
HOME="$doc_home" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1
out="$(HOME="$doc_home" bash "${REPO_DIR}/install.sh" --doctor 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"ok    UserPromptSubmit"* && "$out" == *"ok    PreCompact"* ]] && ok "doctor passes after install" || bad "doctor passes after install (rc=$rc)"
mkdir -p "${doc_home}/.local/state/context-parachute"
printf '1\ts\tauto\t100000\n' > "${doc_home}/.local/state/context-parachute/compactions.log"
out="$(HOME="$doc_home" bash "${REPO_DIR}/install.sh" --doctor 2>&1)"
[[ "$out" == *"context_window is probably too large"* ]] && ok "doctor warns when compaction happened far below the window" || bad "doctor warns when compaction happened far below the window"
HOME="$doc_home" bash "${REPO_DIR}/install.sh" --with-posttool >/dev/null 2>&1
jq -e --arg c "bash '${REPO_DIR}/hooks/parachute-watch.sh'" '.hooks.PostToolUse | any(.[].hooks[]?; .command == $c)' "${doc_home}/.claude/settings.json" >/dev/null 2>&1 \
    && ok "--with-posttool registers the PostToolUse hook" || bad "--with-posttool registers the PostToolUse hook"
HOME="$doc_home" bash "${REPO_DIR}/install.sh" --bogus >/dev/null 2>&1 && bad "unknown installer option is rejected" || ok "unknown installer option is rejected"
rm -rf "$doc_home"

# Regressions found by the v1.2.0 review gate.
sp_home="$(mktemp -d)"; sp_repo="${sp_home}/dir with space/ctx"
mkdir -p "${sp_home}/.claude" "${sp_repo}/hooks"
cp "${REPO_DIR}/hooks/"*.sh "${sp_repo}/hooks/"; cp "${REPO_DIR}/VERSION" "${REPO_DIR}/install.sh" "$sp_repo/"; mkdir -p "${sp_repo}/skill"
HOME="$sp_home" bash "${sp_repo}/install.sh" >/dev/null 2>&1
out="$(HOME="$sp_home" bash "${sp_repo}/install.sh" --doctor 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"ok    UserPromptSubmit"* ]] && ok "doctor resolves an install path containing spaces" || bad "doctor resolves an install path containing spaces (rc=$rc)"
printf '%s\n' '{"context_window":200000}' > "${sp_home}/.claude/parachute.json"
out="$(HOME="$sp_home" CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 bash "${sp_repo}/install.sh" --doctor 2>&1)"
[[ "$out" == *"effective context window: 200000"* ]] && ok "doctor: explicit 200000 config beats the env window" || bad "doctor: explicit 200000 config beats the env window"
rm -rf "$sp_home"

sub_repo="$(mktemp -d)"; git -C "$sub_repo" init -q 2>/dev/null; mkdir -p "${sub_repo}/pkg/inner"
jq -nc --arg tr auto --arg s s-subdir --arg cwd "${sub_repo}/pkg/inner" '{trigger:$tr, session_id:$s, cwd:$cwd}' \
    | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$PRECOMPACT" 2>/dev/null
[[ -s "${sub_repo}/pkg/inner/.parachute/emergency.md" && -z "$(git -C "$sub_repo" status --porcelain)" ]] \
    && ok "snapshot below the repo root is excluded too" || bad "snapshot below the repo root is excluded too"
rm -rf "$sub_repo"

# ---------------------------------------------------------------------------
section "Window auto-grow, requested-vs-saved reminder, resume card (v1.3.0)"

# Unconfigured window + tokens above the 200k default -> measured against 1M.
grow_fixture="${RUN_TMP}/grow.jsonl"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":300000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' > "$grow_fixture"
input="$(jq -nc --arg t "$grow_fixture" '{transcript_path:$t, session_id:"s-grow"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
err="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>&1 >/dev/null)"
[[ "$err" == *"assuming a 1000000-token window"* ]] && ok "300k tokens, no config -> assumes a 1M window and says so" || bad "auto-grow notice (got: ${err:0:80})"
[[ "$out" != *"CONTEXT-PARACHUTE"* ]] && ok "auto-grow does not fire the parachute at 30%" || bad "auto-grow does not fire the parachute at 30%"
printf '%s\n' '{"context_window":200000}' > "${RUN_HOME}/.claude/parachute.json" 2>/dev/null || { mkdir -p "${RUN_HOME}/.claude"; printf '%s\n' '{"context_window":200000}' > "${RUN_HOME}/.claude/parachute.json"; }
input="$(jq -nc --arg t "$grow_fixture" '{transcript_path:$t, session_id:"s-grow2"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"CONTEXT-PARACHUTE"* ]] && ok "an explicit window is never auto-grown" || bad "an explicit window is never auto-grown"
rm -f "${RUN_HOME}/.claude/parachute.json"

# Requested vs saved: reminder once when HANDOFF.md stayed older than the marker.
rs_dir="$(mktemp -d)"
rs_run() { jq -nc --arg t "${FIXTURES}/at-80.jsonl" --arg s "$1" --arg cwd "$rs_dir" '{transcript_path:$t, session_id:$s, cwd:$cwd}' \
    | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" PARACHUTE_REMIND_AFTER="${2:-0}" bash "$WATCH" 2>/dev/null; }
out="$(rs_run s-remind)"; [[ "$out" == *"CONTEXT-PARACHUTE (v"* ]] && ok "reminder test: directive fires first" || bad "reminder test: directive fires first"
out="$(rs_run s-remind 3600)"; [[ -z "$out" ]] && ok "no reminder inside the grace period" || bad "no reminder inside the grace period"
out="$(rs_run s-remind)"
[[ "$out" == *"CONTEXT-PARACHUTE reminder"* ]] && ok "reminder when HANDOFF.md was not updated after the directive" || bad "reminder when HANDOFF.md was not updated after the directive (got: ${out:0:60})"
out="$(rs_run s-remind)"; [[ -z "$out" ]] && ok "the reminder is sent only once" || bad "the reminder is sent only once"
rs_run s-saved >/dev/null
printf '# handoff\n' > "${rs_dir}/HANDOFF.md"; touch -d '+1 minute' "${rs_dir}/HANDOFF.md"
out="$(rs_run s-saved)"; [[ -z "$out" ]] && ok "no reminder once HANDOFF.md was written" || bad "no reminder once HANDOFF.md was written (got: ${out:0:60})"
: > "${RUN_TMP}/context-parachute/s-remind.fired"; : > "${RUN_TMP}/context-parachute/s-remind.remind"
jq -nc --arg tr manual --arg s s-remind '{trigger:$tr, session_id:$s}' | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$PRECOMPACT" 2>/dev/null
[[ ! -e "${RUN_TMP}/context-parachute/s-remind.remind" ]] && ok "compaction re-arms the reminder too" || bad "compaction re-arms the reminder too"

# Resume card.
RESUME="${REPO_DIR}/hooks/parachute-resume.sh"
mkdir -p "${rs_dir}/.parachute"; printf 'CARD-HANDOFF %s\n' "$(head -c 5000 /dev/zero | tr '\0' 'x')" > "${rs_dir}/HANDOFF.md"
res() { jq -nc --arg src "$1" --arg cwd "$rs_dir" '{source:$src, cwd:$cwd, session_id:"s-res"}' | HOME="$RUN_HOME" bash "$RESUME" 2>/dev/null; }
out="$(res startup)"; [[ -z "$out" ]] && ok "resume hook ignores source=startup (no double injection)" || bad "resume hook ignores source=startup"
out="$(res compact)"
[[ "$out" == *"resume card"* && "$out" == *"CARD-HANDOFF"* ]] && ok "resume hook injects HANDOFF.md after compaction" || bad "resume hook injects HANDOFF.md after compaction"
(( ${#out} < 3400 )) && ok "resume card is bounded (<3.4 KB)" || bad "resume card is bounded (got ${#out} bytes)"
printf 'CARD-CONTINUE\n' > "${rs_dir}/.parachute/continue-claude.md"
out="$(res compact)"; [[ "$out" == *"CARD-CONTINUE"* && "$out" != *"CARD-HANDOFF"* ]] && ok "resume card prefers continue-claude.md" || bad "resume card prefers continue-claude.md"
printf 'snap\n' > "${rs_dir}/.parachute/emergency.md"
out="$(res compact)"; [[ "$out" == *"emergency.md"* ]] && ok "resume card points to the emergency snapshot" || bad "resume card points to the emergency snapshot"
touch -d '30 days ago' "${rs_dir}/.parachute/continue-claude.md"
out="$(res compact)"; [[ "$out" == *"STALE"* ]] && ok "stale resume card is labelled STALE" || bad "stale resume card is labelled STALE"
rm -rf "${rs_dir:?}/.parachute" "${rs_dir}/HANDOFF.md"
out="$(res compact)"; [[ -z "$out" ]] && ok "resume hook is silent without any handoff" || bad "resume hook is silent without any handoff"
rm -rf "$rs_dir"

# Installer: --with-resume uses the compact matcher; doctor reports it; uninstall removes it.
ri_home="$(mktemp -d)"; mkdir -p "${ri_home}/.claude"
HOME="$ri_home" bash "${REPO_DIR}/install.sh" --with-resume >/dev/null 2>&1
jq -e --arg c "bash '${REPO_DIR}/hooks/parachute-resume.sh'" '.hooks.SessionStart | any(.[]; .matcher == "compact" and any(.hooks[]?; .command == $c))' "${ri_home}/.claude/settings.json" >/dev/null 2>&1 \
    && ok "--with-resume registers SessionStart with matcher compact" || bad "--with-resume registers SessionStart with matcher compact"
out="$(HOME="$ri_home" bash "${REPO_DIR}/install.sh" --doctor 2>&1)"
[[ "$out" == *"ok    SessionStart: parachute-resume.sh"* ]] && ok "doctor sees the resume hook" || bad "doctor sees the resume hook"
big_repo="$(mktemp -d)"; git -C "$big_repo" init -q 2>/dev/null; head -c 50000 /dev/zero | tr '\0' 'x' > "${big_repo}/HANDOFF.md"
out="$(cd "$big_repo" && HOME="$ri_home" bash "${REPO_DIR}/install.sh" --doctor 2>&1)"
[[ "$out" == *"HANDOFF.md is "*"KB"* ]] && ok "doctor warns about an oversized HANDOFF.md" || bad "doctor warns about an oversized HANDOFF.md"
rm -rf "$big_repo"
HOME="$ri_home" bash "${REPO_DIR}/uninstall.sh" >/dev/null 2>&1
jq -e '(.hooks // {}) | has("SessionStart") | not' "${ri_home}/.claude/settings.json" >/dev/null 2>&1 \
    && ok "uninstall removes the resume hook" || bad "uninstall removes the resume hook"
rm -rf "$ri_home"

# Review-gate follow-ups (v1.3.1).
section "Invalid output_dir warns; test helper never exempts a crashed run (v1.3.1)"
oc_dir="$(mktemp -d)"; printf '%s\n' '{"output_dir":"bad\u0001dir"}' > "${oc_dir}/parachute.json"
oc_err="$(CLAUDE_CONFIG_DIR="$oc_dir" HOME="$RUN_HOME" bash -c 'source "$1"; parachute_output_dir' _ "${REPO_DIR}/hooks/parachute-lib.sh" 2>&1 >/dev/null)"
[[ "$oc_err" == *"invalid output_dir"* ]] && ok "invalid output_dir warns on stderr" || bad "invalid output_dir warns on stderr (got: ${oc_err:0:60})"
rm -rf "$oc_dir"
tg_repo="$(mktemp -d)"; git -C "$tg_repo" init -q; mkdir -p "${tg_repo}/tests" "${tg_repo}/hooks" "${tg_repo}/.githooks"
cp "${REPO_DIR}/.githooks/run-tests-on-commit" "${tg_repo}/.githooks/"
printf '#!/bin/bash\nprintf "  FAIL git tag (1.0.0) matches VERSION (1.0.1)\\n"\nexit 1\n' > "${tg_repo}/tests/run-tests.sh"
: > "${tg_repo}/hooks/x"; git -C "$tg_repo" add hooks/x tests/run-tests.sh
(cd "$tg_repo" && bash .githooks/run-tests-on-commit >/dev/null 2>&1) && bad "tag-only FAIL without Results line is blocked" || ok "tag-only FAIL without Results line is blocked"
printf '#!/bin/bash\nprintf "  FAIL git tag (1.0.0) matches VERSION (1.0.1)\\nResults: 1 passed, 1 failed\\n"\nexit 1\n' > "${tg_repo}/tests/run-tests.sh"
(cd "$tg_repo" && bash .githooks/run-tests-on-commit >/dev/null 2>&1) && ok "tag-only FAIL with a completed run is exempt" || bad "tag-only FAIL with a completed run is exempt"
rm -rf "$tg_repo"

# Installer accepts a skill link that resolves to this clone through another link (v1.3.2).
il_home="$(mktemp -d)"; mkdir -p "${il_home}/.claude/skills" "${il_home}/lib"
ln -s "${REPO_DIR}/skill" "${il_home}/lib/context-parachute"; ln -s "${il_home}/lib/context-parachute" "${il_home}/.claude/skills/context-parachute"
HOME="$il_home" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1 && ok "installer accepts an indirect skill link to this clone" || bad "installer accepts an indirect skill link to this clone"
rm "${il_home}/.claude/skills/context-parachute"; ln -s /tmp "${il_home}/.claude/skills/context-parachute"
HOME="$il_home" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1 && bad "installer rejects a skill link to elsewhere" || ok "installer rejects a skill link to elsewhere"
rm -rf "$il_home"

# ---------------------------------------------------------------------------
section "Other hosts: Codex rollout and Pi session transcripts (v1.4.0)"
usage() { bash -c 'source "$1"; parachute_last_usage "$2"' _ "${REPO_DIR}/hooks/parachute-lib.sh" "$1"; }
[[ "$(usage "${FIXTURES}/codex-380k.jsonl")" == "380900 475000" ]] && ok "Codex: total_tokens and model_context_window" || bad "Codex: total_tokens and model_context_window"
[[ -z "$(usage "${FIXTURES}/codex-compacted.jsonl")" ]] && ok "Codex: usage before a compacted record is stale" || bad "Codex: usage before a compacted record is stale"
[[ "$(usage "${FIXTURES}/codex-after-compact.jsonl")" == "30100 475000" ]] && ok "Codex: usage after a compacted record counts" || bad "Codex: usage after a compacted record counts"
[[ "$(usage "${FIXTURES}/pi-800k.jsonl")" == "800000 0" ]] && ok "Pi: input + cacheRead (output excluded), no window" || bad "Pi: input + cacheRead (got: $(usage "${FIXTURES}/pi-800k.jsonl"))"
[[ -z "$(usage "${FIXTURES}/pi-compacted.jsonl")" ]] && ok "Pi: usage before a compaction record is stale" || bad "Pi: usage before a compaction record is stale"
[[ "$(usage "${FIXTURES}/at-80.jsonl")" == "160000 0" ]] && ok "Claude Code transcript still parses" || bad "Claude Code transcript still parses"
out="$(run_watch codex-380k.jsonl s-codex)"
[[ "$out" == *"80% of the 475000-token window"* ]] && ok "watcher uses the Codex window from the transcript (80% of 475000)" || bad "watcher uses the Codex window from the transcript (got: ${out:0:80})"
input="$(jq -nc --arg t "${FIXTURES}/pi-800k.jsonl" '{transcript_path:$t, session_id:"s-pi"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" PARACHUTE_CONTEXT_WINDOW=1000000 bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"80% of the 1000000-token window"* ]] && ok "PARACHUTE_CONTEXT_WINDOW sets the window (Pi 800k of 1M)" || bad "PARACHUTE_CONTEXT_WINDOW sets the window (got: ${out:0:80})"
printf '%s\n' '{"context_window":2000000}' > "${RUN_HOME}/.claude/parachute.json" 2>/dev/null || { mkdir -p "${RUN_HOME}/.claude"; printf '%s\n' '{"context_window":2000000}' > "${RUN_HOME}/.claude/parachute.json"; }
input="$(jq -nc --arg t "${FIXTURES}/codex-380k.jsonl" '{transcript_path:$t, session_id:"s-cfgwin"}')"
out="$(printf '%s' "$input" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" PARACHUTE_CONTEXT_WINDOW=1000000 bash "$WATCH" 2>/dev/null)"
[[ -z "$out" ]] && ok "configured context_window beats host window and transcript window" || bad "configured context_window beats host window and transcript window"
rm -f "${RUN_HOME}/.claude/parachute.json"

[[ "$(usage "${FIXTURES}/gemini-524k.jsonl")" == "524000 0" ]] && ok "Gemini: last gemini message tokens.input" || bad "Gemini: last gemini message tokens.input"
[[ "$(usage "${FIXTURES}/agy-250k.jsonl")" == "250000 0" ]] && ok "agy: input_tokens + cache_read_tokens" || bad "agy: input_tokens + cache_read_tokens"
[[ -z "$(usage "${FIXTURES}/agy-checkpoint.jsonl")" ]] && ok "agy: usage before a CHECKPOINT record is stale" || bad "agy: usage before a CHECKPOINT record is stale"
[[ "$(usage "${FIXTURES}/adapter-usage.jsonl")" == "150000 0" ]] && ok "adapter state file: last parachute_usage record" || bad "adapter state file: last parachute_usage record"
out="$(printf '%s' "$(jq -nc --arg t "${FIXTURES}/codex-380k.jsonl" '{transcript_path:$t, session_id:"s-host"}')" | PARACHUTE_HOST=codex TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$WATCH" 2>/dev/null)"
[[ "$out" == *"Read and follow "*"/skill/SKILL.md NOW"* ]] && ok "non-Claude host: directive points at SKILL.md" || bad "non-Claude host: directive points at SKILL.md (got: ${out:0:120})"
out="$(run_watch at-90.jsonl s-claude-host)"
[[ "$out" == *"Invoke the context-parachute skill NOW"* ]] && ok "Claude host: directive invokes the skill" || bad "Claude host: directive invokes the skill"
tr_dir="$(mktemp -d)"; mkdir -p "${tr_dir}/.parachute"; printf 'GENERIC\n' > "${tr_dir}/.parachute/continue.md"; printf 'CLAUDE\n' > "${tr_dir}/.parachute/continue-claude.md"
tres() { jq -nc --arg cwd "$tr_dir" '{source:"compact", cwd:$cwd}' | HOME="$RUN_HOME" bash "${REPO_DIR}/hooks/parachute-resume.sh" "$@" 2>/dev/null; }
out="$(tres --tool codex)"; [[ "$out" == *"GENERIC"* && "$out" != *"CLAUDE"* ]] && ok "resume --tool codex falls back to continue.md" || bad "resume --tool codex falls back to continue.md"
out="$(tres)"; [[ "$out" == *"CLAUDE"* ]] && ok "resume default tool is claude" || bad "resume default tool is claude"
rm -rf "$tr_dir"

# ---------------------------------------------------------------------------
section "Host adapter: Gemini CLI, agy, Cursor (v1.4.0)"
HOST_SH="${REPO_DIR}/hooks/parachute-host.sh"
hs_dir="$(mktemp -d)"; mkdir -p "${hs_dir}/.parachute"; printf 'HOSTCARD\n' > "${hs_dir}/.parachute/continue.md"
hs() { # host event json
    printf '%s' "$3" | TMPDIR="$RUN_TMP" HOME="$RUN_HOME" bash "$HOST_SH" "$1" "$2" 2>/dev/null
}
gj() { jq -nc --arg t "${FIXTURES}/$1" --arg c "$hs_dir" --arg s "$2" '{session_id:$s, transcript_path:$t, cwd:$c, trigger:"auto"}'; }
out="$(hs gemini BeforeAgent "$(gj gemini-524k.jsonl hs-g1)")"
[[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>/dev/null)" == "BeforeAgent" && "$out" == *"CONTEXT-PARACHUTE"* ]] \
    && ok "gemini BeforeAgent: hookSpecificOutput.additionalContext with the directive" || bad "gemini BeforeAgent output (got: ${out:0:100})"
out="$(hs gemini BeforeAgent "$(gj at-50.jsonl hs-g2)")"; [[ "$out" == "{}" ]] && ok "gemini quiet turn answers {}" || bad "gemini quiet turn answers {} (got: ${out:0:60})"
out="$(hs gemini PreCompress "$(gj gemini-524k.jsonl hs-g1)")"
[[ "$out" == "{}" && -e "${RUN_TMP}/context-parachute/hs-g1.compacted" && -e "${hs_dir}/.parachute/emergency.md" ]] \
    && ok "gemini PreCompress: snapshot, compacted marker, valid JSON" || bad "gemini PreCompress (got: ${out:0:60})"
out="$(hs gemini BeforeAgent "$(gj at-50.jsonl hs-g1)")"
[[ "$out" == *"resume card"*"HOSTCARD"* && ! -e "${RUN_TMP}/context-parachute/hs-g1.compacted" ]] \
    && ok "next prompt injects the resume card once and clears the marker" || bad "resume card after PreCompress (got: ${out:0:100})"
aj() { jq -nc --arg t "${FIXTURES}/$1" --arg c "$hs_dir" --arg s "$2" '{conversationId:$s, transcriptPath:$t, workspacePaths:[$c]}'; }
out="$(hs agy PreInvocation "$(aj agy-250k.jsonl hs-a1)")"
[[ "$(jq -r '.injectSteps[0].ephemeralMessage' <<<"$out" 2>/dev/null)" == *"CONTEXT-PARACHUTE"* ]] && ok "agy PreInvocation: injectSteps ephemeralMessage" || bad "agy PreInvocation (got: ${out:0:100})"
out="$(hs agy PreInvocation "$(aj agy-250k.jsonl hs-a1)")"; [[ "$out" == "{}" ]] && ok "agy PreInvocation is throttled (30 s)" || bad "agy throttle (got: ${out:0:60})"
cj() { jq -nc --arg c "$hs_dir" --arg s "$1" --argjson n "${2:-0}" '{conversation_id:$s, workspace_roots:[$c], input_tokens:$n, cache_read_tokens:0, cache_write_tokens:0, trigger:"auto", context_tokens:$n, context_window_size:200000}'; }
hs cursor afterAgentResponse "$(cj hs-c1 190000)" >/dev/null
out="$(hs cursor beforeSubmitPrompt "$(cj hs-c1)")"
[[ "$(jq -r '.continue' <<<"$out" 2>/dev/null)" == "true" && "$(jq -r '.additional_context' <<<"$out" 2>/dev/null)" == *"CONTEXT-PARACHUTE"* ]] \
    && ok "cursor beforeSubmitPrompt: continue + additional_context from adapter usage" || bad "cursor beforeSubmitPrompt (got: ${out:0:100})"
out="$(hs cursor beforeSubmitPrompt "$(cj hs-c2)")"; [[ "$out" == '{"continue":true}' ]] && ok "cursor without usage answers continue:true" || bad "cursor without usage (got: ${out:0:60})"
hs cursor preCompact "$(cj hs-c1 190000)" >/dev/null
[[ "$(cat "${RUN_TMP}/context-parachute/cursor-hs-c1.window" 2>/dev/null)" == "200000" && -e "${RUN_TMP}/context-parachute/hs-c1.compacted" ]] \
    && ok "cursor preCompact stores the window and the compacted marker" || bad "cursor preCompact bookkeeping"
out="$(hs cursor beforeSubmitPrompt "$(cj hs-c1)")"; [[ "$(jq -r '.additional_context' <<<"$out" 2>/dev/null)" == *"resume card"* ]] && ok "cursor resume card after preCompact" || bad "cursor resume card (got: ${out:0:100})"
out="$(hs gemini BeforeAgent 'garbage')"; [[ "$out" == "{}" ]] && ok "host adapter fails open with valid JSON on garbage input" || bad "host adapter garbage input (got: ${out:0:60})"
rm -rf "$hs_dir"

# ---------------------------------------------------------------------------
section "install-host.sh: Codex, Gemini, Cursor, agy, Pi (v1.4.0)"
IH="${REPO_DIR}/install-host.sh"
ih_home="$(mktemp -d)"; mkdir -p "${ih_home}/.codex" "${ih_home}/.gemini/config" "${ih_home}/.cursor" "${ih_home}/.pi/agent"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"foreign.sh"}]}]}}' > "${ih_home}/.codex/hooks.json"
printf '%s\n' '{"theme":"x"}' > "${ih_home}/.gemini/settings.json"
printf '%s\n' '{"session-pipeline":{"enabled":true}}' > "${ih_home}/.gemini/config/hooks.json"
ih() { HOME="$ih_home" bash "$IH" "$@" 2>&1; }
ih codex gemini cursor agy >/dev/null; ih codex gemini cursor agy >/dev/null
out="$(ih --doctor codex gemini cursor agy)"
[[ "$out" == *"ok    codex: 4 hook"* && "$out" == *"ok    gemini: 3 hook"* && "$out" == *"ok    cursor: 4 hook"* && "$out" == *"ok    agy: 1 hook"* ]] \
    && ok "install-host registers every host, idempotently (doctor: exact counts)" || bad "install-host registers every host, idempotently"
jq -e '.hooks.SessionStart | any(.[]; .matcher == "compact" and any(.hooks[]; .command | contains("--tool codex"))) and any(.[]; any(.hooks[]?; .command == "foreign.sh"))' "${ih_home}/.codex/hooks.json" >/dev/null \
    && ok "codex: compact resume entry added, foreign hook kept" || bad "codex: compact resume entry added, foreign hook kept"
jq -e 'has("session-pipeline") and has("context-parachute") and (."context-parachute".PreInvocation | length == 1)' "${ih_home}/.gemini/config/hooks.json" >/dev/null \
    && ok "agy: named entry added next to the existing one" || bad "agy: named entry added next to the existing one"
jq -e '.theme == "x" and (.hooks.BeforeAgent | length == 1)' "${ih_home}/.gemini/settings.json" >/dev/null && ok "gemini: settings keys preserved" || bad "gemini: settings keys preserved"
ih --uninstall codex gemini cursor agy >/dev/null
[[ "$(jq -c . "${ih_home}/.codex/hooks.json")" == '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"foreign.sh"}]}]}}' \
    && "$(jq -c 'has("session-pipeline") and (has("context-parachute") | not)' "${ih_home}/.gemini/config/hooks.json")" == "true" ]] \
    && ok "uninstall removes only our entries" || bad "uninstall removes only our entries"
printf '%s\n' '{"context-parachute":{"PreInvocation":[{"type":"command","command":"bash /other/clone/hooks/parachute-host.sh agy PreInvocation"}]}}' > "${ih_home}/.gemini/config/hooks.json"
out="$(ih --uninstall agy)"
[[ "$out" == *"another clone"* ]] && jq -e 'has("context-parachute")' "${ih_home}/.gemini/config/hooks.json" >/dev/null \
    && ok "agy uninstall keeps an entry owned by another clone" || bad "agy uninstall keeps an entry owned by another clone"
ih --bogus >/dev/null && bad "install-host rejects unknown arguments" || ok "install-host rejects unknown arguments"
out="$(HOME="$(mktemp -d)" bash "$IH" codex 2>&1)"; [[ "$out" == *"skip  codex"* ]] && ok "absent host is skipped, not created" || bad "absent host is skipped, not created"
rm -rf "$ih_home"

# ---------------------------------------------------------------------------
section "Version consistency (VERSION == CHANGELOG == tag)"

VERSION_FILE="${REPO_DIR}/VERSION"
if [[ -r "$VERSION_FILE" ]]; then
    ver="$(head -n1 "$VERSION_FILE" | tr -d '[:space:]')"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "VERSION is semver ($ver)" || bad "VERSION is semver (got: $ver)"

    # top CHANGELOG release heading: first "## [x.y.z]" line, skipping [Unreleased]
    chlog="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "${REPO_DIR}/CHANGELOG.md" 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    [[ "$chlog" == "$ver" ]] && ok "CHANGELOG top matches VERSION" || bad "CHANGELOG top ($chlog) matches VERSION ($ver)"

    # Exported skills must carry their own release metadata: the destination
    # project may have no VERSION, or a VERSION belonging to a different product.
    skill_ver="$(sed -n 's/^  version: "\([^"]*\)"$/\1/p' "${REPO_DIR}/skill/SKILL.md")"
    [[ "$skill_ver" == "$ver" ]] && ok "bundled skill version matches VERSION" || bad "bundled skill version ($skill_ver) matches VERSION ($ver)"

    # latest git tag (if any tags exist yet) must match
    tag="$(cd "$REPO_DIR" && git tag -l 'v*' --sort=-v:refname 2>/dev/null | head -n1 | sed 's/^v//')"
    if [[ -n "$tag" ]]; then
        [[ "$tag" == "$ver" ]] && ok "latest git tag matches VERSION" || bad "git tag ($tag) matches VERSION ($ver)"
    else
        printf '  \033[33mSKIP\033[0m no git tag yet (tag before release)\n'
    fi
else
    bad "VERSION file present"
fi

# ---------------------------------------------------------------------------
section "shellcheck"

if command -v shellcheck >/dev/null 2>&1; then
    for s in "$WATCH" "$PRECOMPACT" "${REPO_DIR}/hooks/parachute-lib.sh" "${REPO_DIR}/hooks/parachute-resume.sh" "${REPO_DIR}/hooks/parachute-host.sh" "${REPO_DIR}/install.sh" "${REPO_DIR}/install-host.sh" "${REPO_DIR}/uninstall.sh" "${BASH_SOURCE[0]}"; do
        if shellcheck -S warning "$s" >/dev/null 2>&1; then
            ok "shellcheck $(basename "$s")"
        else
            bad "shellcheck $(basename "$s")"
        fi
    done
else
    printf '  \033[33mSKIP\033[0m shellcheck not installed\n'
fi

# ---------------------------------------------------------------------------
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
    exit 1
fi
exit 0
