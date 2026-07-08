# context-parachute

## Kontext

Auto-eject session handoff fuer AI-Coding-Agents. Schreibt bei vollem
Context-Window automatisch Session-Summary, `HANDOFF.md` und Continuation-Prompts
(`.parachute/continue*.md`) ins Projektverzeichnis — agent-agnostisch
(Claude Code, Codex, Gemini, OpenCode, Cursor). Kein Daemon, keine Datenbank;
nur `bash` + `jq`, zwei fail-open Hooks und ein Skill.

## Stack

- Sprache: Bash (+ jq)
- Framework: Claude-Code-Hooks + Skill

## Commands

- Install: `./install.sh`
- Uninstall: `./uninstall.sh`
- Test: `bash tests/` (siehe tests/-Verzeichnis)

## Konventionen

- Conventional Commits: feat:, fix:, chore:, docs:, refactor:
- Worktrees unter `.wt/` (lokal, gitignored via .git/info/exclude)
- NEXT.md fuer naechsten Schritt (lokal, gitignored)
- LOCAL.md fuer persoenliche Notizen (lokal, gitignored)
- Code-Docs in `docs/` (git-tracked)
- Planung/Notizen in ObsidianVault/Projects/lab/context-parachute/
- Public Repo: github.com/DnaMes/context-parachute — Englisch, keine internen Pfade leaken

## Dont

- Keine Secrets committen (.env, *.pem, *.key)
- Hooks muessen fail-open bleiben (nie eine Session blockieren)
- Keine force-pushes auf main
