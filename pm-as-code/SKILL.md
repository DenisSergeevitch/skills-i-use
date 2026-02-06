---
name: pm-as-code
description: "Strict Markdown project management with status.md as the canonical entrypoint: checkbox-only tasks with IDs, acceptance criteria, evidence, and append-only pulse history. Includes no-dependency Bash and Windows (PowerShell/CMD) ticket and collab wrappers for long-running and multi-agent repos."
---

# PM as Code

## Contract

- Read `status.md` first in every session.
- Keep all actionables as checkboxes only: `- [ ]` or `- [x]`.
- Give every task an ID (`T-0001`, `T-0002`, ...), and keep counters in `status.md`.
- Keep required section order exactly as defined in `references/status-template.md`.
- Keep acceptance criteria for active tasks keyed by task ID.
- Treat Pulse history as append-only.
- Resolve ambiguity by updating docs, never by relying on chat memory.

## Done Gate

A task is done only when all are true:
- task checkbox is `[x]`
- acceptance criteria are `[x]`
- evidence is recorded
- `Now / In progress / Blocked / Next` are updated
- a new Pulse entry is appended

## Session Loop

1. Read `status.md`.
2. Execute one active task ID (prefer `Now`).
3. If new work appears, create a new task ID immediately.
4. If blocked, move task to `Blocked` with explicit blocker text.
5. On completion, run the Done Gate.

## Mode Selection

Use direct Markdown mode for short projects.

Use ledger mode when `status.md` grows:
- `scripts/pm-ticket.sh` (Bash)
- `scripts/pm-ticket.ps1` or `scripts/pm-ticket.cmd` (Windows)
- Prefer scoped ledgers for parallel teams: `--scope <name>` (or `PM_SCOPE`).
- Ledger files in `.pm/scopes/<scope>/*` are the machine record.
- `status.md` is rendered:
  - single default scope: full snapshot
  - multiple scopes (or non-default only): compact scope index to `status.<scope>.md`

Use multi-agent mode for shared workspaces:
- `scripts/pm-collab.sh` (Bash)
- `scripts/pm-collab.ps1` or `scripts/pm-collab.cmd` (Windows)
- Run all writes through collab wrappers (lock + per-task claim).

For teammate handoffs, use a bounded task pack:
- `scripts/pm-ticket.sh [--scope <name>] render-context <T-0001> [evidence-tail]`
- `scripts/pm-ticket.ps1 [--scope <name>] render-context <T-0001> [evidence-tail]`

## References

- `references/pm-rules.md`
- `references/status-template.md`
- `references/optional-doc-templates.md`
- `references/compact-ticket-system.md`
