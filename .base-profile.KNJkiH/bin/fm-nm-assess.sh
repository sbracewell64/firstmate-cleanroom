#!/usr/bin/env bash
# fm-nm-assess.sh - single owner of the continual per-run TWO-LEVEL ASSESSMENT
# that sits on top of the no-mistakes observation obligation (bin/fm-nm-observe.sh).
#
# Usage:
#   fm-nm-assess.sh assess   <task-id> [--transition <t>] [--no-query]
#                            [--provider-capacity <detail>] [--repair-attempts <n>]
#                            [--usage-cost <val>] [--gate <name>]
#                            [--finding <owner>:<invariant>:<family>[:<applicability>]]...
#                            [--carried-finding <id>] [--executed <csv>]
#                            [--never-started <csv>] [--next-owner <text>]
#                            [--disposition <d>] [--accepted-authority <ref>]
#                            [--supersede <key|carried|provider>[,...]]
#                            [--coverage-performed]
#   fm-nm-assess.sh receipt  <task-id>
#   fm-nm-assess.sh families [--task <task-id>]
#   fm-nm-assess.sh coverage [--now <epoch>]
#   fm-nm-assess.sh --help
#
# Why. NMF-OBS-1 records WHICH run a managed launch became and its canonical
# outcome. This owner adds the ASSESSMENT: for every applicable run at each
# material transition (stall/failure, CI-ready, terminal outcome, later
# terminal/head revision) it produces a durable per-run receipt with two
# levels, deduplicates findings into families that never lose occurrence
# history, routes each finding to its existing owner, classifies
# provider-capacity as a typed external resource-blocked condition, reconciles
# a late merge against provider/canonical state rather than a stale cached run
# record, and mechanically enforces that every admitted launch has an
# observation-or-error, every assessment has a disposition, and every
# remediation has an owner and a next gate.
#
# Boundary (the same boundary NMF-OBS-1 keeps, restated for this owner). The
# observer OBSERVES, CLASSIFIES, and ROUTES only. It NEVER starts, answers,
# aborts, syncs, or reruns a pipeline; never approves a gate; never merges,
# deploys, edits a pipeline-owned checkout, changes a model or budget, or
# manufactures a PASS. It NEVER repairs pinned no-mistakes internals: a
# provider-capacity finding is routed to the upstream tooling-qualification
# owner, never fixed here. It never writes the NMF-OBS-1 obligation (it READS
# state/<id>.nm-observe and never mutates it) and never writes under NM_HOME.
# The only verbs it sends to `no-mistakes` are `axi status` and
# `axi status --run <id>`, both read-only, and only when a bound run is present
# and --no-query was not passed.
#
# Records (this script is the only writer of each):
#   state/<id>.nm-assessment           the per-run assessment, key=value,
#                                      fm-nm-assessment/v1; rewritten on every
#                                      assess and rendered into the receipt
#   data/<id>/nm-assessment-receipt.md the two-level receipt; survives teardown
#   data/nm-finding-families/<key>     one durable file per finding family,
#                                      fm-nm-finding-family/v1: a header plus
#                                      append-only occurrence lines keyed by
#                                      task|run|transition|head (re-assessing the
#                                      identical occurrence replaces its line;
#                                      a distinct task, run, transition, OR head
#                                      revision never overwrites another, so
#                                      occurrence history is immutable across
#                                      head revisions and never lost)
#   state/.nm-assess-<id>.lock         per-task write lock
#   state/.nm-finding-families.lock    family-store write lock
#
# Finding families are deduplicated by owner + violated invariant + failure
# family + contract/profile applicability. Routing:
#   provider-capacity   -> nmf-provider-capacity-typed-condition (pinned-tool
#                          root fix, UPSTREAM; observer only observes/classifies/
#                          routes and MUST NOT repair pinned internals)
#   check-normalization -> nmf-observer-check-normalization
#   anything else       -> the explicit owner the finding carries; a finding
#                          with no owner is a bounded-owner-task to be filed
# Dispositions: handled-in-run, linked-existing-repair, bounded-owner-task,
# accepted-deferred-with-authority, no-actionable-anomaly, coverage-unperformed.
# A malformed --disposition is refused (exit 2) before anything is recorded, so a
# nonsense value can never reach coverage/closure.
#
# Refresh semantics. An ordinary refresh (a re-assess or the observation owner's
# best-effort hook, both --no-query with no new findings) PRESERVES the carried
# residual finding, the provider-capacity block, and every recorded finding
# family it already holds; it never silently clears them. Carried state is closed
# only by a typed owner action: --supersede <family-key> drops one recorded
# finding, --supersede carried clears the carried residual, and --supersede
# provider clears a carried provider-capacity block once capacity has returned.
#
# CI-ready needs source-applicable evidence. A run is reported ci-ready only when
# the effective canonical outcome is checks-passed; ci-ready is never inferred
# from an absent, empty, or merely normalized outcome_class. Without that
# evidence the transition is ci-ready-unverified, a check-normalization finding
# is raised, and no clean CI-ready is claimed.
#
# Coverage performed vs UNPERFORMED. Recording that an assessment exists is not
# an investigation. Coverage counts as PERFORMED only when a canonical read
# actually ran, or findings/provider/carried state were ingested or carried, or
# --coverage-performed explicitly asserts a clean investigation. Otherwise (the
# bare existence-recording hook path) the assessment is disposed
# coverage-unperformed and the receipt says so, rather than manufacturing a
# clean no-actionable-anomaly.
#
# Exit codes: 0 done (including a coverage pass that printed enforcement gaps);
# 1 typed refusal (NOT_ENROLLED); 2 usage or an unreadable record.
#
# docs/no-mistakes-observation.md owns the assessment invariant and its place
# in the entrypoint census; docs/configuration.md routes the home layout.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

OBLIGATION_SCHEMA=fm-nm-observation/v1
ASSESS_SCHEMA=fm-nm-assessment/v1
FAMILY_SCHEMA=fm-nm-finding-family/v1
CALL_TIMEOUT=${FM_NM_OBSERVE_TIMEOUT:-8}
FAMILIES_DIR="$DATA/nm-finding-families"
FAMILIES_LOCK="$STATE/.nm-finding-families.lock"

usage() {
  sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "error: $1" >&2
  echo "usage: fm-nm-assess.sh assess <task-id> [flags] | receipt <task-id> | families [--task <id>] | coverage [--now <epoch>] | --help" >&2
  exit 2
}

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Age in seconds from <now> to <epoch-field>, or `unknown` when either operand
# is empty or non-numeric (never a negative, garbage, or arithmetic-error value).
# <now> is validated at dispatch; this guard keeps the arithmetic total even if a
# malformed epoch ever reaches it.
age_of() {  # <now> <epoch-field>
  case "$1" in
    ''|*[!0-9]*) printf 'unknown'; return 0 ;;
  esac
  case "$2" in
    ''|*[!0-9]*) printf 'unknown' ;;
    *) printf '%ss' "$(( $1 - $2 ))" ;;
  esac
}

valid_task_id() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*|.*|-*) return 1 ;;
  esac
  return 0
}

# A non-negative integer epoch (seconds). Rejects empty, signs, decimals, and any
# non-digit so a malformed --now can never produce an arithmetic error or a
# silently-wrong age while the command still exits 0.
valid_epoch() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# The closed set of assessment dispositions. A value outside this set is
# malformed and is refused before it can reach a record, coverage, or closure.
valid_disposition() {
  case "${1:-}" in
    handled-in-run|linked-existing-repair|bounded-owner-task|\
    accepted-deferred-with-authority|no-actionable-anomaly|coverage-unperformed) return 0 ;;
    *) return 1 ;;
  esac
}

# --- record I/O (obligation is READ-only here; assessment is ours) ----------

obligation_path() { printf '%s/%s.nm-observe\n' "$STATE" "$1"; }
assessment_path() { printf '%s/%s.nm-assessment\n' "$STATE" "$1"; }
receipt_path() { printf '%s/%s/nm-assessment-receipt.md\n' "$DATA" "$1"; }
lock_path() { printf '%s/.nm-assess-%s.lock\n' "$STATE" "$1"; }
meta_path() { printf '%s/%s.meta\n' "$STATE" "$1"; }

record_get() {  # <record> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Replace or append key=value pairs in <record> atomically.
record_set() {  # <record> <key=value>...
  local record=$1 tmp kv key
  shift
  tmp="$record.tmp.$$"
  if [ -f "$record" ]; then cp -- "$record" "$tmp"; else : > "$tmp"; fi
  for kv in "$@"; do
    key=${kv%%=*}
    grep -v "^$key=" "$tmp" > "$tmp.next" 2>/dev/null || true
    printf '%s\n' "$kv" >> "$tmp.next"
    mv -f -- "$tmp.next" "$tmp"
  done
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$record"
}

with_lock() {  # <lock> <fn> [args...]
  local lock=$1 rc=0
  shift
  fm_lock_acquire_wait "$lock"
  "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

nm_available() { command -v no-mistakes >/dev/null 2>&1; }

task_worktree() {  # <meta>
  local wt
  wt=$(fm_meta_get "$1" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] && printf '%s' "$wt" || true
}

task_dir() {  # <meta> -> worktree when it exists, else project, else empty
  local wt proj
  wt=$(fm_meta_get "$1" worktree)
  proj=$(fm_meta_get "$1" project)
  if [ -n "$wt" ] && [ -d "$wt" ]; then printf '%s' "$wt"
  elif [ -n "$proj" ] && [ -d "$proj" ]; then printf '%s' "$proj"
  fi
}

run_field() {  # <toon> <key>
  fm_nm_strip_quotes "$(fm_nm_field "$1" "$2")"
}

# The PR identity carried by the merge-notification marker bin/fm-pr-lib.sh
# writes: the version tag on line 1, then provider, host, path, and number.
# This is provider/canonical state (the PR poll owner sourced it from the
# forge REST API), so it outranks any cached pr field a run record carries.
merge_marker_identity() {  # <marker> -> provider:host:path:number
  local version provider host path number extra
  { IFS= read -r version && IFS= read -r provider && IFS= read -r host \
      && IFS= read -r path && IFS= read -r number && ! IFS= read -r extra; } < "$1" || return 1
  [ "$version" = fm-pr-poll-merge-notified-v1 ] && [ -n "$provider" ] && [ -n "$host" ] \
    && [ -n "$path" ] && [ -n "$number" ] || return 1
  printf '%s:%s:%s:%s' "$provider" "$host" "$path" "$number"
}

# --- finding families -------------------------------------------------------

# Owner task that already owns a repair for a failure family, or empty when the
# failure family has no standing owner and the finding must carry its own.
route_owner_for_family() {  # <failure-family>
  case "$1" in
    provider-capacity) printf 'nmf-provider-capacity-typed-condition' ;;
    check-normalization) printf 'nmf-observer-check-normalization' ;;
    *) printf '' ;;
  esac
}

# The next gate / closure predicate a routed family carries.
next_gate_for_family() {  # <failure-family>
  case "$1" in
    provider-capacity) printf 'upstream pinned-tool candidate -> qualification -> adoption; observer observes/classifies/routes only, never repairs pinned internals' ;;
    check-normalization) printf 'investigate the actual source/interpretation, then repair check normalization with regression fixtures (failed prior attempt + running rerun on the same head, omitted rows, completed+failure, completed+cancelled, null conclusion)' ;;
    *) printf 'file the bounded owner task with reproduction, invariant, sibling scope, acceptance, and the next gate' ;;
  esac
}

# Deterministic family key from the four dedup dimensions.
family_key() {  # <owner> <invariant> <failure-family> <applicability>
  local sum
  sum=$(printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4" | cksum | awk '{print $1}')
  printf '%s-%s' "$3" "$sum"
}

family_file() { printf '%s/%s\n' "$FAMILIES_DIR" "$1"; }

# Attach one occurrence to a family, creating the family header on first sight.
# Occurrence identity is task|run|transition|head: re-assessing the identical
# occurrence replaces its line in place, while a distinct task, run, transition,
# OR head revision is always a new line, so a material candidate/head/evidence
# revision preserves the prior occurrence and history is immutable across head
# revisions. Runs under the family lock (held by the caller).
family_attach() {  # <key> <owner> <invariant> <family> <applicability> <next-gate>
                   #   <task> <run> <head> <completed-repair> <usage-cost>
                   #   <disposition> <detail>
  local key=$1 owner=$2 invariant=$3 family=$4 applicability=$5 next_gate=$6
  local task=$7 run=$8 head=$9 completed=${10} usage=${11} disp=${12} detail=${13}
  local file line occ tmp
  mkdir -p "$FAMILIES_DIR"
  file=$(family_file "$key")
  if [ ! -f "$file" ]; then
    {
      printf 'record=%s\n' "$FAMILY_SCHEMA"
      printf 'family_key=%s\n' "$key"
      printf 'owner=%s\n' "$owner"
      printf 'invariant=%s\n' "$invariant"
      printf 'failure_family=%s\n' "$family"
      printf 'applicability=%s\n' "$applicability"
      printf 'first_epoch=%s\n' "$(now_epoch)"
      printf 'next_gate=%s\n' "$next_gate"
      printf '# occurrences: occurrence<TAB>epoch<TAB>task<TAB>run<TAB>head<TAB>completed_repair<TAB>usage_cost<TAB>disposition<TAB>detail\n'
    } > "$file"
    chmod 0600 "$file"
  fi
  occ=$(printf 'occurrence\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(now_epoch)" "$task" "$run" "$head" "$completed" "$usage" "$disp" "$detail")
  tmp="$file.tmp.$$"
  # Drop any prior occurrence with the same task|run|transition|head (transition
  # is folded into <detail>'s leading token by the caller), then append the fresh
  # one. The occurrence identity match is on task+run+head+the transition prefix,
  # so the same task/run/transition at a DISTINCT head is a new occurrence and the
  # earlier head's line is preserved, never overwritten.
  awk -F '\t' -v t="$task" -v r="$run" -v h="$head" -v d="$detail" '
    $1 == "occurrence" && $3 == t && $4 == r && $5 == h {
      split(d, want, ":"); split($9, have, ":")
      if (want[1] == have[1]) next
    }
    { print }
  ' "$file" > "$tmp"
  printf '%s\n' "$occ" >> "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$file"
}

# --- assess -----------------------------------------------------------------

# The executed/never-started derivation names a no-mistakes ship run's ordered
# steps (review, test, document, lint, push, pr, ci) when the caller does not.
derive_executed() {  # <outcome-class>
  case "$1" in
    successful) printf 'review,test,document,lint,push,pr,ci' ;;
    ci-ready) printf 'review,test,document,lint,push,pr' ;;
    active) printf 'in progress' ;;
    failed) printf 'up to the failing step' ;;
    cancelled) printf 'up to cancellation' ;;
    preflight-refused|'') printf 'none' ;;
    *) printf 'unknown' ;;
  esac
}

derive_never_started() {  # <outcome-class> <provider-capacity>
  if [ -n "$2" ]; then
    printf 'the CI fixer repair (invoked but no completed repair)'
    return 0
  fi
  case "$1" in
    successful) printf 'none' ;;
    ci-ready) printf 'ci' ;;
    preflight-refused|'') printf 'the pipeline (no run created)' ;;
    *) printf 'unknown' ;;
  esac
}

transition_for_class() {  # <outcome-class> <provider-capacity>
  [ -z "$2" ] || { printf 'stall'; return 0; }
  case "$1" in
    successful) printf 'terminal' ;;
    ci-ready) printf 'ci-ready' ;;
    failed) printf 'failure' ;;
    cancelled) printf 'terminal' ;;
    active) printf 'routine' ;;
    preflight-refused) printf 'failure' ;;
    *) printf 'routine' ;;
  esac
}

# True when <token> appears in a comma-separated <csv> (whitespace tolerated).
token_in_csv() {  # <token> <csv>
  local tok=$1 csv=$2 item IFS=,
  for item in $csv; do
    item=${item# }; item=${item% }
    [ "$item" = "$tok" ] && return 0
  done
  return 1
}

# Fill IMMEDIATE and ABOVE globals plus the finding/disposition state.
do_assess() {  # many positional args, see dispatch
  local id=$1 transition=$2 no_query=$3 provider=$4 attempts=$5 usage=$6 gate=$7
  local carried=$8 executed=$9 never=${10} next_owner=${11} disp=${12} authority=${13}
  local supersede=${14} cov_perf=${15}
  shift 15
  local -a findings=("$@")
  local obl meta record dir wt run class status outcome head branch nm_ver nm_build daemon
  local pr publication run_pr cached_pr reconciled toon epoch
  local prior_carried='' prior_provider='' prior_prov_attempts='' prior_prov_cost='' prior_gate_paused=''
  local -a prior_findings=()
  obl=$(obligation_path "$id")
  [ -f "$obl" ] && [ ! -L "$obl" ] || { echo "error: NOT_ENROLLED task=$id: no observation obligation ($obl); run bin/fm-nm-observe.sh enrol $id first" >&2; exit 1; }
  [ "$(record_get "$obl" record)" = "$OBLIGATION_SCHEMA" ] || { echo "error: unreadable observation obligation for $id ($obl)" >&2; exit 2; }
  meta=$(meta_path "$id")
  record=$(assessment_path "$id")
  dir=$([ -f "$meta" ] && task_dir "$meta" || true)
  wt=$([ -f "$meta" ] && task_worktree "$meta" || true)

  run=$(record_get "$obl" run_id)
  class=$(record_get "$obl" outcome_class)
  status=$(record_get "$obl" run_status)
  outcome=$(record_get "$obl" run_outcome)
  head=$(record_get "$obl" run_head)
  branch=$(record_get "$obl" candidate_branch)
  nm_ver=$(record_get "$obl" nm_version)
  nm_build=$(record_get "$obl" nm_build)
  daemon=$(record_get "$obl" daemon_epoch)
  pr=$(record_get "$obl" pr)
  publication=$(record_get "$obl" publication)

  # Carry-forward base. An ordinary refresh must PRESERVE the carried residual
  # finding, the provider-capacity block, and every recorded finding family;
  # only a typed --supersede closes them. Read the prior assessment before it is
  # overwritten below.
  if [ -f "$record" ] && [ "$(record_get "$record" record)" = "$ASSESS_SCHEMA" ]; then
    prior_carried=$(record_get "$record" imm_carried_finding)
    prior_provider=$(record_get "$record" provider_capacity)
    prior_prov_attempts=$(record_get "$record" provider_attempts)
    prior_prov_cost=$(record_get "$record" provider_usage_cost)
    prior_gate_paused=$(record_get "$record" gate_paused)
    local _pfc _pi
    _pfc=$(record_get "$record" finding_count)
    case "$_pfc" in ''|*[!0-9]*) _pfc=0 ;; esac
    _pi=0
    while [ "$_pi" -lt "$_pfc" ]; do
      prior_findings+=("$(record_get "$record" "finding.$_pi")")
      _pi=$((_pi + 1))
    done
  fi

  # One read-only canonical read of the bound run, unless suppressed. It refreshes
  # the daemon's own cached view (status/outcome/head and its cached pr ref) so a
  # late merge is reconciled against provider/canonical state below, never against
  # a stale cached run record.
  epoch=
  run_pr=
  if [ -n "$run" ] && [ "$no_query" -eq 0 ] && [ -n "$dir" ] && nm_available; then
    if toon=$(fm_nm_run_checked "$dir" "$CALL_TIMEOUT" axi status --run "$run"); then
      if [ "$(run_field "$toon" id)" = "$run" ]; then
        status=$(run_field "$toon" status)
        outcome=$(run_field "$toon" outcome)
        head=$(run_field "$toon" head)
        run_pr=$(run_field "$toon" pr)
        class=$(outcome_class_of "$status" "$outcome")
        epoch=$(now_epoch)
      fi
    fi
  fi
  [ -z "$run_pr" ] && run_pr=$pr

  # Late-merge reconciliation. The merge-notification marker is provider/canonical
  # truth; a run record's cached pr can still read OPEN after a merge (PR #12).
  reconciled=$publication
  local marker ident
  marker="$STATE/$id.pr-poll-merge-notified"
  if [ -z "$reconciled" ] && [ -f "$marker" ] && [ ! -L "$marker" ]; then
    ident=$(merge_marker_identity "$marker") && reconciled="merged:$ident"
  fi
  cached_pr=
  if [ -n "$reconciled" ]; then
    # The run's own view of the PR, kept only as the cached (untrusted) datum.
    cached_pr=${run_pr:-none}
  fi

  # Provider-capacity: a typed external resource-blocked condition, DISTINCT from
  # a candidate repair. Real invocation attempts are preserved; completed repair
  # is false; usage/cost is UNKNOWN unless measured (never fabricated to zero);
  # the affected gate is PAUSED while independent eligible work continues. A fresh
  # --provider-capacity computes the block from its flags and raises the finding;
  # otherwise a prior block is carried forward unchanged unless --supersede
  # provider closed it, so an ordinary refresh never drops it.
  local gate_paused='' prov_attempts=0 prov_cost=unknown
  if [ -n "$provider" ]; then
    gate_paused=${gate:-ci}
    prov_attempts=${attempts:-0}
    prov_cost=${usage:-unknown}
    [ -n "$prov_cost" ] || prov_cost=unknown
    if awk -v v="$prov_cost" 'BEGIN{ if (v ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)$/ && v+0==0) exit 0; exit 1 }'; then
      prov_cost=unknown
    fi
    findings+=("$(route_owner_for_family provider-capacity):provider-capacity-is-not-a-candidate-repair:provider-capacity:profile=${nm_ver:-unobserved}/${nm_build:-unobserved}")
  elif [ -n "$prior_provider" ] && ! token_in_csv provider "$supersede"; then
    # Carry the prior block forward verbatim; its finding line rides along in
    # prior_findings, so it is not re-appended here.
    provider=$prior_provider
    gate_paused=$prior_gate_paused
    prov_attempts=${prior_prov_attempts:-0}
    prov_cost=${prior_prov_cost:-unknown}
  fi

  # CI-ready needs source-applicable evidence: the effective canonical outcome
  # must be checks-passed. ci-ready is NEVER inferred from an absent, empty, or
  # merely normalized outcome_class. Without the evidence the transition is
  # ci-ready-unverified and a check-normalization finding is raised, so no clean
  # CI-ready is ever claimed.
  local ci_unverified=0
  if [ "$class" = ci-ready ] && [ "$outcome" != checks-passed ]; then
    ci_unverified=1
    findings+=("$(route_owner_for_family check-normalization):ci-ready-requires-source-applicable-ci-evidence:check-normalization:profile=${nm_ver:-unobserved}/${nm_build:-unobserved}")
  fi

  # Compute the transition when the caller left it to us. An unverified ci-ready
  # is never derived as a clean ci-ready transition.
  if [ -z "$transition" ]; then
    if [ "$ci_unverified" -eq 1 ] && [ -z "$provider" ]; then
      transition=ci-ready-unverified
    else
      transition=$(transition_for_class "$class" "$provider")
    fi
  fi
  if [ "$ci_unverified" -eq 1 ] && [ -z "$provider" ]; then
    [ -n "$executed" ] || executed='unknown (ci-ready claimed without source-applicable CI evidence)'
    [ -n "$never" ] || never='ci (no source-applicable evidence CI started or completed)'
  else
    [ -n "$executed" ] || executed=$(derive_executed "$class")
    [ -n "$never" ] || never=$(derive_never_started "$class" "$provider")
  fi

  # Immediate defect / blocked condition.
  local imm_defect
  if [ -n "$provider" ]; then
    imm_defect="provider-capacity block at gate ${gate_paused} ($provider): a typed external resource-blocked condition, not a candidate repair and not a candidate failure; $prov_attempts invocation attempt(s), no completed repair"
  elif [ "$ci_unverified" -eq 1 ]; then
    imm_defect="ci-ready claimed without source-applicable CI evidence: outcome=${outcome:-none}, status=${status:-none}; ci-ready must be backed by a checks-passed canonical verdict, never inferred from an absent or normalized state"
  else
    case "$class" in
      failed) imm_defect="run failed: canonical status $status outcome $outcome" ;;
      cancelled) imm_defect="run cancelled: canonical status $status" ;;
      preflight-refused) imm_defect="launch refused before any run: $(record_get "$obl" preflight_refusal)" ;;
      *) imm_defect=none ;;
    esac
  fi

  # Next exact owner / gate.
  local imm_next
  if [ -n "$next_owner" ]; then
    imm_next=$next_owner
  elif [ -n "$provider" ]; then
    imm_next="the affected gate stays paused and predecessor-linked until capacity returns; the owning worker consumes the gate normally once it does; the pinned-tool fix is owned by $(route_owner_for_family provider-capacity)"
  elif [ "$ci_unverified" -eq 1 ]; then
    imm_next="$(route_owner_for_family check-normalization) must confirm the source-applicable CI verdict before ci-ready is claimed; no CI gate is treated as consumed on absent or normalized state"
  else
    case "$class" in
      ci-ready) imm_next="the owning worker consumes the exact-head CI gate, with explicit disposition of any carried defect (a green rerun does not close a carried finding)" ;;
      successful) imm_next="the guarded-landing owner (bin/fm-pr-merge.sh) under its existing merge authority; validated is not landed" ;;
      failed|cancelled) imm_next="the owning worker follows the active gate help; recovery uses the existing owner" ;;
      *) imm_next="the owning worker continues the pipeline through its next gate" ;;
    esac
  fi

  # Merge findings. An ordinary refresh carries every prior finding forward
  # (dropping only the family keys named in --supersede); a fresh finding with
  # the same family key replaces its prior line. Entries are the stored pipe form
  # fkey|owner|invariant|family|applicability|fdisp.
  local -a merged=()
  local m owner invariant family applicability fdisp fkey mk found j mfam
  for m in ${prior_findings[@]+"${prior_findings[@]}"}; do
    [ -n "$m" ] || continue
    fkey=${m%%|*}
    token_in_csv "$fkey" "$supersede" && continue
    # --supersede provider closes the whole provider-capacity block, so its
    # carried finding line is dropped along with the block state above.
    mfam=$(printf '%s\n' "$m" | cut -d'|' -f4)
    [ "$mfam" = provider-capacity ] && token_in_csv provider "$supersede" && continue
    merged+=("$m")
  done
  for m in ${findings[@]+"${findings[@]}"}; do
    IFS=: read -r owner invariant family applicability <<EOF2
$m
EOF2
    [ -n "$owner" ] || owner=unassigned
    [ -n "$applicability" ] || applicability="profile=${nm_ver:-unobserved}/${nm_build:-unobserved}"
    if [ "$owner" = unassigned ]; then
      fdisp=bounded-owner-task
    elif [ "$family" = provider-capacity ] || [ "$family" = check-normalization ]; then
      fdisp=linked-existing-repair
    elif [ -n "$authority" ]; then
      fdisp=accepted-deferred-with-authority
    else
      fdisp=linked-existing-repair
    fi
    fkey=$(family_key "$owner" "$invariant" "$family" "$applicability")
    # Replace a prior line with the same family key, else append.
    found=0
    j=0
    while [ "$j" -lt "${#merged[@]}" ]; do
      mk=${merged[$j]%%|*}
      if [ "$mk" = "$fkey" ]; then
        merged[j]="$fkey|$owner|$invariant|$family|$applicability|$fdisp"
        found=1
        break
      fi
      j=$((j + 1))
    done
    [ "$found" -eq 1 ] || merged+=("$fkey|$owner|$invariant|$family|$applicability|$fdisp")
  done

  # Resolve the carried residual. An ordinary refresh preserves it; only
  # --carried-finding replaces it and --supersede carried clears it.
  local carried_final
  if [ -n "$carried" ]; then
    carried_final=$carried
  elif token_in_csv carried "$supersede"; then
    carried_final=none
  elif [ -n "$prior_carried" ] && [ "$prior_carried" != none ]; then
    carried_final=$prior_carried
  else
    carried_final=none
  fi

  # Coverage performed vs UNPERFORMED. Recording that an assessment exists is not
  # an investigation: coverage counts as performed only when a canonical read
  # actually ran, findings/provider/carried state were ingested or carried, or
  # --coverage-performed asserts a clean investigation.
  local performed=0
  [ -n "$epoch" ] && performed=1
  [ "${#merged[@]}" -gt 0 ] && performed=1
  [ "$carried_final" != none ] && performed=1
  [ -n "$supersede" ] && performed=1
  [ "$cov_perf" -eq 1 ] && performed=1

  # Immediate state label. An unverified ci-ready is never reported as clean.
  local state_label
  if [ "$ci_unverified" -eq 1 ] && [ -z "$provider" ]; then
    state_label=ci-ready-unverified
  else
    state_label=${class:-unread}
  fi

  # One owner level above, derived from what the merged findings expose and
  # whether coverage was actually performed.
  local above_owner above_siblings above_reason
  if [ "$performed" -eq 0 ]; then
    above_owner="coverage UNPERFORMED: an assessment record exists but no investigation ran (no canonical read, no ingested or carried findings); existence is not investigation"
    above_siblings=none
    above_reason="the default/hook path recorded existence only; it does not prove the run clean and must be re-assessed with an actual canonical read or ingested findings"
  elif [ "${#merged[@]}" -eq 0 ]; then
    above_owner="no anomaly within measured coverage"
    above_siblings=none
    above_reason="the canonical read exposed no defect and no avoidable work; a clean assessment does not prove the architecture defect-free"
  elif [ -n "$provider" ]; then
    above_owner="the no-mistakes CI caller and provider adapter (pinned-tool internal): source-applicable gate readiness must survive primary interruption/recovery; failed provider attempts stay durable and predecessor-linked; resource retry/accounting is budgeted separately from candidate repair attempts"
    above_siblings="every gate whose fixer invokes the same provider adapter; deduplicated as one family across occurrences"
    above_reason="no automatic paid fallback, provider/model substitution, new spend, global restart, or new watcher; FirstMate observes/classifies/routes only"
  else
    above_owner="the caller/lifecycle/shared-contract the routed finding names"
    above_siblings="the sibling consumers of that contract (see the finding family)"
    above_reason=
  fi

  # Overall disposition. Unperformed coverage is disposed coverage-unperformed
  # rather than a manufactured clean no-actionable-anomaly. A finding whose owner
  # field is unassigned must be filed as a bounded owner task; a finding routed to
  # a standing owner links an existing repair.
  local have_unassigned=0 fscan fowner
  for fscan in ${merged[@]+"${merged[@]}"}; do
    fscan=${fscan#*|}
    fowner=${fscan%%|*}
    { [ -z "$fowner" ] || [ "$fowner" = unassigned ]; } && have_unassigned=1
  done
  if [ -z "$disp" ]; then
    if [ "$performed" -eq 0 ]; then
      disp=coverage-unperformed
    elif [ "${#merged[@]}" -eq 0 ]; then
      disp=no-actionable-anomaly
    elif [ -n "$authority" ]; then
      disp=accepted-deferred-with-authority
    elif [ "$have_unassigned" -eq 1 ]; then
      disp=bounded-owner-task
    else
      disp=linked-existing-repair
    fi
  fi

  # Persist the assessment record.
  mkdir -p "$STATE"
  : > "$record.tmp.$$"
  {
    printf 'record=%s\n' "$ASSESS_SCHEMA"
    printf 'task=%s\n' "$id"
    printf 'assessed_epoch=%s\n' "$(now_epoch)"
    printf 'assessed_iso=%s\n' "$(now_iso)"
    printf 'transition=%s\n' "$transition"
    printf 'imm_run=%s\n' "$run"
    printf 'imm_branch=%s\n' "$branch"
    printf 'imm_head=%s\n' "$head"
    printf 'imm_gate=%s\n' "${status:-none}"
    printf 'imm_state=%s\n' "$state_label"
    printf 'imm_defect=%s\n' "$imm_defect"
    printf 'imm_executed=%s\n' "$executed"
    printf 'imm_never_started=%s\n' "$never"
    printf 'imm_carried_finding=%s\n' "$carried_final"
    printf 'imm_next_owner=%s\n' "$imm_next"
    printf 'above_owner=%s\n' "$above_owner"
    printf 'above_siblings=%s\n' "$above_siblings"
    printf 'above_reason=%s\n' "$above_reason"
    printf 'coverage_performed=%s\n' "$([ "$performed" -eq 1 ] && printf yes || printf no)"
    printf 'ci_ready_unverified=%s\n' "$([ "$ci_unverified" -eq 1 ] && printf yes || printf no)"
    printf 'superseded=%s\n' "${supersede:-none}"
    printf 'provider_capacity=%s\n' "$provider"
    printf 'provider_attempts=%s\n' "$prov_attempts"
    printf 'provider_completed_repair=%s\n' "$([ -n "$provider" ] && printf false || printf 'n/a')"
    printf 'provider_usage_cost=%s\n' "$prov_cost"
    printf 'gate_paused=%s\n' "$gate_paused"
    printf 'cached_pr_state=%s\n' "$cached_pr"
    printf 'reconciled_publication=%s\n' "$reconciled"
    printf 'accepted_authority=%s\n' "$authority"
    printf 'last_poll_epoch=%s\n' "${epoch:-$(record_get "$obl" outcome_epoch)}"
    printf 'last_material_epoch=%s\n' "$(record_get "$obl" outcome_epoch)"
    printf 'last_handled_epoch=%s\n' "$(now_epoch)"
    printf 'runtime_generation=%s\n' "${daemon:-unobserved}"
    printf 'disposition=%s\n' "$disp"
  } >> "$record.tmp.$$"

  # Findings: record each merged finding and attach it to its family under the
  # family lock. Occurrence identity includes the head, so a distinct head keeps
  # the prior occurrence rather than overwriting it.
  local i=0
  for m in ${merged[@]+"${merged[@]}"}; do
    IFS='|' read -r fkey owner invariant family applicability fdisp <<EOF3
$m
EOF3
    printf 'finding.%s=%s|%s|%s|%s|%s|%s\n' "$i" "$fkey" "$owner" "$invariant" "$family" "$applicability" "$fdisp" >> "$record.tmp.$$"
    with_lock "$FAMILIES_LOCK" family_attach "$fkey" "$owner" "$invariant" "$family" "$applicability" \
      "$(next_gate_for_family "$family")" "$id" "${run:-none}" "${head:-none}" \
      "$([ "$family" = provider-capacity ] && printf false || printf 'n/a')" \
      "$([ "$family" = provider-capacity ] && printf '%s' "$prov_cost" || printf 'n/a')" \
      "$fdisp" "$transition: $invariant"
    i=$((i + 1))
  done
  printf 'finding_count=%s\n' "$i" >> "$record.tmp.$$"
  chmod 0600 "$record.tmp.$$"
  mv -f -- "$record.tmp.$$" "$record"

  render_receipt "$id"
  printf 'NM_ASSESS: ASSESSED task=%s transition=%s state=%s findings=%s disposition=%s\n' \
    "$id" "$transition" "$state_label" "$i" "$disp"
}

outcome_class_of() {  # <status> <outcome> (mirror of the obligation owner's map)
  local status=$1 outcome=$2
  case "$outcome" in
    passed) printf 'successful'; return 0 ;;
    checks-passed) printf 'ci-ready'; return 0 ;;
    failed) printf 'failed'; return 0 ;;
    cancelled) printf 'cancelled'; return 0 ;;
  esac
  case "$status" in
    completed) printf 'successful' ;;
    failed) printf 'failed' ;;
    cancelled) printf 'cancelled' ;;
    *) printf 'active' ;;
  esac
}

# --- receipt ----------------------------------------------------------------

render_receipt() {  # <task-id>
  local id=$1 record obl dir out tmp i fc
  record=$(assessment_path "$id")
  [ -f "$record" ] || return 0
  obl=$(obligation_path "$id")
  dir="$DATA/$id"
  mkdir -p "$dir"
  out=$(receipt_path "$id")
  tmp="$out.tmp.$$"
  fc=$(record_get "$record" finding_count)
  {
    printf '# no-mistakes per-run assessment: %s\n\n' "$id"
    printf 'Rendered %s by bin/fm-nm-assess.sh from state/%s.nm-assessment (%s).\n' "$(now_iso)" "$id" "$ASSESS_SCHEMA"
    printf 'This assessment observes, classifies, and routes; it grants nothing, approves no gate, and is not a run outcome.\n\n'

    printf '## Identity\n\n'
    printf -- '- home: %s\n' "$(record_get "$obl" home)"
    printf -- '- project: %s\n' "$(record_get "$obl" project)"
    printf -- '- repository remote: %s\n' "$(record_get "$obl" repo_remote)"
    printf -- '- launch attempt: %s (predecessor attempt %s, predecessor run %s)\n' \
      "$(record_get "$obl" attempt_id)" "$(record_get "$obl" predecessor_attempt_id)" "$(record_get "$obl" predecessor_run_id)"
    printf -- '- run: %s (branch %s, head %s)\n' "$(record_get "$record" imm_run)" "$(record_get "$record" imm_branch)" "$(record_get "$record" imm_head)"
    printf -- '- runtime profile: no-mistakes %s build %s\n' "$(record_get "$obl" nm_version)" "$(record_get "$obl" nm_build)"
    printf -- '- transition: %s\n\n' "$(record_get "$record" transition)"

    printf '## Immediate boundary\n\n'
    printf -- '- gate / canonical state: %s / %s\n' "$(record_get "$record" imm_gate)" "$(record_get "$record" imm_state)"
    printf -- '- defect or blocked condition: %s\n' "$(record_get "$record" imm_defect)"
    printf -- '- work executed: %s\n' "$(record_get "$record" imm_executed)"
    printf -- '- work never started: %s\n' "$(record_get "$record" imm_never_started)"
    printf -- '- carried residual finding: %s\n' "$(record_get "$record" imm_carried_finding)"
    printf -- '- next exact owner / gate: %s\n\n' "$(record_get "$record" imm_next_owner)"

    printf '## One owner level above\n\n'
    printf -- '- owner / contract: %s\n' "$(record_get "$record" above_owner)"
    printf -- '- sibling consumers checked: %s\n' "$(record_get "$record" above_siblings)"
    [ -z "$(record_get "$record" above_reason)" ] || printf -- '- reason broader repair is unnecessary here: %s\n' "$(record_get "$record" above_reason)"
    printf '\n'

    if [ -n "$(record_get "$record" provider_capacity)" ]; then
      printf '## Provider-capacity (typed external resource-blocked condition)\n\n'
      printf -- '- condition: %s\n' "$(record_get "$record" provider_capacity)"
      printf -- '- real invocation attempts (no completed repair): %s\n' "$(record_get "$record" provider_attempts)"
      printf -- '- completed repair: %s\n' "$(record_get "$record" provider_completed_repair)"
      printf -- '- usage/cost: %s (UNKNOWN is never fabricated to zero)\n' "$(record_get "$record" provider_usage_cost)"
      printf -- '- gate paused: %s (independent eligible work continues; readiness survives interruption/recovery)\n' "$(record_get "$record" gate_paused)"
      printf -- '- budget: separate from candidate repair-attempt budgets\n\n'
    fi

    if [ -n "$(record_get "$record" reconciled_publication)" ]; then
      printf '## Late-merge reconciliation\n\n'
      printf -- '- provider/canonical publication: %s\n' "$(record_get "$record" reconciled_publication)"
      printf -- '- cached run pr (untrusted, not authoritative): %s\n' "$(record_get "$record" cached_pr_state)"
      printf -- '- terminal outcome is taken from the provider/canonical state, never the stale cached run record\n\n'
    fi

    printf '## Findings and dispositions\n\n'
    if [ "${fc:-0}" -eq 0 ]; then
      if [ "$(record_get "$record" coverage_performed)" = no ]; then
        printf -- '- coverage UNPERFORMED: existence recorded without an investigation; findings not ingested; disposition: coverage-unperformed\n'
      else
        printf -- '- none within measured coverage; disposition: no-actionable-anomaly\n'
      fi
    else
      i=0
      while [ "$i" -lt "$fc" ]; do
        printf -- '- %s\n' "$(record_get "$record" "finding.$i")"
        i=$((i + 1))
      done
    fi
    [ "$(record_get "$record" superseded)" = none ] || printf -- '- typed-closed (superseded) this refresh: %s\n' "$(record_get "$record" superseded)"
    printf -- '- carried residual finding: %s (carried by identity across refresh unless typed-closed)\n' "$(record_get "$record" imm_carried_finding)"
    printf -- '- overall disposition: %s\n' "$(record_get "$record" disposition)"
    [ -z "$(record_get "$record" accepted_authority)" ] || printf -- '- accepted/deferred authority: %s\n' "$(record_get "$record" accepted_authority)"
    printf '\n'

    if [ "$(record_get "$record" ci_ready_unverified)" = yes ]; then
      printf '## CI-ready evidence (unverified)\n\n'
      printf -- '- ci-ready was NOT claimed: no source-applicable checks-passed verdict; ci-ready is never inferred from an absent or normalized state\n'
      printf -- '- %s\n\n' "$(record_get "$record" imm_defect)"
    fi

    printf '## Coverage and freshness\n\n'
    printf -- '- coverage performed: %s (recording existence is not investigation)\n' "$(record_get "$record" coverage_performed)"
    printf -- '- last successful canonical read: %s\n' "$(record_get "$record" last_poll_epoch)"
    printf -- '- last material event: %s\n' "$(record_get "$record" last_material_epoch)"
    printf -- '- last handled/acknowledged: %s\n' "$(record_get "$record" last_handled_epoch)"
    printf -- '- current runtime/session generation (daemon): %s\n' "$(record_get "$record" runtime_generation)"
    printf -- '- captured eval cases are review evidence, never launch coverage, and are not counted here\n'
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$out"
}

# --- families ---------------------------------------------------------------

do_families() {  # <task-id-or-empty>
  local want=$1 file key any=0
  [ -d "$FAMILIES_DIR" ] || { printf 'NM_ASSESS: no finding families recorded\n'; return 0; }
  for file in "$FAMILIES_DIR"/*; do
    [ -f "$file" ] || continue
    [ "$(record_get "$file" record)" = "$FAMILY_SCHEMA" ] || continue
    if [ -n "$want" ]; then
      grep -q "$(printf '\t%s\t' "$want")" "$file" || continue
    fi
    any=1
    key=$(record_get "$file" family_key)
    printf 'NM_ASSESS: FAMILY key=%s owner=%s invariant=%s failure_family=%s applicability=%s next_gate=%s\n' \
      "$key" "$(record_get "$file" owner)" "$(record_get "$file" invariant)" \
      "$(record_get "$file" failure_family)" "$(record_get "$file" applicability)" "$(record_get "$file" next_gate)"
    awk -F '\t' '$1 == "occurrence" {
      printf "  occurrence epoch=%s task=%s run=%s head=%s completed_repair=%s usage_cost=%s disposition=%s detail=%s\n", $2, $3, $4, $5, $6, $7, $8, $9
    }' "$file"
  done
  [ "$any" -eq 1 ] || printf 'NM_ASSESS: no finding families recorded\n'
  return 0
}

# --- coverage enforcement ---------------------------------------------------

# Mechanically enforce three invariants across the home and print one typed
# line per gap: every admitted launch has an observation-or-error; every
# assessment has a disposition; every finding family (remediation) has an owner
# and a next gate. Read-only; prints nothing when everything holds.
do_coverage() {  # <now-epoch-or-empty>
  local now=$1 obl id stage class preflight record disp file owner gate any=0
  now=${now:-$(now_epoch)}
  for obl in "$STATE"/*.nm-observe; do
    [ -f "$obl" ] || continue
    [ "$(record_get "$obl" record)" = "$OBLIGATION_SCHEMA" ] || continue
    id=$(basename "$obl" .nm-observe)
    stage=$(record_get "$obl" stage)
    class=$(record_get "$obl" outcome_class)
    preflight=$(record_get "$obl" preflight_refusal)
    case "$stage" in
      launch-accepted|run-bound|finalized)
        if [ -z "$class" ] && [ -z "$preflight" ]; then
          printf 'NM_ASSESS: COVERAGE_GAP task=%s reason=admitted launch has no observation or explicit pending/error state (heal: bin/fm-nm-observe.sh refresh %s)\n' "$id" "$id"
          any=1
        fi ;;
    esac
    # An admitted launch past run-bound should carry an assessment with a disposition.
    record=$(assessment_path "$id")
    if [ "$stage" = run-bound ] || [ "$stage" = finalized ]; then
      if [ ! -f "$record" ]; then
        printf 'NM_ASSESS: COVERAGE_GAP task=%s reason=bound run has no assessment (heal: bin/fm-nm-assess.sh assess %s)\n' "$id" "$id"
        any=1
      fi
    fi
  done
  for record in "$STATE"/*.nm-assessment; do
    [ -f "$record" ] || continue
    [ "$(record_get "$record" record)" = "$ASSESS_SCHEMA" ] || continue
    id=$(basename "$record" .nm-assessment)
    disp=$(record_get "$record" disposition)
    if [ -z "$disp" ]; then
      printf 'NM_ASSESS: COVERAGE_GAP task=%s reason=assessment has no disposition (heal: bin/fm-nm-assess.sh assess %s)\n' "$id" "$id"
      any=1
    elif ! valid_disposition "$disp"; then
      printf 'NM_ASSESS: COVERAGE_GAP task=%s reason=assessment has a malformed disposition (%s) outside the defined set (heal: bin/fm-nm-assess.sh assess %s --disposition <valid>)\n' "$id" "$disp" "$id"
      any=1
    fi
  done
  if [ -d "$FAMILIES_DIR" ]; then
    for file in "$FAMILIES_DIR"/*; do
      [ -f "$file" ] || continue
      [ "$(record_get "$file" record)" = "$FAMILY_SCHEMA" ] || continue
      owner=$(record_get "$file" owner)
      gate=$(record_get "$file" next_gate)
      if [ -z "$owner" ] || [ "$owner" = unassigned ] || [ -z "$gate" ]; then
        printf 'NM_ASSESS: COVERAGE_GAP family=%s reason=remediation has no %s (file the bounded owner task with an owner and next gate)\n' \
          "$(record_get "$file" family_key)" "$([ -z "$gate" ] && printf 'next gate' || printf 'owner')"
        any=1
      fi
    done
  fi
  # Freshness dimension: additive, always emitted, never part of the gap/ok
  # accounting. One line per assessment record, ages resolved against <now>.
  for record in "$STATE"/*.nm-assessment; do
    [ -f "$record" ] || continue
    [ "$(record_get "$record" record)" = "$ASSESS_SCHEMA" ] || continue
    id=$(basename "$record" .nm-assessment)
    printf 'NM_ASSESS: FRESHNESS task=%s now=%s last_poll_age=%s last_event_age=%s last_handled_age=%s generation=%s\n' \
      "$id" "$now" \
      "$(age_of "$now" "$(record_get "$record" last_poll_epoch)")" \
      "$(age_of "$now" "$(record_get "$record" last_material_epoch)")" \
      "$(age_of "$now" "$(record_get "$record" last_handled_epoch)")" \
      "$(record_get "$record" runtime_generation)"
  done
  [ "$any" -eq 1 ] || printf 'NM_ASSESS: COVERAGE ok (every admitted launch observed, every assessment disposed, every remediation owned)\n'
  return 0
}

# --- dispatch ---------------------------------------------------------------

[ "$#" -ge 1 ] || die_usage "a verb is required"
VERB=$1
shift
case "$VERB" in
  --help|-h|help) usage; exit 0 ;;
esac

if [ "$VERB" = coverage ]; then
  NOW=
  want=
  for a in "$@"; do
    if [ -n "$want" ]; then NOW=$a; want=; continue; fi
    case "$a" in
      --now) want=now ;;
      *) die_usage "unknown coverage flag $a" ;;
    esac
  done
  [ -z "$want" ] || die_usage "--now requires a value"
  # A malformed --now must fail typed and non-zero, never produce an arithmetic
  # error or a silently-wrong age while still exiting 0 with COVERAGE ok.
  [ -z "$NOW" ] || valid_epoch "$NOW" || die_usage "--now requires a non-negative integer epoch (got: $NOW)"
  mkdir -p "$STATE"
  do_coverage "$NOW"
  exit 0
fi

if [ "$VERB" = families ]; then
  WANT=
  want=
  for a in "$@"; do
    if [ -n "$want" ]; then WANT=$a; want=; continue; fi
    case "$a" in
      --task) want=task ;;
      *) die_usage "unknown families flag $a" ;;
    esac
  done
  [ -z "$want" ] || die_usage "--task requires a value"
  do_families "$WANT"
  exit 0
fi

[ "$#" -ge 1 ] || die_usage "$VERB requires a task id"
ID=$1
shift
valid_task_id "$ID" || die_usage "invalid task id"

TRANSITION=
NO_QUERY=0
PROVIDER=
ATTEMPTS=
USAGE=
GATE=
CARRIED=
EXECUTED=
NEVER=
NEXT_OWNER=
DISPOSITION=
AUTHORITY=
SUPERSEDE=
COV_PERF=0
FINDINGS=()
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      transition) TRANSITION=$a ;;
      provider-capacity) PROVIDER=$a ;;
      repair-attempts) ATTEMPTS=$a ;;
      usage-cost) USAGE=$a ;;
      gate) GATE=$a ;;
      finding) FINDINGS+=("$a") ;;
      carried-finding) CARRIED=$a ;;
      executed) EXECUTED=$a ;;
      never-started) NEVER=$a ;;
      next-owner) NEXT_OWNER=$a ;;
      disposition) DISPOSITION=$a ;;
      accepted-authority) AUTHORITY=$a ;;
      supersede) SUPERSEDE=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --transition) want=transition ;;
    --no-query) NO_QUERY=1 ;;
    --provider-capacity) want='provider-capacity' ;;
    --repair-attempts) want='repair-attempts' ;;
    --usage-cost) want='usage-cost' ;;
    --gate) want=gate ;;
    --finding) want=finding ;;
    --carried-finding) want='carried-finding' ;;
    --executed) want=executed ;;
    --never-started) want='never-started' ;;
    --next-owner) want='next-owner' ;;
    --disposition) want=disposition ;;
    --accepted-authority) want='accepted-authority' ;;
    --supersede) want=supersede ;;
    --coverage-performed) COV_PERF=1 ;;
    *) die_usage "unknown flag $a for $VERB" ;;
  esac
done
[ -z "$want" ] || die_usage "--$want requires a value"
# A malformed --disposition is refused before anything is recorded, so a nonsense
# value can never reach a record, coverage, or closure.
[ -z "$DISPOSITION" ] || valid_disposition "$DISPOSITION" || die_usage "invalid --disposition: $DISPOSITION (one of handled-in-run, linked-existing-repair, bounded-owner-task, accepted-deferred-with-authority, no-actionable-anomaly, coverage-unperformed)"
mkdir -p "$STATE"

case "$VERB" in
  assess)
    with_lock "$(lock_path "$ID")" do_assess "$ID" "$TRANSITION" "$NO_QUERY" "$PROVIDER" \
      "$ATTEMPTS" "$USAGE" "$GATE" "$CARRIED" "$EXECUTED" "$NEVER" "$NEXT_OWNER" \
      "$DISPOSITION" "$AUTHORITY" "$SUPERSEDE" "$COV_PERF" ${FINDINGS[@]+"${FINDINGS[@]}"} ;;
  receipt)
    [ -f "$(assessment_path "$ID")" ] || { echo "error: no assessment for $ID; run bin/fm-nm-assess.sh assess $ID" >&2; exit 2; }
    render_receipt "$ID"; printf '%s\n' "$(receipt_path "$ID")" ;;
  *) die_usage "unknown verb $VERB" ;;
esac
