#!/usr/bin/env bash
set -euo pipefail

PM_DIR=".pm"
META_FILE="$PM_DIR/meta.env"
CORE_FILE="$PM_DIR/core.md"
TICKETS_FILE="$PM_DIR/tickets.tsv"
CRITERIA_FILE="$PM_DIR/criteria.tsv"
EVIDENCE_FILE="$PM_DIR/evidence.tsv"
PULSE_FILE="$PM_DIR/pulse.log"
CLAIMS_FILE="$PM_DIR/claims.tsv"

usage() {
  cat <<'EOF'
Usage:
  pm-ticket.sh init
  pm-ticket.sh new <now|in-progress|blocked|next> "<title>" [deps]
  pm-ticket.sh move <T-0001> <now|in-progress|blocked|next|done> [note]
  pm-ticket.sh criterion-add <T-0001> "<criterion>"
  pm-ticket.sh criterion-check <T-0001> <index>
  pm-ticket.sh evidence <T-0001> "<path-or-link>" [note]
  pm-ticket.sh done <T-0001> "<path-or-link>" [note]
  pm-ticket.sh list [state]
  pm-ticket.sh render [status.md]
  pm-ticket.sh next-id
EOF
}

now_date() {
  date +%F
}

now_ts() {
  date "+%F %T"
}

sanitize() {
  local s="$1"
  s="${s//$'\t'/ }"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

require_pm_dir() {
  if [[ ! -d "$PM_DIR" ]]; then
    echo "error: $PM_DIR not initialized. Run: pm-ticket.sh init" >&2
    exit 1
  fi
}

normalize_state() {
  local raw
  raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    now) printf 'NOW' ;;
    in-progress|inprogress|doing) printf 'IN_PROGRESS' ;;
    blocked) printf 'BLOCKED' ;;
    next|todo) printf 'NEXT' ;;
    done|closed) printf 'DONE' ;;
    *)
      echo "error: invalid state '$1'" >&2
      exit 1
      ;;
  esac
}

state_heading() {
  case "$1" in
    NOW) printf 'Now (top priorities)' ;;
    IN_PROGRESS) printf 'In progress' ;;
    BLOCKED) printf 'Blocked' ;;
    NEXT) printf 'Next' ;;
    DONE) printf 'Done' ;;
    *) printf 'Unknown' ;;
  esac
}

format_id() {
  printf 'T-%04d' "$1"
}

load_meta() {
  require_pm_dir
  if [[ ! -f "$META_FILE" ]]; then
    echo "error: missing $META_FILE" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$META_FILE"
  NEXT_TASK_NUM="${NEXT_TASK_NUM:-1}"
  PULSE_TAIL="${PULSE_TAIL:-30}"
  NEXT_LIMIT="${NEXT_LIMIT:-20}"
  EVIDENCE_TAIL="${EVIDENCE_TAIL:-50}"
}

save_meta() {
  cat >"$META_FILE" <<EOF
NEXT_TASK_NUM=$NEXT_TASK_NUM
PULSE_TAIL=$PULSE_TAIL
NEXT_LIMIT=$NEXT_LIMIT
EVIDENCE_TAIL=$EVIDENCE_TAIL
EOF
}

append_pulse() {
  local task_id="$1"
  local event="$2"
  local details
  details="$(sanitize "${3:-}")"
  printf '%s|%s|%s|%s\n' "$(now_ts)" "$task_id" "$event" "$details" >>"$PULSE_FILE"
}

ensure_base_files() {
  mkdir -p "$PM_DIR"
  [[ -f "$TICKETS_FILE" ]] || printf 'id\tstate\ttitle\tdeps\tcreated\tupdated\n' >"$TICKETS_FILE"
  [[ -f "$CRITERIA_FILE" ]] || printf 'id\tdone\ttext\n' >"$CRITERIA_FILE"
  [[ -f "$EVIDENCE_FILE" ]] || printf 'id\tdate\tlocation\tnote\n' >"$EVIDENCE_FILE"
  [[ -f "$PULSE_FILE" ]] || : >"$PULSE_FILE"
}

cmd_init() {
  ensure_base_files
  if [[ ! -f "$META_FILE" ]]; then
    NEXT_TASK_NUM=1
    PULSE_TAIL=30
    NEXT_LIMIT=20
    EVIDENCE_TAIL=50
    save_meta
  fi
  if [[ ! -f "$CORE_FILE" ]]; then
    cat >"$CORE_FILE" <<'EOF'
## CORE context (keep short; must stay true)

### Objective
<One sentence: what winning means.>

### Current phase
<Discovery | Build | Beta | Launch | Maintenance>

### Constraints (if any)
- <constraint 1>
- <constraint 2>

### Success metrics (if known)
- <metric 1>
- <metric 2>

### Scope boundaries (if helpful)
- In scope: <...>
- Out of scope: <...>
EOF
  fi
  append_pulse "SYSTEM" "INIT" "Initialized .pm ledger"
  cmd_render "status.md"
}

ticket_exists() {
  local task_id="$1"
  awk -F'\t' -v id="$task_id" 'NR > 1 && $1 == id { found=1 } END { exit(found ? 0 : 1) }' "$TICKETS_FILE"
}

update_ticket_state() {
  local task_id="$1"
  local new_state="$2"
  local note="$3"
  local details
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v id="$task_id" -v st="$new_state" -v dt="$(now_date)" '
    NR == 1 { print; next }
    $1 == id { $2 = st; $6 = dt; found = 1 }
    { print }
    END {
      if (!found) exit 42
    }
  ' "$TICKETS_FILE" >"$tmp" || {
    rc=$?
    rm -f "$tmp"
    if [[ $rc -eq 42 ]]; then
      echo "error: task not found: $task_id" >&2
      exit 1
    fi
    exit "$rc"
  }
  mv "$tmp" "$TICKETS_FILE"
  details="state=$new_state"
  if [[ -n "$note" ]]; then
    details="$details - $note"
  fi
  append_pulse "$task_id" "MOVE" "$details"
}

cmd_new() {
  load_meta
  ensure_base_files
  local state title deps task_id today
  state="$(normalize_state "$1")"
  title="$(sanitize "$2")"
  deps="$(sanitize "${3:-}")"
  today="$(now_date)"
  task_id="$(format_id "$NEXT_TASK_NUM")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$task_id" "$state" "$title" "$deps" "$today" "$today" >>"$TICKETS_FILE"
  NEXT_TASK_NUM=$((NEXT_TASK_NUM + 1))
  save_meta
  append_pulse "$task_id" "CREATE" "state=$state title=$title"
  printf '%s\n' "$task_id"
}

cmd_move() {
  load_meta
  local task_id new_state note
  task_id="$1"
  new_state="$(normalize_state "$2")"
  note="$(sanitize "${3:-}")"
  update_ticket_state "$task_id" "$new_state" "$note"
}

cmd_criterion_add() {
  load_meta
  local task_id text
  task_id="$1"
  text="$(sanitize "$2")"
  if ! ticket_exists "$task_id"; then
    echo "error: task not found: $task_id" >&2
    exit 1
  fi
  printf '%s\t0\t%s\n' "$task_id" "$text" >>"$CRITERIA_FILE"
  append_pulse "$task_id" "CRITERION_ADD" "$text"
}

cmd_criterion_check() {
  load_meta
  local task_id idx tmp
  task_id="$1"
  idx="$2"
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v id="$task_id" -v target="$idx" '
    NR == 1 { print; next }
    $1 == id {
      count++
      if (count == target) {
        $2 = 1
        found = 1
      }
    }
    { print }
    END {
      if (!found) exit 42
    }
  ' "$CRITERIA_FILE" >"$tmp" || {
    rc=$?
    rm -f "$tmp"
    if [[ $rc -eq 42 ]]; then
      echo "error: criterion index not found for $task_id: $idx" >&2
      exit 1
    fi
    exit "$rc"
  }
  mv "$tmp" "$CRITERIA_FILE"
  append_pulse "$task_id" "CRITERION_CHECK" "index=$idx"
}

cmd_evidence() {
  load_meta
  local task_id location note
  task_id="$1"
  location="$(sanitize "$2")"
  note="$(sanitize "${3:-}")"
  if ! ticket_exists "$task_id"; then
    echo "error: task not found: $task_id" >&2
    exit 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$task_id" "$(now_date)" "$location" "$note" >>"$EVIDENCE_FILE"
  if [[ -n "$note" ]]; then
    append_pulse "$task_id" "EVIDENCE" "$location - $note"
  else
    append_pulse "$task_id" "EVIDENCE" "$location"
  fi
}

cmd_done() {
  load_meta
  local task_id location note
  task_id="$1"
  location="$2"
  note="${3:-}"
  cmd_evidence "$task_id" "$location" "$note"
  update_ticket_state "$task_id" "DONE" "completed"
}

cmd_list() {
  load_meta
  local filter=""
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    filter="$(normalize_state "$1")"
  fi
  awk -F'\t' -v st="$filter" '
    NR == 1 { next }
    st == "" || $2 == st {
      printf "%s\t%s\t%s\n", $1, $2, $3
    }
  ' "$TICKETS_FILE"
}

print_state_section() {
  local state="$1"
  local limit="${2:-0}"
  local heading
  heading="$(state_heading "$state")"
  printf '### %s\n' "$heading"
  awk -F'\t' -v st="$state" -v lim="$limit" -v claims_path="$CLAIMS_FILE" '
    BEGIN {
      if (claims_path != "") {
        while ((getline line < claims_path) > 0) {
          if (line == "") continue
          split(line, claim_parts, "\t")
          if (claim_parts[1] == "id") continue
          claims[claim_parts[1]] = claim_parts[2]
        }
        close(claims_path)
      }
    }
    NR == 1 { next }
    $2 == st {
      total++
      if (lim > 0 && total > lim) {
        hidden++
        next
      }
      dep = ""
      if ($4 != "") dep = " (deps: " $4 ")"
      claim = ""
      if (($1 in claims) && claims[$1] != "" && $2 != "DONE") {
        claim = " (claimed: " claims[$1] ")"
      }
      printf "- [ ] %s - %s%s%s\n", $1, $3, dep, claim
    }
    END {
      if (total == 0) print "- (none)"
      if (hidden > 0) print "- ... +" hidden " more (see .pm/tickets.tsv)"
    }
  ' "$TICKETS_FILE"
  printf '\n'
}

print_acceptance_criteria() {
  local active_ids
  active_ids="$(awk -F'\t' 'NR > 1 && $2 != "DONE" { print $1 }' "$TICKETS_FILE")"
  if [[ -z "$active_ids" ]]; then
    echo "_No active tasks_"
    return
  fi

  while IFS= read -r task_id; do
    [[ -z "$task_id" ]] && continue
    printf '### %s acceptance criteria\n' "$task_id"
    awk -F'\t' -v id="$task_id" '
      NR == 1 { next }
      $1 == id {
        mark = ($2 == 1 ? "x" : " ")
        printf "- [%s] %s\n", mark, $3
        found = 1
      }
      END {
        if (!found) print "- [ ] Add acceptance criteria"
      }
    ' "$CRITERIA_FILE"
    printf '\n'
  done <<<"$active_ids"
}

format_evidence_lines() {
  awk -F'\t' '
    {
      note = ""
      if ($4 != "") note = " - " $4
      printf "- %s: %s (%s)%s\n", $1, $3, $2, note
    }
  '
}

print_evidence_index() {
  local tail_count="${1:-0}"
  local total omitted

  total="$(awk 'NR > 1 { c++ } END { print c + 0 }' "$EVIDENCE_FILE")"
  if ((total == 0)); then
    echo "- (none)"
    return
  fi

  omitted=0
  if ((tail_count > 0 && total > tail_count)); then
    omitted=$((total - tail_count))
  fi

  if ((tail_count > 0)); then
    awk -F'\t' 'NR > 1 { print }' "$EVIDENCE_FILE" | tail -n "$tail_count" | format_evidence_lines
  else
    awk -F'\t' 'NR > 1 { print }' "$EVIDENCE_FILE" | format_evidence_lines
  fi

  if ((omitted > 0)); then
    echo "- ... +$omitted older entries (see .pm/evidence.tsv)"
  fi
}

print_pulse_tail() {
  local tail_count="$1"
  if [[ ! -s "$PULSE_FILE" ]]; then
    echo "- (no entries)"
    return
  fi
  tail -n "$tail_count" "$PULSE_FILE" | while IFS='|' read -r ts task_id event details; do
    printf -- '- %s | %s | %s | %s\n' "$ts" "$task_id" "$event" "$details"
  done
}

cmd_render() {
  load_meta
  local out="${1:-status.md}"
  local next_task_id
  next_task_id="$(format_id "$NEXT_TASK_NUM")"

  {
    echo "# status.md"
    echo "## Project Pulse"
    echo
    echo "Last updated: $(now_date)"
    echo
    echo "---"
    echo
    if [[ -f "$CORE_FILE" ]]; then
      cat "$CORE_FILE"
      echo
    else
      echo "## CORE context (keep short; must stay true)"
      echo
      echo "### Objective"
      echo "<One sentence: what winning means.>"
      echo
      echo "### Current phase"
      echo "<Discovery | Build | Beta | Launch | Maintenance>"
      echo
    fi
    echo "### Counters"
    echo "- Next Task ID: $next_task_id"
    echo
    echo "---"
    echo
    echo "## Current state (always keep accurate)"
    echo
    print_state_section "NOW"
    print_state_section "IN_PROGRESS"
    print_state_section "BLOCKED"
    if ((NEXT_LIMIT > 0)); then
      print_state_section "NEXT" "$NEXT_LIMIT"
      echo "> Next shows up to $NEXT_LIMIT items; see .pm/tickets.tsv for full backlog"
      echo
    else
      print_state_section "NEXT"
    fi
    echo "---"
    echo
    echo "## Acceptance criteria (required for active tasks)"
    echo
    print_acceptance_criteria
    echo "---"
    echo
    echo "## Evidence index (keep it navigable)"
    echo "> Source of truth: .pm/evidence.tsv"
    if ((EVIDENCE_TAIL > 0)); then
      echo "> Showing latest $EVIDENCE_TAIL entries to keep status.md compact"
    fi
    echo
    print_evidence_index "$EVIDENCE_TAIL"
    echo
    echo "---"
    echo
    echo "## Pulse Log (append-only)"
    echo "> Source of truth: .pm/pulse.log (full history)"
    echo "> Showing latest $PULSE_TAIL entries to keep status.md compact"
    echo
    print_pulse_tail "$PULSE_TAIL"
  } >"$out"
}

cmd_next_id() {
  load_meta
  format_id "$NEXT_TASK_NUM"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    init)
      cmd_init
      ;;
    new)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      cmd_new "$1" "$2" "${3:-}"
      ;;
    move)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      cmd_move "$1" "$2" "${3:-}"
      ;;
    criterion-add)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      cmd_criterion_add "$1" "$2"
      ;;
    criterion-check)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      cmd_criterion_check "$1" "$2"
      ;;
    evidence)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      cmd_evidence "$1" "$2" "${3:-}"
      ;;
    done)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      cmd_done "$1" "$2" "${3:-}"
      ;;
    list)
      if [[ $# -gt 0 ]]; then
        cmd_list "$1"
      else
        cmd_list
      fi
      ;;
    render)
      cmd_render "${1:-status.md}"
      ;;
    next-id)
      cmd_next_id
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
