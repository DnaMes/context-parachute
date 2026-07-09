#!/bin/bash
# context-parachute — test runner (plain bash; bats not required).
#
# Covers: token-sum / threshold matrix / fail-open / precompact / installer
# idempotency, plus shellcheck on every shipped script.
set -uo pipefail

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
trap 'rm -rf "$RUN_TMP"' EXIT

# Run the watcher against a fixture with a given session id. Echoes stdout.
# Usage: run_watch <fixture> <session_id> [extra_json_fields]
run_watch() {
    local fixture="$1" sid="$2"
    local input
    input="$(jq -nc --arg t "${FIXTURES}/${fixture}" --arg s "$sid" '{transcript_path:$t, session_id:$s}')"
    TMPDIR="$RUN_TMP" printf '%s' "$input" | TMPDIR="$RUN_TMP" bash "$WATCH" 2>/dev/null
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

out="$(run_watch at-79.jsonl s-79)"
[[ -z "$out" ]] && ok "79% is silent" || bad "79% is silent"
[[ -e "${RUN_TMP}/context-parachute/s-79.fired" ]] && bad "79% must NOT write marker" || ok "79% writes no marker"

# ---------------------------------------------------------------------------
section "Token-sum correctness"

# normal sums to 160000/200000 = 80% -> fires
out="$(run_watch normal.jsonl s-normal)"
[[ "$out" == *"at 80%"* ]] && ok "normal -> 80%" || bad "normal -> 80% (got: ${out:0:60})"

# cache-heavy sums to 158000 = 79% -> silent
out="$(run_watch cache-heavy.jsonl s-cache)"
[[ -z "$out" ]] && ok "cache-heavy -> 79% silent" || bad "cache-heavy -> 79% silent (got: ${out:0:60})"

# sidechain line must be ignored: real usage = 20000 = 10% -> silent
out="$(run_watch sidechain-mixed.jsonl s-side)"
[[ -z "$out" ]] && ok "sidechain line ignored -> silent" || bad "sidechain line ignored (got: ${out:0:60})"

# corrupt: garbage lines skipped, valid line = 170000 = 85% -> fires
out="$(run_watch corrupt.jsonl s-corrupt)"
[[ "$out" == *"at 85%"* ]] && ok "corrupt lines skipped, valid line used" || bad "corrupt lines skipped (got: ${out:0:60})"

# ---------------------------------------------------------------------------
section "Fail-open"

# empty transcript file -> no usage -> silent, exit 0
out="$(run_watch empty.jsonl s-empty)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "empty transcript -> silent exit 0" || bad "empty transcript -> silent exit 0"

# missing transcript path
input="$(jq -nc '{transcript_path:"/nonexistent/x.jsonl", session_id:"s-miss"}')"
out="$(TMPDIR="$RUN_TMP" printf '%s' "$input" | TMPDIR="$RUN_TMP" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "missing transcript -> silent exit 0" || bad "missing transcript -> silent exit 0"

# malformed stdin JSON
out="$(TMPDIR="$RUN_TMP" printf '%s' 'not json {{{' | TMPDIR="$RUN_TMP" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "malformed stdin -> silent exit 0" || bad "malformed stdin -> silent exit 0"

# empty stdin
out="$(printf '' | TMPDIR="$RUN_TMP" bash "$WATCH" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "empty stdin -> silent exit 0" || bad "empty stdin -> silent exit 0"

# no jq on PATH: symlink the core utils the hook needs (cat, tac, head, date,
# mkdir, basename) into a scratch dir but deliberately NOT jq, so the hook's
# `command -v jq` guard is what trips — not a missing coreutil or bash.
nojq_dir="$(mktemp -d)"
for u in cat tac head date mkdir basename pwd; do
    p="$(command -v "$u" 2>/dev/null)" && ln -s "$p" "${nojq_dir}/${u}" 2>/dev/null
done
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-nojq"}')"
out="$(printf '%s' "$input" | PATH="$nojq_dir" TMPDIR="$RUN_TMP" /bin/bash "$WATCH" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "no jq -> silent exit 0" || bad "no jq -> silent exit 0 (rc=$rc out=${out:0:40})"
rm -rf "$nojq_dir"

# unset TMPDIR (marker dir falls back to /tmp) — must still fire without error
input="$(jq -nc --arg t "${FIXTURES}/at-80.jsonl" '{transcript_path:$t, session_id:"s-notmp-'$$'"}')"
out="$(env -u TMPDIR printf '%s' "$input" | env -u TMPDIR bash "$WATCH" 2>/dev/null)"; rc=$?
[[ "$out" == *"CONTEXT-PARACHUTE"* && $rc -eq 0 ]] && ok "unset TMPDIR -> still fires" || bad "unset TMPDIR -> still fires (rc=$rc)"
rm -f "/tmp/context-parachute/s-notmp-$$.fired" 2>/dev/null

# ---------------------------------------------------------------------------
section "PreCompact fallback"

pc_scratch="$(mktemp -d)"
run_precompact() {
    local trigger="$1" sid="$2"
    local input
    input="$(jq -nc --arg tr "$trigger" --arg s "$sid" '{trigger:$tr, session_id:$s}')"
    ( cd "$pc_scratch" && TMPDIR="$RUN_TMP" printf '%s' "$input" | TMPDIR="$RUN_TMP" bash "$PRECOMPACT" 2>/dev/null )
}

# manual -> silent
out="$(run_precompact manual s-pc-manual)"
[[ -z "$out" ]] && ok "precompact manual -> silent" || bad "precompact manual -> silent"

# auto + existing marker -> silent (skill already ran)
mkdir -p "${RUN_TMP}/context-parachute"; : > "${RUN_TMP}/context-parachute/s-pc-marked.fired"
out="$(run_precompact auto s-pc-marked)"
[[ -z "$out" ]] && ok "precompact auto+marker -> silent" || bad "precompact auto+marker -> silent"

# auto + no marker -> emergency prompt to stdout AND emergency.md written
out="$(run_precompact auto s-pc-fire)"
[[ "$out" == *"EMERGENCY BRAIN DUMP"* ]] && ok "precompact auto -> emergency prompt" || bad "precompact auto -> emergency prompt"
[[ -f "${pc_scratch}/.parachute/emergency.md" ]] && ok "precompact auto -> emergency.md written" || bad "precompact auto -> emergency.md written"
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
jq -e --arg c "bash ${REPO_DIR}/hooks/parachute-watch.sh" '.hooks.UserPromptSubmit | any(.[].hooks[]?; .command == $c)' "$S" </dev/null >/dev/null 2>&1 \
    && ok "watcher entry added" || bad "watcher entry added"
jq -e --arg c "bash ${REPO_DIR}/hooks/parachute-precompact.sh" '.hooks.PreCompact | any(.[].hooks[]?; .command == $c)' "$S" </dev/null >/dev/null 2>&1 \
    && ok "precompact entry added" || bad "precompact entry added"

# second install -> no duplicate entries
HOME="$fake_home" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1
cnt="$(jq --arg c "bash ${REPO_DIR}/hooks/parachute-watch.sh" '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == $c)] | length' "$S" </dev/null 2>/dev/null)"
[[ "$cnt" == "1" ]] && ok "re-install is idempotent (no dup watcher)" || bad "re-install idempotent (count=$cnt)"

# uninstall removes our entries, keeps existing
HOME="$fake_home" bash "${REPO_DIR}/uninstall.sh" >/dev/null 2>&1
jq -e --arg c "bash ${REPO_DIR}/hooks/parachute-watch.sh" '.hooks.UserPromptSubmit // [] | any(.[].hooks[]?; .command == $c) | not' "$S" </dev/null >/dev/null 2>&1 \
    && ok "uninstall removes watcher" || bad "uninstall removes watcher"
jq -e '.hooks.UserPromptSubmit | any(.[].hooks[]?; .command == "node /home/user/existing-router.js")' "$S" </dev/null >/dev/null 2>&1 \
    && ok "uninstall keeps existing entry" || bad "uninstall keeps existing entry"
rm -rf "$inst_scratch"

# ---------------------------------------------------------------------------
section "Version consistency (VERSION == CHANGELOG == tag)"

VERSION_FILE="${REPO_DIR}/VERSION"
if [[ -r "$VERSION_FILE" ]]; then
    ver="$(head -n1 "$VERSION_FILE" | tr -d '[:space:]')"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "VERSION is semver ($ver)" || bad "VERSION is semver (got: $ver)"

    # top CHANGELOG release heading: first "## [x.y.z]" line, skipping [Unreleased]
    chlog="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "${REPO_DIR}/CHANGELOG.md" 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    [[ "$chlog" == "$ver" ]] && ok "CHANGELOG top matches VERSION" || bad "CHANGELOG top ($chlog) matches VERSION ($ver)"

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
