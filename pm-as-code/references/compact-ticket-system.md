# Compact Ticket System (Bash, No Dependencies)

Use this when `status.md` gets large and wastes context space.

## What It Stores

- `.pm/meta.env`: counters and render settings.
- `.pm/core.md`: stable core context block.
- `.pm/tickets.tsv`: task ID, state, title, deps, timestamps.
- `.pm/criteria.tsv`: acceptance criteria by task ID.
- `.pm/evidence.tsv`: completion evidence records.
- `.pm/pulse.log`: append-only event log.
- `status.md`: compact, rendered project snapshot.

## Commands

```bash
scripts/pm-ticket.sh init
scripts/pm-ticket.sh new next "Implement OAuth callback flow"
scripts/pm-ticket.sh criterion-add T-0001 "Callback route validates state"
scripts/pm-ticket.sh move T-0001 in-progress
scripts/pm-ticket.sh criterion-check T-0001 1
scripts/pm-ticket.sh evidence T-0001 "src/auth/callback.ts" "state validation added"
scripts/pm-ticket.sh done T-0001 "src/auth/callback.ts" "manual test passed"
scripts/pm-ticket.sh render status.md
```

## States

- `now`
- `in-progress`
- `blocked`
- `next`
- `done`

## Recommended Workflow

1. Initialize once with `init`.
2. Create tasks with `new`.
3. Add acceptance criteria immediately.
4. Update state with `move`.
5. Record evidence and close with `done`.
6. Re-render `status.md` after task changes.

## Why This Saves Context

- `status.md` stays small and scannable.
- Full history stays in `.pm/pulse.log`.
- Structured TSV files avoid verbose prose growth.
