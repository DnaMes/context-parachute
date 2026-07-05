# context-parachute — ready-to-paste prompt for OpenCode & pi (picoder)

These tools have **no PreCompact / UserPromptSubmit hooks** like Claude Code, so
they cannot auto-fire the parachute at 80%. Instead they use it two ways:

1. **Consume** — both read `AGENTS.md` natively at startup, so any parachute block
   Claude Code wrote is already in their context (zero paste).
2. **Produce on demand** — paste the prompt below (or say "parachute this session")
   to make the tool write the same cross-agent handoff artifacts itself.

---

## The prompt (paste verbatim, or keep in a snippet)

```
You are the payload of the "context-parachute" cross-agent handoff system.
Capture this session's working state into repo-local, AGENT-AGNOSTIC artifacts
NOW, while context is still fresh, then continue my task.

Write everything in ENGLISH regardless of chat language. Be concrete: real file
paths, real decisions, real failed approaches. A vague handoff is worse than none.

CONFIG: read output_dir (default `.parachute`), update_agents_md (default true),
create_agents_md (default false) from `.parachute/config.json` in the repo, or
`~/.claude/parachute.json`. Otherwise use the defaults.

Write these artifacts:

1. HANDOFF.md (repo root) — READ existing file first if present, then update.
   Sections: Goal · Current Progress · What Worked · What Didn't Work ·
   Decisions Made (each + WHY) · Files Changed (path + one-line what/why) ·
   Next Steps (ordered, concrete).

2. <output_dir>/continue.md — generic continuation prompt, self-contained and
   ready to paste into ANY tool (Cursor, aider, Gemini, ChatGPT, OpenCode, pi,
   fresh Claude). MUST open with a "verify state before trusting this document"
   preamble: reader runs `git status`, `git diff`, re-reads key files first,
   because the repo may have moved on. Point to HANDOFF.md as source of truth.
   Summarize the immediate next step inline.

3. <output_dir>/continue-claude.md — same intent, tuned for Claude Code. Tell the
   reader to run /clear then paste this (clean session beats compacted context).

4. AGENTS.md block (repo root) — only if update_agents_md is true. Maintain a
   marker-delimited block so OpenCode/Codex/pi get zero-paste pickup next time:
       <!-- parachute:begin -->
       ... one-paragraph state summary + pointer to HANDOFF.md + next step ...
       <!-- parachute:end -->
   Replace the block if the markers already exist; append it if not. Do NOT
   duplicate. If AGENTS.md does not exist and create_agents_md is false, skip
   this artifact (do not create the file).

After writing, print a one-line receipt: which files were written/updated.
Then continue with my actual task.
```

---

## When to fire it (self-trigger, since no hook exists)

Fire the prompt when ANY of these is true — you are responsible for noticing,
there is no watcher in these tools:

- The session is long and you sense context is getting heavy (rough rule: you've
  read many large files or the conversation spans many turns).
- Before the user runs a context reset / new session on unfinished work.
- Before a risky or hard-to-resume step (big refactor, migration, long build).
- The user says "parachute", "hand off", "eject", "save state", "before I clear".

## Note on limits

Unlike Claude Code, there is no token-percentage watcher here. The 80% auto-fire
is Claude-Code-only. In OpenCode/pi the parachute is **on-demand + consume-side**:
you read any existing AGENTS.md parachute block automatically, and you write fresh
artifacts when asked or when you judge the session is at risk of losing state.
