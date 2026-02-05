# Optional Document Templates

Create these files only when project scale requires them. Keep them consistent with `status.md`.

## backlog.md

```md
# backlog.md
## Backlog

Rules:
- All items are checkboxes.
- All items have IDs.
- Done items are archived, not deleted.

## P0
- [ ] T-0100 - <outcome>

## P1
- [ ] T-0101 - <outcome>

## Done (archive)
### YYYY-MM
- [x] T-0007 - <outcome> (completed: YYYY-MM-DD)
```

## decisions/ADR-0000-template.md

```md
# ADR-0000 - <decision title>

Date: YYYY-MM-DD
Status: Proposed | Accepted | Superseded
Related tasks: T-0000, T-0001

## Context
<What forced this decision? What constraints matter?>

## Decision
<What we decided.>

## Alternatives considered
- Option A - pros/cons
- Option B - pros/cons

## Consequences
<What changes now, what tradeoffs we accept.>

## Follow-ups
- [ ] T-0000 - <follow-up task>
```

## risks.md

```md
# risks.md
## Risk Register

## RISK-01 - <risk title>
Severity: low | medium | high

Triggers:
- <what to watch>

Mitigations:
- [ ] T-0000 - <mitigation task>

Contingency:
- <what we do if it happens>
```
