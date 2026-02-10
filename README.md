# PM-as-CODE Skill

Single-skill repository for `pm-as-code`.

Repo URL: `https://github.com/DenisSergeevitch/PM-as-CODE-skill`

Skill entrypoint:
- `pm-as-code/SKILL.md`

## TL;DR

- `pm-as-code` gives agents a strict file-based PM workflow.
- Canonical state lives in `status.md` + `.pm/*` (ledger mode).
- Supports both single-agent and multi-agent execution without Git.
- Install by copying `pm-as-code/` into Codex or Claude Code skills directory.

## How It Works

`pm-as-code` keeps project execution state in files instead of chat memory.

Core behavior:
- `status.md` is the canonical project state.
- Every actionable is a checkbox task with ID (`T-0001`, `T-0002`, ...).
- Active tasks must have acceptance criteria.
- Completion requires evidence and an append-only Pulse entry.

Execution path:
- Default for all writes (single-agent and multi-agent): `scripts/pm-collab.sh` or `scripts/pm-collab.ps1` / `scripts/pm-collab.cmd`.
- Use `pm-collab run <pm-ticket command...>`; it auto-resolves agent identity and auto-claims task IDs when needed.
- Agent identity resolution order: `PM_AGENT` -> `CODEX_THREAD_ID` -> `CLAUDE_SESSION_ID` -> host fallback.
- Empty state is auto-covered: missing `status.md`/`.pm` is bootstrapped by `pm-collab init` (or automatically on first `pm-collab run` mutation).
- If repo-local wrappers are missing, call installed skill scripts directly from your skills path.
- Use `pm-ticket.*` directly only for read-only/status operations or maintenance.
- `status.md` is generated output; do not edit it manually.
- Rendered status headers include a bloat metric (`BLOAT_TICKET_THRESHOLD`, default `50`) and print an OS-appropriate `pm-collab run` command once the threshold is reached.

Typical flow:
1. Read `status.md`.
2. Initialize once with `pm-collab ... init` (or rely on automatic bootstrap on first `pm-collab run` mutation).
3. Work one active task ID at a time via `pm-collab run ...`.
4. Let collab wrapper auto-render status and append Pulse history.

## Best Practice (Optional)

Best practice for long-running work is to mention in your `AGENTS.md` or `CLAUDE.md` that the agent should use `pm-as-code` before each task execution. This is optional, but it improves consistency.

Copy-paste prompt:

```md
Before executing each task, invoke and follow `$pm-as-code`.
Use it to read current status, choose/update task IDs, and record completion evidence.
```

## Install Paths

- Codex (macOS/Linux): `~/.codex/skills/pm-as-code`
- Claude Code (macOS/Linux): `~/.claude/skills/pm-as-code`
- Codex (Windows): `%USERPROFILE%\.codex\skills\pm-as-code`
- Claude Code (Windows): `%USERPROFILE%\.claude\skills\pm-as-code`

## Install on macOS (zsh/bash)

### Codex

```bash
git clone https://github.com/DenisSergeevitch/PM-as-CODE-skill.git /tmp/PM-as-CODE-skill && mkdir -p ~/.codex/skills && rm -rf ~/.codex/skills/pm-as-code && cp -R /tmp/PM-as-CODE-skill/pm-as-code ~/.codex/skills/
```

### Claude Code

```bash
git clone https://github.com/DenisSergeevitch/PM-as-CODE-skill.git /tmp/PM-as-CODE-skill && mkdir -p ~/.claude/skills && rm -rf ~/.claude/skills/pm-as-code && cp -R /tmp/PM-as-CODE-skill/pm-as-code ~/.claude/skills/
```

## Install on Windows (PowerShell)

### Codex

```powershell
git clone https://github.com/DenisSergeevitch/PM-as-CODE-skill.git "$env:TEMP\PM-as-CODE-skill"; New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex\skills" | Out-Null; Remove-Item -Recurse -Force "$env:USERPROFILE\.codex\skills\pm-as-code" -ErrorAction SilentlyContinue; Copy-Item -Recurse "$env:TEMP\PM-as-CODE-skill\pm-as-code" "$env:USERPROFILE\.codex\skills\"
```

### Claude Code

```powershell
git clone https://github.com/DenisSergeevitch/PM-as-CODE-skill.git "$env:TEMP\PM-as-CODE-skill"; New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills" | Out-Null; Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\skills\pm-as-code" -ErrorAction SilentlyContinue; Copy-Item -Recurse "$env:TEMP\PM-as-CODE-skill\pm-as-code" "$env:USERPROFILE\.claude\skills\"
```
