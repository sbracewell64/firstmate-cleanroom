#!/usr/bin/env bash
# Engineering extension of fm-work-context-lib.sh; no independent task/authority
# store. The optional work-context.json engineering object owns generation,
# discipline, triggers[], skills[] and verification[]. The discipline field is
# compiled and checked by fm-work-context-discipline-lib.sh; this owner includes
# it in the context identity without duplicating its schema. No declaration
# means no new duty.
# Trigger mapping is closed and model-invoked: test-change -> tdd/worker/test,
# diagnosis -> diagnosing-bugs/worker/diagnosis, instruction-change ->
# writing-for-agents/worker/implementation, review -> code-review/reviewer/review.
# A skill row binds id, trigger, role, stage, absolute path, release, sha256.
# Irrelevant rows impose no source/read/test obligation. Required rows are checked
# before delivery, dispatch and stage use. A mismatch refuses only that effect.
# verification[] rows bind id, skill, scope (component|composition|
# provisioned-runtime|deployed-consumer), public_seam, inputs, environment, oracle,
# allowed_effects, source_identity, caller_identity, command, negative, owner,
# next_gate. All are nonempty strings. Component/composition evidence and
# selected-discipline candidate evidence are owed at CI-ready; runtime/consumer
# obligations survive landing in the existing currentness receipt until their
# existing owner qualifies them.
# data/<id>/engineering-evidence.json is the evidence index, not a success token:
# {task,generation,run,head,results:[{id,
# load:{kind,path,sha256,source_sha256,role,stage},
# behavior:{scope,path,sha256,command,oracle,exit_code}}]}.
# Load source_sha256/role/stage match the selected skill; behavior scope,
# command and oracle match the verification row, and exit_code must be zero.
# Load kind is native-read or tool-read, never self-report. Referenced artifacts
# must be readable exact bytes. The index must match the actual pipeline run/head
# and descriptor generation. The existing no-mistakes review still assesses the
# behavioral evidence; integrity/read delivery never establishes good reasoning.
# No recorded command is executed. No source/receipt is mutated by this library.

# shellcheck source=bin/fm-work-context-discipline-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-work-context-discipline-lib.sh"

FM_WC_ENGINEERING=
FM_WC_ENGINEERING_DIGEST=
FM_WC_ENGINEERING_SKILLS=
FM_WC_ENGINEERING_REUSE=0
FM_DISCIPLINE_EVIDENCE_INDEX_JSON=
FM_DISCIPLINE_EVIDENCE_INDEX_DIGEST=
FM_DISCIPLINE_EVIDENCE_INDEX_PATH=

_fm_wc_engineering_gap() {
  # shellcheck disable=SC2034 # Result consumed by work-context, stage and generator callers.
  FM_WORK_CONTEXT_DETAIL=$1
  # shellcheck disable=SC2034 # Shared typed result.
  FM_WORK_CONTEXT_VERDICT=refuse
  return 3
}

_fm_wc_engineering_sha() { # <readable-file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{print $1}'
  else
    return 1
  fi
}

fm_work_context_engineering() { # <data> <id> <worker|reviewer|all> <stage|all>
  local data=$1 id=$2 role=$3 stage=$4 desc rows row path expected actual generation descriptor_rc
  FM_WC_ENGINEERING=
  FM_WC_ENGINEERING_DIGEST=
  FM_WC_ENGINEERING_SKILLS=
  FM_DISCIPLINE_DESCRIPTOR_JSON=
  FM_DISCIPLINE_DESCRIPTOR_DIGEST=
  FM_DISCIPLINE_DESCRIPTOR_PATH=
  FM_DISCIPLINE_ARTIFACT_BYTES=
  FM_DISCIPLINE_ARTIFACT_DIGEST=
  desc="$data/$id/work-context.json"
  if [ ! -e "$desc" ] && [ ! -L "$desc" ]; then
    return 0
  fi
  fm_discipline_descriptor_capture "$desc" || {
    _fm_wc_engineering_gap "unsafe-work-context: $desc"; return 3;
  }
  command -v jq >/dev/null 2>&1 || { _fm_wc_engineering_gap 'engineering-capability: jq required'; return 3; }
  printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -se 'length == 1 and (.[0]|type == "object")' >/dev/null 2>&1 || {
    _fm_wc_engineering_gap "malformed-work-context: $desc"; return 3;
  }
  printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -e 'has("engineering")' >/dev/null || return 0
  if printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -e '.engineering.discipline != null' >/dev/null 2>&1; then
    FM_DISCIPLINE_DESCRIPTOR_REUSE=1
    fm_discipline_load "$data" "$id" ship implementation; descriptor_rc=$?
    FM_DISCIPLINE_DESCRIPTOR_REUSE=0
    [ "$descriptor_rc" -eq 0 ] || return 3
  fi
  case "$role:$stage" in
    all:all|worker:all|reviewer:all|worker:implementation|worker:test|worker:diagnosis|reviewer:review) ;;
    *) _fm_wc_engineering_gap "engineering-role-stage: $role/$stage"; return 3 ;;
  esac
  # One mapping owns applicability and roles; a label cannot turn a reviewer
  # into a worker or introduce an unrelated skill as a required invocation.
  if ! jq -e '
    def text: type == "string" and length > 0 and (test("[\\r\\n\\t]")|not);
    def catalog: {"test-change":["tdd","worker","test"],
      "diagnosis":["diagnosing-bugs","worker","diagnosis"],
      "instruction-change":["writing-for-agents","worker","implementation"],
      "review":["code-review","reviewer","review"]};
    .engineering as $e | ($e|type == "object") and
    ($e.triggers|type == "array") and ($e.triggers|length == (unique|length)) and
    all($e.triggers[]; . as $t | catalog|has($t)) and
    ($e.skills|type == "array") and ($e.skills|map(.id)|length == (unique|length)) and
    all($e.skills[]; . as $s | (catalog[$s.trigger] == [$s.id,$s.role,$s.stage]) and
      all([.path,.release,.sha256][]; text) and (.path|startswith("/")) and
      (.sha256|test("^[0-9a-f]{64}$"))) and
    all($e.triggers[]; . as $t | any($e.skills[]; .trigger == $t)) and
    ($e.verification|type == "array") and
    ($e.verification|map(.id)|length == (unique|length)) and
    all($e.verification[]; . as $v |
      all([.id,.skill,.scope,.public_seam,.inputs,.environment,.oracle,.allowed_effects,
        .source_identity,.caller_identity,.command,.negative,.owner,.next_gate][]; text) and
      (["component","composition","provisioned-runtime","deployed-consumer"]|index($v.scope)) != null and
      any($e.skills[]; .id == $v.skill and (.trigger as $t | $e.triggers|index($t)) != null))
  ' <(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON") >/dev/null 2>&1; then
    _fm_wc_engineering_gap "engineering-schema: invalid source/trigger/role/stage/evidence declaration in $desc"; return 3
  fi
  if ! printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -c '.engineering.generation' | fm_discipline_generation_json_valid; then
    _fm_wc_engineering_gap "engineering-schema: invalid generation in $desc"; return 3;
  fi
  generation=$(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -r '.engineering.generation')
  FM_WC_ENGINEERING=$(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -cS '.engineering') || return 3
  FM_WC_ENGINEERING_DIGEST=$(printf '%s\n' "$FM_WC_ENGINEERING" | _fm_wc_engineering_sha /dev/stdin) || {
    _fm_wc_engineering_gap 'engineering-capability: SHA256 unavailable'; return 3;
  }
  rows=$(jq -c --arg role "$role" --arg stage "$stage" '
    .engineering as $e | $e.skills[] |
    select(.trigger as $t | $e.triggers|index($t)) |
    select($role == "all" or .role == $role) |
    select($stage == "all" or .stage == $stage)' <(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON")) || return 3
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    path=$(printf '%s' "$row" | jq -r .path)
    expected=$(printf '%s' "$row" | jq -r .sha256)
    fm_discipline_capture "$path" || {
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        _fm_wc_engineering_gap "missing-skill-source: $path"
      else
        _fm_wc_engineering_gap "unreadable-skill-source: $path"
      fi
      return 3;
    }
    actual=$FM_DISCIPLINE_CAPTURE_SHA256
    fm_discipline_capture_cleanup
    [ "$actual" = "$expected" ] || {
      _fm_wc_engineering_gap "stale-skill-source: $path expected=$expected actual=$actual owner=pocock-seven-skill-adoption"; return 3;
    }
  done <<ROWS
$rows
ROWS
  FM_WC_ENGINEERING_SKILLS=$rows
  return 0
}

fm_work_context_engineering_render() { # <data> <id> <worker|reviewer|all> <stage|all>
  local data=$1 id=$2 role=$3 stage=$4 row skill_role skill_stage
  if [ "$FM_WC_ENGINEERING_REUSE" -ne 1 ]; then
    fm_work_context_engineering "$data" "$id" "$role" "$stage" || return 3
  fi
  [ -n "$FM_WC_ENGINEERING" ] || return 0
  printf '# Engineering context\n'
  printf 'Task %s; generation %s; engineering SHA256 %s.\n' "$id" \
    "$(printf '%s' "$FM_WC_ENGINEERING" | jq -r .generation)" "$FM_WC_ENGINEERING_DIGEST"
  printf 'Before each applicable stage, including after resume, read its current checked context, then load the selected source.\n'
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    skill_role=$(printf '%s' "$row" | jq -r .role)
    skill_stage=$(printf '%s' "$row" | jq -r .stage)
    printf '%s' "$row" | jq -r '"- \(.id): trigger=\(.trigger), role=\(.role), stage=\(.stage), release=\(.release), sha256=\(.sha256), source=\(.path)."'
    # shellcheck disable=SC2016 # Literal command shown to the worker.
    printf '  Run `FM_HOME=%q FM_DATA_OVERRIDE=%q FM_ROOT_OVERRIDE=%q %q engineering %q %q %q`.\n' \
      "$FM_HOME" "$data" "$FM_ROOT" "$FM_ROOT/bin/fm-work-context.sh" "$id" "$skill_role" "$skill_stage"
  done <<ROWS
$FM_WC_ENGINEERING_SKILLS
ROWS
  printf 'The worker carries reviewer obligations into the existing no-mistakes intent; only its review owner performs that review.\n'
  printf 'Load/read, self-report, behavior, qualification and deployed consumption remain separate; these sources grant no routing, merge or phase authority.\n'
  if [ -n "$FM_DISCIPLINE_RECEIPT" ] && {
    [ "$role:$stage" = all:all ] ||
    [ "$role:$stage" = worker:implementation ];
  }; then
    printf 'Candidate discipline evidence uses the existing engineering-evidence.json results[] row id=worker-discipline. Its discipline object binds task, role=ship, stage=implementation, generation, level, fragment_sha256, producer=worker-candidate, outcome=OBSERVED|CNO, the selected surface, command, oracle, absolute artifact path/SHA256 and safety_facts[]. Bind the index to the current task/run/head. OBSERVED and CNO remain candidate evidence, never qualification or landing authority.\n'
  fi
  printf 'Required proof (JSON; scopes do not substitute for each other):\n'
  printf '%s' "$FM_WC_ENGINEERING" | jq -c --arg role "$role" --arg stage "$stage" '
    . as $e | .verification[] | . as $v | select(any($e.skills[];
      .id == $v.skill and ($role == "all" or .role == $role) and ($stage == "all" or .stage == $stage)))'
}

fm_work_context_engineering_prompt() { # <data> <id> <role> <stage> [include-discipline]
  local data=$1 id=$2 role=$3 stage=$4 discipline_rc include_discipline=${5:-1}
  fm_work_context_engineering "$data" "$id" "$role" "$stage" || return 3
  [ -n "$FM_WC_ENGINEERING" ] || return 0
  if [ "$include_discipline" -eq 1 ] && [ -n "$FM_DISCIPLINE_RECEIPT" ] && {
    [ "$role:$stage" = all:all ] ||
    [ "$role:$stage" = worker:implementation ];
  }; then
    FM_DISCIPLINE_DESCRIPTOR_REUSE=1
    fm_discipline_envelope_render "$data" "$id"; discipline_rc=$?
    FM_DISCIPLINE_DESCRIPTOR_REUSE=0
    [ "$discipline_rc" -eq 0 ] || return 3
    printf '\n\n'
  fi
  FM_WC_ENGINEERING_REUSE=1
  fm_work_context_engineering_render "$data" "$id" "$role" "$stage"
  discipline_rc=$?
  FM_WC_ENGINEERING_REUSE=0
  return "$discipline_rc"
}

fm_work_context_engineering_evidence() { # <data> <id> <run> <actual-head>
  local data=$1 id=$2 run=$3 head=$4 index generation required row proof kind path expected actual skill index_json
  FM_WC_ENGINEERING_EVIDENCE_DIGEST=
  FM_DISCIPLINE_EVIDENCE_INDEX_JSON=
  FM_DISCIPLINE_EVIDENCE_INDEX_DIGEST=
  FM_DISCIPLINE_EVIDENCE_INDEX_PATH=
  fm_work_context_engineering "$data" "$id" all all || return 3
  [ -n "$FM_WC_ENGINEERING" ] || return 0
  required=$(printf '%s' "$FM_WC_ENGINEERING" | jq -c '.verification[] | select(.scope == "component" or .scope == "composition")')
  if ! printf '%s' "$FM_WC_ENGINEERING" | jq -e '
    . as $e | all(.triggers[]; . as $t |
      any($e.verification[]; . as $v |
        (.scope == "component" or .scope == "composition") and
        any($e.skills[]; .trigger == $t and .id == $v.skill)))' >/dev/null; then
    _fm_wc_engineering_gap 'engineering-evidence-undeclared: every applicable skill needs independent behavioral verification owner=nmf-completion-residual-carry'; return 3
  fi
  index="$data/$id/engineering-evidence.json"
  generation=$(printf '%s' "$FM_WC_ENGINEERING" | jq -r .generation)
  if [ -n "$FM_DISCIPLINE_RECEIPT" ]; then
    fm_discipline_evidence "$data" "$id" "$run" "$head" || return 3
    index_json=$FM_DISCIPLINE_EVIDENCE_INDEX_JSON
    FM_WC_ENGINEERING_EVIDENCE_DIGEST=$FM_DISCIPLINE_EVIDENCE_INDEX_DIGEST
  elif [ -n "$required" ] || [ -e "$index" ] || [ -L "$index" ]; then
    fm_discipline_capture "$index" || {
      _fm_wc_engineering_gap "engineering-evidence-unreadable: $index"; return 3;
    }
    index_json=$(<"$FM_DISCIPLINE_CAPTURE_PATH")
    FM_DISCIPLINE_EVIDENCE_INDEX_JSON=$index_json
    FM_DISCIPLINE_EVIDENCE_INDEX_DIGEST=$FM_DISCIPLINE_CAPTURE_SHA256
    FM_DISCIPLINE_EVIDENCE_INDEX_PATH=$index
    FM_WC_ENGINEERING_EVIDENCE_DIGEST=$FM_DISCIPLINE_EVIDENCE_INDEX_DIGEST
    fm_discipline_capture_cleanup
  fi
  [ -n "$required" ] || return 0
  index_json=$FM_DISCIPLINE_EVIDENCE_INDEX_JSON
  if [ -z "$run" ] || ! printf '%s' "$head" | grep -Eq '^[0-9a-f]{40}$' ||
    ! jq -se --arg id "$id" --arg gen "$generation" --arg run "$run" --arg head "$head" '
      length == 1 and (.[0] | .task == $id and .generation == $gen and .run == $run and .head == $head and
      (.results|type == "array") and (.results|map(.id)|length == (unique|length)))
    ' <(printf '%s' "$index_json") >/dev/null 2>&1; then
    _fm_wc_engineering_gap "engineering-evidence-identity: $index requires current task/generation/run/head owner=nmf-completion-residual-carry"; return 3
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    skill=$(printf '%s' "$FM_WC_ENGINEERING" | jq -c --argjson req "$row" '.skills[] | select(.id == $req.skill)')
    proof=$(printf '%s' "$index_json" | jq -c --argjson req "$row" '.results[] | select(.id == $req.id)') || return 3
    if [ -z "$proof" ] || ! printf '%s' "$proof" | jq -e --argjson req "$row" --argjson skill "$skill" '
      .load.source_sha256 == $skill.sha256 and .load.role == $skill.role and .load.stage == $skill.stage and
      .behavior.scope == $req.scope and (.load.kind == "native-read" or .load.kind == "tool-read") and
      .behavior.exit_code == 0 and .behavior.command == $req.command and
      .behavior.oracle == $req.oracle and
      all([.load,.behavior][]; (.path|type == "string" and startswith("/")) and
        (.sha256|type == "string" and test("^[0-9a-f]{64}$")))
    ' >/dev/null 2>&1; then
      _fm_wc_engineering_gap "engineering-evidence-missing: $(printf '%s' "$row" | jq -r .id) needs observed load plus independent behavior owner=nmf-completion-residual-carry"; return 3
    fi
    for kind in load behavior; do
      path=$(printf '%s' "$proof" | jq -r ".$kind.path")
      expected=$(printf '%s' "$proof" | jq -r ".$kind.sha256")
      fm_discipline_capture "$path" || {
        _fm_wc_engineering_gap "engineering-evidence-unreadable: $path"; return 3;
      }
      actual=$FM_DISCIPLINE_CAPTURE_SHA256
      fm_discipline_capture_cleanup
      [ "$actual" = "$expected" ] || {
        _fm_wc_engineering_gap "engineering-evidence-stale: $path"; return 3;
      }
    done
  done <<ROWS
$required
ROWS
}

fm_work_context_engineering_residuals() { # <descriptor>
  # Source completion never discharges runtime/deployed scope. Its existing
  # owner supplies later acceptance; this receipt preserves each obligation.
  fm_discipline_descriptor_capture "$1" || return 3
  jq -c '
    .engineering as $e | if $e == null then empty else
    ($e.verification[]? | select(.scope == "provisioned-runtime" or .scope == "deployed-consumer") |
      {id,scope,owner,next_gate,source_identity,caller_identity,status:"open"}),
    ($e.discipline? | select(type == "object") | {id:"worker-discipline:active",scope:"provisioned-runtime",
      owner:"runtime-pin-adoption-gap",next_gate:"qualified release deployment and read-back",
      source_identity:.fragment_sha256,caller_identity:"pending",claim:"ACTIVE",evidence:"CNO",status:"open"}),
    ($e.discipline? | select(type == "object") | {id:"worker-discipline:fresh-production-consumed",scope:"deployed-consumer",
      owner:"runtime-pin-adoption-gap",next_gate:"fresh production worker receipt",
      source_identity:.fragment_sha256,caller_identity:"pending",claim:"CONSUMED",evidence:"CNO",status:"open"}),
    ($e.skills[] | select(.trigger as $t | $e.triggers|index($t)) |
      {id:("skill:" + .id + ":consumer"),scope:"deployed-consumer",
       owner:"pocock-seven-skill-adoption",next_gate:"qualified actual consumer evidence",
       source_identity:.sha256,caller_identity:"pending",status:"open"}) end' \
    <(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON")
}

fm_work_context_engineering_brief() { # <data> <id> <kind> <state>
  local data=$1 id=$2 kind=$3 state=$4 line expected brief instructions origin_count origin mode
  brief="$data/$id/brief.md"
  instructions="$data/$id/ship-instructions.md"
  if [ "$kind" = ship ]; then
    origin_count=$(grep -c '^origin=' "$state/$id.meta" 2>/dev/null || true)
    origin=$(fm_meta_get "$state/$id.meta" origin)
    case "$origin_count:$origin" in
      *:) [ ! -e "$instructions" ] && [ ! -L "$instructions" ] || {
        _fm_wc_engineering_gap 'discipline-artifact: unexpected promoted instructions shadow'; return 3;
      } ;;
      1:scout-to-ship) : ;;
      *) _fm_wc_engineering_gap 'discipline-artifact: malformed promotion origin'; return 3 ;;
    esac
    if [ "$origin" = scout-to-ship ]; then
      [ -f "$instructions" ] && [ ! -L "$instructions" ] || {
        _fm_wc_engineering_gap 'discipline-artifact: promoted instructions path is unsafe'; return 3;
      }
      brief="$instructions"
    fi
    if printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -e '.engineering.discipline != null' >/dev/null 2>&1; then
      if [ "$origin" = scout-to-ship ]; then
        mode=$(fm_meta_get "$state/$id.meta" mode)
        fm_discipline_envelope_validate "$data" "$id" "$brief" \
          "Your scout task has been promoted to a ship task, mode=$mode. Your window, worktree, and context stay as they are; only the contract below changes." || return 3
      else
        fm_discipline_brief "$data" "$id" ship "$brief" || return 3
      fi
    fi
  elif [ "$kind" = scout ] || [ "$kind" = secondmate ]; then
    if [ "$kind" = scout ]; then
      fm_discipline_capture "$brief" || {
        _fm_wc_engineering_gap 'discipline-artifact: unsafe or missing scout brief'; return 3;
      }
      FM_DISCIPLINE_ARTIFACT_BYTES=$(<"$FM_DISCIPLINE_CAPTURE_PATH")
      FM_DISCIPLINE_ARTIFACT_DIGEST=$FM_DISCIPLINE_CAPTURE_SHA256
      fm_discipline_capture_cleanup
      [ "$(printf '%s' "$FM_DISCIPLINE_ARTIFACT_BYTES" | head -n 1)" = 'You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.' ] || {
        _fm_wc_engineering_gap 'discipline-role: scout brief has an unexpected generated prefix'; return 3;
      }
    fi
    fm_discipline_brief "$data" "$id" "$kind" "$brief" || return 3
  fi
  if [ -z "$FM_DISCIPLINE_ARTIFACT_DIGEST" ]; then
    fm_discipline_capture "$brief" || { _fm_wc_engineering_gap "discipline-artifact: unsafe or unreadable $brief"; return 3; }
    FM_DISCIPLINE_ARTIFACT_BYTES=$(<"$FM_DISCIPLINE_CAPTURE_PATH")
    FM_DISCIPLINE_ARTIFACT_DIGEST=$FM_DISCIPLINE_CAPTURE_SHA256
    fm_discipline_capture_cleanup
  fi
  line=$(printf '%s' "$FM_DISCIPLINE_ARTIFACT_BYTES" | grep -F 'engineering SHA256 ' 2>/dev/null || true)
  [ -n "$FM_WC_ENGINEERING" ] || {
    [ -z "$line" ] || { _fm_wc_engineering_gap 'stale-engineering-brief: declaration removed'; return 3; }
    return 0
  }
  expected="Task $id; generation $(printf '%s' "$FM_WC_ENGINEERING" | jq -r .generation); engineering SHA256 $FM_WC_ENGINEERING_DIGEST."
  [ "$line" = "$expected" ] || {
    _fm_wc_engineering_gap 'stale-engineering-brief: regenerate the brief from the current declared context before dispatch'; return 3;
  }
}
