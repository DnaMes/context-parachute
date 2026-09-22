# Related tools and design lessons

Research date: 2026-09-21. These observations come from upstream documentation,
not from installing or benchmarking the projects. They supersede the July
comparison; the ecosystem now has substantial overlap with context-parachute.

| Project | Documented approach | Useful lesson for context-parachute |
|---|---|---|
| [willseltzer/claude-handoff](https://github.com/willseltzer/claude-handoff) | Full/quick handoff commands and a resume flow that checks repository drift. | Keep a compact handoff mode and make resume validation explicit. |
| [mjbarefo/baton](https://github.com/mjbarefo/baton) | Host-neutral `.baton/BATON.md`, validation, host adapters, startup resume/archive, and redacted sidecar reviews. | Separate a stable artifact contract from host integrations; validate before marking a save complete. |
| [sethyanow/session-context](https://github.com/sethyanow/session-context) | SessionStart recovery plus hooks tracking file edits, plans, todos, and user decisions. | Record minimal structured facts incrementally; inject only relevant recovery state. |
| [adrrr/persistent-handoff](https://github.com/adrrr/persistent-handoff) | A milestone-updated handoff file reread by SessionStart. | Restore state after a restart/compact without requiring the user to paste it. |
| [f3kpclon/claude-code-handoff](https://github.com/f3kpclon/claude-code-handoff) | Statusline context monitoring, threshold dialogs, private timestamped snapshots, and a mechanical PreCompact snapshot. | Consider explicit context telemetry and optional private history; keep deterministic recovery independent of a model turn. |

## Candidate improvements

The following are design recommendations inferred from those projects, not
features implemented or guaranteed by this review.

1. **Validate and acknowledge completed handoffs.** Add small structured metadata
   for schema version, UTC timestamp, session/worktree, branch/HEAD, and completed
   artifacts. A validator should reject incomplete sets without blocking the
   coding session. Keep “directive sent” separate from “handoff saved.”
2. **Opt-in recovery on startup and after compaction.** Use a supported
   SessionStart adapter to point to the relevant handoff after checking freshness
   and repository state. Bound injected text and never let older notes replace
   the newest user request. Test against an actual supported host version.
3. **Handle long and parallel sessions.** Store snapshots by session/worktree,
   preserve a simple latest pointer, and define how advisories rearm after a
   verified context reset. Test concurrent writers and repeated compactions.
4. **Offer quick and full saves.** Keep the next action, blockers, decisions, and
   failed approaches in a short default handoff. Put extended evidence behind
   links, with explicit artifact budgets and checks against secret copying.
5. **Package native host adapters only after the contract is stable.** Preserve
   plain Bash + jq and manual export as useful defaults. Do not assume Claude
   hook semantics, authorization, or tools exist in another host.

## Platform constraints to retain

The [Claude Code hook reference](https://code.claude.com/docs/en/hooks) documents
context injection for UserPromptSubmit and SessionStart. PreCompact is suitable
for deterministic persistence; it does not guarantee an extra model-writing
turn. Hook timeouts must be explicit, and emitted warnings must not be confused
with completed handoffs. Avoid copying competitors' blocking or autonomous
restart behavior into a plugin whose contract is fail-open.

The [Agent Skills specification](https://agentskills.io/specification) supports
arbitrary string metadata, including a version. Bundling that metadata is enough
to fix manual provenance without a new service, database, or runtime dependency.
