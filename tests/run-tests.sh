#!/bin/bash
# context-parachute — test runner (plain bash; bats not required).
#
# Covers: token-sum / threshold matrix / fail-open / precompact / installer
# idempotency, plus shellcheck on every shipped script.
set -uo pipefail
# Do not inherit a host-specific Claude profile into the isolated tests.
unset CLAUDE_CONFIG_DIR

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
cp "${REPO_DIR}/install.sh" "${REPO_DIR}/uninstall.sh" "${REPO_DIR}/VERSION" "$quoted_repo/"
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
out="$(printf '%s' "$input" | HOME="$profile_home" CLAUDE_CONFIG_DIR="$profile_dir" TMPDIR="$RUN_TMP" bash "$WATCH" 2>/dev/null)"
[[ -z "$out" ]] && ok "watcher reads custom profile config" || bad "watcher reads custom profile config"
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
    for s in "$WATCH" "$PRECOMPACT" "${REPO_DIR}/install.sh" "${REPO_DIR}/uninstall.sh" "${BASH_SOURCE[0]}"; do
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
