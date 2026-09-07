#!/usr/bin/env bash
# Read and account for the local startup-memory budget.
# Usage:
#   fm-startup-memory-budget.sh read
#   fm-startup-memory-budget.sh report
#   fm-startup-memory-budget.sh enforce
#
# `read` prints the one validated effective budget from
# config/startup-memory-budget.  `report` prints the stable local estimate for
# data/captain.md, data/captain-shared.md, and data/learnings.md together.
# `enforce` prints the same accounting but ties the EXIT CODE to compliance -
# exit 0 only when within budget, exit 3 when over budget - so a caller at a
# real startup/consumption or a durable-memory-write boundary can gate on it. A
# `report` exit 0 alone is NOT compliance (it means the accounting merely ran);
# `enforce` is the deterministic gate. HONEST BOUND: direct-write and raw-shell
# paths cannot be universally intercepted - this gates only at the qualified
# owner boundaries that call it, never a text-pattern shell blacklist.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent, malformed, symlinked, hardlinked, or otherwise
# unsafe value is a concrete error rather than an inferred default.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,17{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'startup-memory-budget: %s\n' "$1" >&2
}

read_budget() {
  if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
    print_error "invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$FM_STARTUP_MEMORY_BUDGET_VALUE"
}

report() {
  local budget bytes tokens presence total=0 shared_tokens=0 role=primary
  if ! budget=$(read_budget); then
    return 2
  fi

  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    role=secondmate
  fi

  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'role=%s\n' "$role"
  printf 'effective_budget_tokens=%s\n' "$budget"
  for file in captain.md captain-shared.md learnings.md; do
    if ! fm_startup_memory_measure_file "$DATA/$file" >/dev/null; then
      print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    bytes=$FM_STARTUP_MEMORY_MEASURE_BYTES
    tokens=$FM_STARTUP_MEMORY_MEASURE_TOKENS
    presence=$FM_STARTUP_MEMORY_MEASURE_PRESENCE
    total=$((total + tokens))
    [ "$file" != captain-shared.md ] || shared_tokens=$tokens
    printf 'file=data/%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$file" "$bytes" "$tokens" "$presence"
  done
  printf 'total_estimated_tokens=%s\n' "$total"
  if fm_startup_memory_decimal_le "$total" "$budget"; then
    printf 'budget_status=within-budget\n'
  else
    printf 'budget_status=over-budget\n'
  fi
  if [ "$role" = secondmate ] \
    && ! fm_startup_memory_decimal_le "$shared_tokens" "$budget"; then
    printf 'exception=primary-owned-shared-file-alone-exceeds-budget\n'
  fi
}

# enforce prints the accounting like report, but returns exit 3 when the total
# is over budget so a caller can gate a real startup/consumption or a durable-
# memory-write on compliance rather than on report's always-0 "it ran" status.
enforce() {
  local out status
  if ! out=$(report); then
    return 2
  fi
  printf '%s\n' "$out"
  status=$(printf '%s\n' "$out" | sed -n 's/^budget_status=//p' | head -1)
  case "$status" in
    within-budget) return 0 ;;
    over-budget)
      print_error "durable memory is over the ${FM_STARTUP_MEMORY_BUDGET_FILE} budget; curate before the next durable-memory write (see /stow)"
      return 3 ;;
    *)
      print_error "budget status could not be determined"
      return 2 ;;
  esac
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report
    ;;
  enforce)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    enforce
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
