# shellcheck shell=bash
# Durable completion handoffs, owned by fm-stage.
# No separate work store: one completion_handoff JSON field in the existing
# task metadata carries the admitted contract, manager release and effect receipt.
# Only fm-stage writes this field under its metadata lock.
#
# Admission: fm-stage TASK handoff --handoff-json FILE. FILE is an object:
# {schema:"fm-completion-handoff/v1",task,generation,attempt,run,candidate,source_head,
#  report:{path,sha256},action:{id,kind,owner,generation,instruction?,pr?}}.
# Source fields must equal the current stage/observer binding. The action is
# closed: task-inbox delivers the exact instruction to an already registered
# task generation; ci-ready invokes the existing stage owner for this task.
# No commands, new workers, pipeline starts, merges or runtime activation.
# The manager releases the exact identity with handoff-release --identity SHA
# after checking capacity. Pending capacity is a manager dependency, not paused.
# Existing keyed holds and work-context authority are rechecked before effects.
#
# Receipt: id = SHA256 of canonical contract JSON; dispatched means ONLY the
# bound inbox effect or CI-ready stage was read back, never landing/adoption or
# actual model consumption. The inbox (including handled/) and stage metadata
# are authoritative effects. Resume reconstructs a missing receipt from those
# effects without repeating them. Changed bytes/identity or unknown canonical
# outcome refuse while preserving the original handoff and receipts.
# Requires fm-stage's metadata, observer, work-context and receipt primitives.

if ! declare -F fm_lease_guard >/dev/null; then
  # shellcheck source=bin/fm-lease-lib.sh
  . "$SCRIPT_DIR/fm-lease-lib.sh"
fi

fm_completion_refuse() {
  printf 'COMPLETION_CNO: task=%s owner=fm-stage reason=%s\n' "$ID" "$1"
  return 1
}

fm_completion_hash() {
  local digest=
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
  fi
  if ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]] && command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1)
  fi
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

fm_completion_report_current() {
  local contract=$1 report hash
  report=$(printf '%s' "$contract" | jq -r .report.path) || return 1
  [ -f "$report" ] && [ ! -L "$report" ] && [ -r "$report" ] || { fm_completion_refuse REPORT_UNREADABLE; return 1; }
  hash=$(fm_pr_sha256 "$report") || { fm_completion_refuse REPORT_UNREADABLE; return 1; }
  [ -n "$hash" ] || { fm_completion_refuse REPORT_UNREADABLE; return 1; }
  [ "$hash" = "$(printf '%s' "$contract" | jq -r .report.sha256)" ] || { fm_completion_refuse REPORT_CHANGED; return 1; }
}

fm_completion_store() { # <single JSON value>
  local value=$1 lock tmp
  lock=$(fm_meta_lock_path "$META") || return 1
  if [ "$lock" != "${FM_COMPLETION_SOURCE_LOCK:-}" ]; then
    fm_lock_acquire_wait "$lock" || return 1
  fi
  tmp=$(mktemp "$STATE/.$ID.completion.XXXXXX") || { [ "$lock" = "${FM_COMPLETION_SOURCE_LOCK:-}" ] || fm_lock_release "$lock"; return 1; }
  if ! fm_backlog_record_present "$META" 'task record' "$STATE" || ! fm_completion_saved_valid "$value"; then
    rm -f "$tmp"; [ "$lock" = "${FM_COMPLETION_SOURCE_LOCK:-}" ] || fm_lock_release "$lock"; return 1
  fi
  if printf '%s' "$value" | jq -e '.status == "dispatched"' >/dev/null; then
    if printf '%s' "$value" | jq -e '.contract.action.kind == "ci-ready"' >/dev/null; then
      if ! fm_completion_ci_ready_effect "$(printf '%s' "$value" | jq -c .contract)"; then
        rm -f "$tmp"; [ "$lock" = "${FM_COMPLETION_SOURCE_LOCK:-}" ] || fm_lock_release "$lock"; return 1
      fi
    elif ! fm_completion_report_current "$(printf '%s' "$value" | jq -c .contract)"; then
      rm -f "$tmp"; [ "$lock" = "${FM_COMPLETION_SOURCE_LOCK:-}" ] || fm_lock_release "$lock"; return 1
    fi
  fi
  grep -v '^completion_handoff=' "$META" > "$tmp" || true
  printf 'completion_handoff=%s\n' "$value" >> "$tmp"
  if ! fm_backlog_atomic_transition publish "$tmp" "$META" 'task record' "$STATE"; then
    rm -f "$tmp"; [ "$lock" = "${FM_COMPLETION_SOURCE_LOCK:-}" ] || fm_lock_release "$lock"; return 1
  fi
  [ "$lock" = "${FM_COMPLETION_SOURCE_LOCK:-}" ] || fm_lock_release "$lock"
}

fm_completion_contract_valid() { # <contract JSON>
  printf '%s' "$1" | jq -e '
    def token: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    def sha: type == "string" and test("^[0-9a-f]{40}$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    type == "object" and .schema == "fm-completion-handoff/v1" and
    ([.task,.generation,.attempt,.run,.action.id,.action.owner,.action.generation] | all(token)) and
    (.candidate|sha) and (.source_head|sha) and (.report.sha256|digest) and
    (.report.path|type == "string" and startswith("/") and (contains("\n")|not)) and
    (.action.kind == "task-inbox" or .action.kind == "ci-ready") and
    (if .action.kind == "task-inbox" then (.action.instruction|type == "string" and length > 0)
     else (.action.pr|type == "string" and length > 0) end)
  ' >/dev/null 2>&1
}

fm_completion_binding_current() { # <contract JSON>
  local contract=$1
  [ "$(printf '%s' "$contract" | jq -r .task)" = "$ID" ] &&
    [ "$(printf '%s' "$contract" | jq -r .generation)" = "$(meta spawn_gen)" ] &&
    [ "$(printf '%s' "$contract" | jq -r .generation)" = "$(meta stage_gen)" ] &&
    [ "$(printf '%s' "$contract" | jq -r .attempt)" = "$(meta stage_attempt)" ] &&
    [ "$(printf '%s' "$contract" | jq -r .attempt)" = "$(obs attempt_id)" ] &&
    [ "$(printf '%s' "$contract" | jq -r .run)" = "$(meta stage_run)" ] &&
    [ "$(printf '%s' "$contract" | jq -r .run)" = "$(obs run_id)" ] &&
    [ "$(printf '%s' "$contract" | jq -r .candidate)" = "$(meta stage_head)" ]
}

fm_completion_saved_valid() { # <saved JSON>; no mutation on corrupt authority
  local saved=$1 contract identity
  printf '%s' "$saved" | jq -e '
    type == "object" and (.released | type == "boolean") and
    (.status == "pending" or .status == "dispatched") and
    (.receipt == null or (.receipt | type == "string" and length > 0))
  ' >/dev/null 2>&1 || return 1
  contract=$(printf '%s' "$saved" | jq -cS .contract) || return 1
  fm_completion_contract_valid "$contract" || return 1
  identity=$(fm_completion_hash "$contract") || return 1
  [ "$(printf '%s' "$saved" | jq -r .identity)" = "$identity" ] &&
    fm_completion_binding_current "$contract"
}

# Teardown is a sibling lifecycle caller. It must retain a task whose inbox
# effect still has an unconfirmed downstream obligation. For the closed stage
# action only, preserve the exact contract/receipt as a non-executable archive
# under the existing durable task report directory before removing metadata.
# The caller holds the task metadata lock. No archived receipt is input to
# execution reconciliation or a replacement source of task authority.
fm_completion_retire() { # <saved JSON> <data-dir> <task-id> [--check]
  local saved=$1 data_dir=$2 task=$3 contract identity receipt dir tmp
  local ID=$3
  [ -n "$saved" ] || return 0
  contract=$(printf '%s' "$saved" | jq -cS .contract 2>/dev/null) || return 1
  fm_completion_contract_valid "$contract" || return 1
  identity=$(fm_completion_hash "$contract") || return 1
  receipt="stage:ci-ready:$(printf '%s' "$contract" | jq -r .run):$(printf '%s' "$contract" | jq -r .action.pr)"
  printf '%s' "$saved" | jq -e --arg identity "$identity" --arg task "$task" --arg receipt "$receipt" '
    .identity == $identity and .contract.task == $task and
    .contract.action.kind == "ci-ready" and .status == "dispatched" and .receipt == $receipt
  ' >/dev/null 2>&1 || return 1
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  fm_completion_ci_ready_effect "$contract" "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$task.meta" || return 1
  [ "${4:-}" != --check ] || return 0
  dir="$data_dir/$task"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(mktemp "$dir/.completion-receipt.XXXXXX") || return 1
  if ! printf '%s\n' "$saved" > "$tmp" || ! mv "$tmp" "$dir/completion-receipt.json"; then
    rm -f "$tmp"; return 1
  fi
}

fm_completion_target_current() {
  local contract=$1 owner generation target
  owner=$(printf '%s' "$contract" | jq -r .action.owner)
  generation=$(printf '%s' "$contract" | jq -r .action.generation)
  target="$STATE/$owner.meta"
  [ -f "$target" ] && [ ! -L "$target" ] && [ -r "$target" ] || { fm_completion_refuse TARGET_UNREADABLE; return 1; }
  [ -z "$(fm_meta_get "$target" remote_host)" ] || { fm_completion_refuse UNSUPPORTED_REMOTE_TARGET; return 1; }
  [ "$(fm_meta_get "$target" spawn_gen)" = "$generation" ] || { fm_completion_refuse TARGET_GENERATION; return 1; }
}

fm_completion_admit() {
  local contract identity old
  contract=$(jq -cS . "$HANDOFF_JSON" 2>/dev/null) || { fm_completion_refuse MALFORMED; return 1; }
  fm_completion_contract_valid "$contract" || { fm_completion_refuse MALFORMED; return 1; }
  fm_completion_binding_current "$contract" || { fm_completion_refuse STALE_BINDING; return 1; }
  fm_completion_target_current "$contract" || return 1
  identity=$(fm_completion_hash "$contract") || { fm_completion_refuse DIGEST_UNAVAILABLE; return 1; }
  old=$(meta completion_handoff)
  if [ -n "$old" ]; then
    fm_completion_saved_valid "$old" || { fm_completion_refuse MALFORMED; return 1; }
    [ "$(printf '%s' "$old" | jq -r .identity 2>/dev/null)" = "$identity" ] || {
      fm_completion_refuse CONFLICTING_HANDOFF; return 1;
    }
  else
    old=$(jq -cn --argjson contract "$contract" --arg identity "$identity" \
      '{identity:$identity,contract:$contract,released:false,status:"pending",next_owner:"firstmate",reason:"manager-capacity",receipt:null}') || return 1
    fm_completion_store "$old" || return 1
  fi
  fm_completion_report_saved "$old" "$identity"
}

# Sole owner of the dispatched-receipt line, and of the open downstream
# obligation an inbox effect retains: dispatched records delivery only, never
# actual consumption, so every caller reporting a task-inbox effect emits both.
fm_completion_dispatched_line() {  # <identity> <receipt> <owner>
  printf 'COMPLETION_DISPATCHED: task=%s identity=%s receipt=%s owner=%s\n' "$ID" "$1" "$2" "$3"
}

fm_completion_downstream_open_line() {  # <identity> <receipt> <owner>
  printf 'COMPLETION_PENDING: task=%s identity=%s owner=%s reason=downstream-action-unconfirmed receipt=%s\n' "$ID" "$1" "$3" "$2"
}

# The saved record - never the admission wording - owns the reported
# disposition, so a dispatched obligation is not routed back to its admitter.
fm_completion_report_saved() {  # <saved JSON> <identity>
  local saved=$1 identity=$2 status owner reason receipt kind
  status=$(printf '%s' "$saved" | jq -r '.status // empty') || return 1
  owner=$(printf '%s' "$saved" | jq -r '.next_owner // empty')
  reason=$(printf '%s' "$saved" | jq -r '.reason // empty')
  receipt=$(printf '%s' "$saved" | jq -r '.receipt // empty')
  kind=$(printf '%s' "$saved" | jq -r '.contract.action.kind // empty')
  if [ "$status" = dispatched ] && [ -n "$receipt" ]; then
    if [ "$kind" != task-inbox ]; then
      local contract
      contract=$(printf '%s' "$saved" | jq -c .contract) || return 1
      fm_nm_effect_current "$META" >/dev/null \
        || { fm_completion_refuse CI_QUALIFICATION_REVOKED; return 1; }
      fm_completion_effect_matches_contract "$contract" \
        || { fm_completion_refuse CI_READY_EFFECT_UNPROVEN; return 1; }
      fm_completion_report_current "$contract" || return 1
    fi
    fm_completion_dispatched_line "$identity" "$receipt" "$owner"
    [ "$kind" != task-inbox ] || fm_completion_downstream_open_line "$identity" "$receipt" "$owner"
  else
    printf 'COMPLETION_PENDING: task=%s identity=%s owner=%s reason=%s\n' "$ID" "$identity" "$owner" "$reason"
  fi
}

fm_completion_pending() { # <saved JSON> <identity> <owner> <reason>
  local saved=$1 identity=$2 owner=$3 reason=$4 updated
  updated=$(printf '%s' "$saved" | jq -c --arg owner "$owner" --arg reason "$reason" \
    '.next_owner=$owner | .reason=$reason') || return 1
  [ "$updated" = "$saved" ] || fm_completion_store "$updated" || return 1
  printf 'COMPLETION_PENDING: task=%s identity=%s owner=%s reason=%s\n' "$ID" "$identity" "$owner" "$reason"
}

# The recorded effect proves the contract's exact identity. Separate from
# whether the producer still qualifies it, so each caller can name the cause
# that actually failed instead of one label covering three.
fm_completion_effect_matches_contract() {  # <contract> [meta file]
  local contract=$1 file=${2:-$META}
  printf '%s' "$(sed -n 's/^stage_ci_ready_effect=//p' "$file")" | jq -se --argjson contract "$contract" '
      length == 1 and (.[0] | .task == $contract.task and .generation == $contract.generation and
      .attempt == $contract.attempt and .run == $contract.run and
      .candidate == $contract.candidate and .source_head == $contract.source_head and .pr == $contract.action.pr and
      $contract.action.owner == .task and $contract.action.generation == .generation)
    ' >/dev/null 2>&1 && [ "$(sed -n 's/^stage_pr=//p' "$file")" = "$(printf '%s' "$contract" | jq -r .action.pr)" ]
}

fm_completion_ci_ready_effect() {
  local contract=$1 file=${2:-$META}
  fm_nm_effect_current "$file" >/dev/null || return 1
  fm_completion_effect_matches_contract "$contract" "$file" && fm_completion_report_current "$contract"
}

fm_completion_source_acquire() {
  local saved=$1 lock
  lock=$(fm_meta_lock_path "$META") || return 1
  if [ "$lock" != "${FM_COMPLETION_SOURCE_LOCK:-}" ]; then
    if [ "$lock" != "${FM_COMPLETION_TARGET_LOCK:-}" ]; then
      fm_lock_try_acquire "$lock" || { fm_completion_refuse SOURCE_BUSY; return 1; }
    fi
    FM_COMPLETION_SOURCE_LOCK=$lock
  fi
  if ! { [ -f "$META" ] && [ ! -L "$META" ] && [ "$(meta completion_handoff)" = "$saved" ] \
    && fm_completion_saved_valid "$saved"; }; then
    fm_completion_refuse SOURCE_CHANGED; return 1
  fi
}

fm_completion_resume() {
  local saved contract identity report hash kind owner generation body record effect out rc existing receipt canonical status outcome
  saved=$(meta completion_handoff)
  # Even without an admitted action, refresh canonical observations on resume.
  # A failed refresh never authorizes effects using the prior cached outcome.
  if [ -f "$OBLIGATION" ] && [ -n "$(obs run_id)" ]; then
    observe refresh "$ID"
    [ "$OBS_RC" -eq 0 ] || { fm_completion_refuse CANONICAL_READ_FAILED; return 1; }
    # refresh intentionally returns zero for observation gaps. Require its
    # positive typed read receipt, not merely a successful observer invocation.
    if ! printf '%s\n' "$OBS_OUT" | grep -qxF "NM_OBSERVE: REFRESHED task=$ID run=$(obs run_id) status=$(obs run_status) class=$(obs outcome_class)" \
      || printf '%s\n' "$OBS_OUT" | grep -q '^NM_OBSERVE: DAEMON_RESET '; then
      fm_completion_refuse CANONICAL_READ_FAILED; return 1
    fi
  fi
  if [ -z "$saved" ]; then
    case "$(obs outcome_class)" in
      successful|ci-ready)
        if [ -f "$DATA/$ID/report.md" ]; then
          fm_completion_refuse HANDOFF_UNBOUND; return 1
        fi ;;
    esac
    return 0
  fi
  fm_completion_saved_valid "$saved" || { fm_completion_refuse MALFORMED_OR_STALE; return 1; }
  contract=$(printf '%s' "$saved" | jq -cS .contract 2>/dev/null) || { fm_completion_refuse MALFORMED; return 1; }
  identity=$(fm_completion_hash "$contract") || return 1
  if [ "$(printf '%s' "$saved" | jq -r .identity)" != "$identity" ] || ! fm_completion_contract_valid "$contract"; then
    fm_completion_refuse MALFORMED; return 1
  fi
  fm_completion_binding_current "$contract" || { fm_completion_refuse STALE_BINDING; return 1; }
  canonical=$(bound_run_status) || { fm_completion_refuse CANONICAL_IDENTITY; return 1; }
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$canonical" head)")" = "$(printf '%s' "$contract" | jq -r .source_head)" ] || {
    fm_completion_refuse CANONICAL_SOURCE_HEAD; return 1;
  }
  fm_completion_report_current "$contract" || return 1
  report=$(printf '%s' "$contract" | jq -r .report.path)
  hash=$(printf '%s' "$contract" | jq -r .report.sha256)
  # The observation class is presentation, not action authority: in particular
  # completed with an unknown outcome must not inherit its broad success label.
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$canonical" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$canonical" outcome)")
  kind=$(printf '%s' "$contract" | jq -r .action.kind)
  if [ "$kind" = task-inbox ]; then
    case "$status:$outcome" in
      completed:passed|completed:checks-passed) ;;
      running:|pending:|waiting:|paused:)
        fm_completion_pending "$saved" "$identity" "$ID" run-active; return $? ;;
      *) fm_completion_refuse CANONICAL_OUTCOME_UNKNOWN; return 1 ;;
    esac
  elif ! NM_HOME="$(obs nm_home)" NO_MISTAKES_HOME="$(obs nm_home)" fm_nm_qualification_read \
      "$WT" "$(meta stage_run)" "$(printf '%s' "$contract" | jq -r .source_head)" \
      "$(meta stage_branch)" "$(printf '%s' "$contract" | jq -r .action.pr)" >/dev/null; then
    # An old dispatched effect cannot inherit pending as current success.
    if [ -n "$(meta stage_ci_ready_effect)" ]; then
      fm_completion_refuse CI_QUALIFICATION_REVOKED; return 1
    fi
    case "$status:$outcome" in
      running:|pending:|waiting:|paused:)
        fm_completion_pending "$saved" "$identity" "$ID" run-active; return $? ;;
      *) fm_completion_refuse CI_QUALIFICATION_UNAVAILABLE; return 1 ;;
    esac
  fi
  owner=$(printf '%s' "$contract" | jq -r .action.owner)
  generation=$(printf '%s' "$contract" | jq -r .action.generation)
  [ -f "$STATE/$owner.meta" ] && [ ! -L "$STATE/$owner.meta" ] || { fm_completion_refuse TARGET_UNREADABLE; return 1; }
  [ "$(fm_meta_get "$STATE/$owner.meta" spawn_gen)" = "$generation" ] || { fm_completion_refuse TARGET_GENERATION; return 1; }
  if [ "$kind" = task-inbox ]; then
    fm_lease_guard "$owner" completion-delivery || return 1
    FM_COMPLETION_TARGET_LOCK=$(fm_meta_lock_path "$STATE/$owner.meta") || return 1
    fm_task_inbox_lock_acquire "$FM_COMPLETION_TARGET_LOCK" || { fm_completion_refuse TARGET_BUSY; return 1; }
  fi
  fm_completion_source_acquire "$saved" || return 1
  fm_completion_report_current "$contract" || return 1
  fm_completion_target_current "$contract" || return 1
  if [ "$kind" = ci-ready ]; then
    [ "$owner" = "$ID" ] && [ "$generation" = "$(meta spawn_gen)" ] || { fm_completion_refuse FOREIGN_STAGE_ACTION; return 1; }
    effect="stage:ci-ready:$(printf '%s' "$contract" | jq -r .run):$(printf '%s' "$contract" | jq -r .action.pr)"
    if fm_completion_ci_ready_effect "$contract"; then
      record=$effect
    else
      case "$(meta stage)" in
        ci-ready|landing|activated) fm_completion_refuse CI_READY_EFFECT_UNPROVEN; return 1 ;;
      esac
      record=
    fi
  else
    # The complete body is stable, including its correlation identity. The
    # existing inbox owner searches both pending and handled records.
    if [ -L "$STATE/$owner.inbox" ] || [ -L "$STATE/$owner.inbox/handled" ]; then
      fm_completion_refuse INBOX_UNREADABLE; return 1
    fi
    body=$(printf 'FM_COMPLETION: %s\nreport=%s sha256=%s\n%s' "$identity" "$report" "$hash" "$(printf '%s' "$contract" | jq -r .action.instruction)")
    record=
    for effect in "$STATE/$owner.inbox"/*.msg "$STATE/$owner.inbox/handled"/*.msg; do
      [ -e "$effect" ] || [ -L "$effect" ] || continue
      [ -f "$effect" ] && [ ! -L "$effect" ] && [ -r "$effect" ] || { fm_completion_refuse EFFECT_UNREADABLE; return 1; }
      existing=$(fm_task_inbox_body "$effect") || { fm_completion_refuse EFFECT_UNREADABLE; return 1; }
      if [ "$existing" != "$body" ]; then
        if printf '%s\n' "$existing" | grep -qxF "FM_COMPLETION: $identity"; then
          fm_completion_refuse EFFECT_CONFLICT; return 1
        fi
        continue
      fi
      [ -z "$record" ] || { fm_completion_refuse MULTIPLE_EFFECTS; return 1; }
      record="inbox:${effect##*/}"
    done
  fi
  receipt=$(printf '%s' "$saved" | jq -r '.receipt // empty')
  if [ -n "$record" ] && [ -n "$receipt" ] && [ "$record" != "$receipt" ]; then
    fm_completion_refuse RECEIPT_CONFLICT; return 1
  fi
  # Read back a completed effect BEFORE testing current release/holds. Receipt
  # repair must never replay an effect that succeeded before acknowledgement.
  if [ -z "$record" ]; then
    if [ "$(printf '%s' "$saved" | jq -r .status)" = dispatched ]; then
      fm_completion_refuse EFFECT_DISAPPEARED; return 1
    fi
    if [ "$(printf '%s' "$saved" | jq -r .released)" != true ]; then
      fm_completion_pending "$saved" "$identity" firstmate manager-capacity; return $?
    fi
    [ -z "$(open_hold_keys)" ] || {
      fm_completion_pending "$saved" "$identity" firstmate dependency-held; return $?;
    }
    fm_work_context_dispatch_authority_gate "$STATE" "$DATA" "$ID" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" || {
      fm_completion_refuse AUTHORITY_UNREADABLE; return 1;
    }
    if [ "$owner" != "$ID" ]; then
      [ -z "$(status_open_decisions "$STATE/$owner.status")" ] || {
        fm_completion_pending "$saved" "$identity" firstmate target-dependency-held; return $?;
      }
      fm_work_context_dispatch_authority_gate "$STATE" "$DATA" "$owner" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" || {
        fm_completion_refuse TARGET_AUTHORITY; return 1;
      }
    fi
    if [ "$kind" = ci-ready ]; then
      fm_lock_release "$FM_COMPLETION_SOURCE_LOCK"
      FM_COMPLETION_SOURCE_LOCK=
      rc=0
      out=$(FM_COMPLETION_RECONCILING=1 "$SCRIPT_DIR/fm-stage.sh" "$ID" ci-ready --identity "$identity" --pr "$(printf '%s' "$contract" | jq -r .action.pr)" 2>&1) || rc=$?
      [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fm_completion_refuse STAGE_HELD; return 1; }
      fm_completion_source_acquire "$saved" || return 1
      if ! { [ "$(meta stage)" = ci-ready ] && fm_completion_ci_ready_effect "$contract"; }; then
        fm_completion_refuse EFFECT_UNCONFIRMED; return 1
      fi
      record=$effect
    else
      fm_completion_report_current "$contract" || return 1
      effect=$(fm_task_inbox_write_idempotent "$STATE" "$owner" "$body" "" fm_completion_report_current "$contract") || { fm_completion_refuse DELIVERY_UNCONFIRMED; return 1; }
      [ "$(fm_task_inbox_body "$effect")" = "$body" ] || { fm_completion_refuse EFFECT_UNCONFIRMED; return 1; }
      record="inbox:${effect##*/}"
    fi
  fi
  if [ "$(printf '%s' "$saved" | jq -r .receipt)" != "$record" ]; then
    saved=$(printf '%s' "$saved" | jq -c --arg receipt "$record" --arg owner "$owner" \
      '.status="dispatched" | .receipt=$receipt | .next_owner=$owner | .reason="effect-confirmed; downstream completion remains independently owned"')
    fm_completion_store "$saved" || { fm_completion_refuse RECEIPT_WRITE_FAILED; return 1; }
    fm_completion_dispatched_line "$identity" "$record" "$owner"
  fi
  if [ "$kind" = task-inbox ]; then
    fm_completion_downstream_open_line "$identity" "$record" "$owner"
  fi
}

fm_completion_transition() ( # <handoff|handoff-release|resume-handoff>
  local transition=$1 lock saved rc=0 FM_COMPLETION_TARGET_LOCK='' FM_COMPLETION_SOURCE_LOCK=''
  trap '[ -z "$FM_COMPLETION_SOURCE_LOCK" ] || [ "$FM_COMPLETION_SOURCE_LOCK" = "$FM_COMPLETION_TARGET_LOCK" ] || fm_lock_release "$FM_COMPLETION_SOURCE_LOCK"; [ -z "$FM_COMPLETION_TARGET_LOCK" ] || fm_lock_release "$FM_COMPLETION_TARGET_LOCK"; fm_lock_release "$lock"; fm_lease_guard_release' EXIT
  lock="$STATE/.$ID.completion.lock"
  [ "$transition" != handoff-release ] || fm_lease_forbid_branch handoff-capacity-release
  fm_lease_guard "$ID" completion-handoff || return 1
  fm_lock_try_acquire "$lock" || { fm_lease_guard_release; fm_completion_refuse OWNER_BUSY; return 1; }
  case "$transition" in
    handoff) fm_completion_admit || rc=$? ;;
    handoff-release)
      saved=$(meta completion_handoff)
      if ! fm_completion_saved_valid "$saved" || [ -z "$HANDOFF_IDENTITY" ] || [ "$(printf '%s' "$saved" | jq -r .identity 2>/dev/null)" != "$HANDOFF_IDENTITY" ]; then
        fm_completion_refuse RELEASE_IDENTITY; rc=1
      else
        fm_completion_store "$(printf '%s' "$saved" | jq -c '.released=true')" && fm_completion_resume || rc=$?
      fi ;;
    resume-handoff) fm_completion_resume || rc=$? ;;
  esac
  return "$rc"
)
