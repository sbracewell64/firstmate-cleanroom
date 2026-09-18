#!/usr/bin/env bash
# Engineering extension of fm-work-context-lib.sh; no independent task/authority
# store. The optional work-context.json engineering object owns generation,
# triggers[], skills[] and verification[]. No declaration means no new duty.
# Trigger mapping is closed and model-invoked: test-change -> tdd/worker/test,
# diagnosis -> diagnosing-bugs/worker/diagnosis, instruction-change ->
# writing-for-agents/worker/implementation, review -> code-review/reviewer/review.
# A skill row binds id, trigger, role, stage, absolute path, release, sha256.
# Irrelevant rows impose no source/read/test obligation. Required rows are checked
# before delivery, dispatch and stage use. A mismatch refuses only that effect.
# verification[] rows bind id, skill, scope (component|composition|
# provisioned-runtime|deployed-consumer), public_seam, inputs, environment, oracle,
# allowed_effects, source_identity, caller_identity, command, negative, owner,
# next_gate. All are nonempty strings. Component/composition evidence is owed at
# CI-ready; runtime/consumer obligations survive landing in the existing
# currentness receipt until their existing owner qualifies them.
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

FM_WC_ENGINEERING=
FM_WC_ENGINEERING_DIGEST=
FM_WC_ENGINEERING_SKILLS=

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
  local data=$1 id=$2 role=$3 stage=$4 desc rows row path expected actual
  FM_WC_ENGINEERING=
  FM_WC_ENGINEERING_DIGEST=
  FM_WC_ENGINEERING_SKILLS=
  desc="$data/$id/work-context.json"
  [ -e "$desc" ] || return 0
  command -v jq >/dev/null 2>&1 || { _fm_wc_engineering_gap 'engineering-capability: jq required'; return 3; }
  jq -se 'length == 1 and (.[0]|type == "object")' "$desc" >/dev/null 2>&1 || {
    _fm_wc_engineering_gap "malformed-work-context: $desc"; return 3;
  }
  jq -e 'has("engineering")' "$desc" >/dev/null || return 0
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
    .engineering as $e | ($e|type == "object") and ($e.generation|text) and
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
  ' "$desc" >/dev/null 2>&1; then
    _fm_wc_engineering_gap "engineering-schema: invalid source/trigger/role/stage/evidence declaration in $desc"; return 3
  fi
  FM_WC_ENGINEERING=$(jq -cS '.engineering' "$desc") || return 3
  FM_WC_ENGINEERING_DIGEST=$(printf '%s\n' "$FM_WC_ENGINEERING" | _fm_wc_engineering_sha /dev/stdin) || {
    _fm_wc_engineering_gap 'engineering-capability: SHA256 unavailable'; return 3;
  }
  rows=$(jq -c --arg role "$role" --arg stage "$stage" '
    .engineering as $e | $e.skills[] |
    select(.trigger as $t | $e.triggers|index($t)) |
    select($role == "all" or .role == $role) |
    select($stage == "all" or .stage == $stage)' "$desc") || return 3
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    path=$(printf '%s' "$row" | jq -r .path)
    expected=$(printf '%s' "$row" | jq -r .sha256)
    [ -f "$path" ] && [ -r "$path" ] || {
      _fm_wc_engineering_gap "missing-skill-source: $path owner=pocock-seven-skill-adoption"; return 3;
    }
    actual=$(_fm_wc_engineering_sha "$path") || {
      _fm_wc_engineering_gap "unreadable-skill-source: $path"; return 3;
    }
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
  fm_work_context_engineering "$data" "$id" "$role" "$stage" || return 3
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
  printf 'Required proof (JSON; scopes do not substitute for each other):\n'
  printf '%s' "$FM_WC_ENGINEERING" | jq -c --arg role "$role" --arg stage "$stage" '
    . as $e | .verification[] | . as $v | select(any($e.skills[];
      .id == $v.skill and ($role == "all" or .role == $role) and ($stage == "all" or .stage == $stage)))'
}

fm_work_context_engineering_evidence() { # <data> <id> <run> <actual-head>
  local data=$1 id=$2 run=$3 head=$4 index generation required row proof kind path expected actual skill
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
  [ -n "$required" ] || return 0
  index="$data/$id/engineering-evidence.json"
  generation=$(printf '%s' "$FM_WC_ENGINEERING" | jq -r .generation)
  if [ -z "$run" ] || ! printf '%s' "$head" | grep -Eq '^[0-9a-f]{40}$' ||
    ! jq -se --arg id "$id" --arg gen "$generation" --arg run "$run" --arg head "$head" '
      length == 1 and (.[0] | .task == $id and .generation == $gen and .run == $run and .head == $head and
      (.results|type == "array") and (.results|map(.id)|length == (unique|length)))
    ' "$index" >/dev/null 2>&1; then
    _fm_wc_engineering_gap "engineering-evidence-identity: $index requires current task/generation/run/head owner=nmf-completion-residual-carry"; return 3
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    skill=$(printf '%s' "$FM_WC_ENGINEERING" | jq -c --argjson req "$row" '.skills[] | select(.id == $req.skill)')
    proof=$(jq -c --argjson req "$row" '.results[] | select(.id == $req.id)' "$index") || return 3
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
      [ -f "$path" ] && [ -r "$path" ] || {
        _fm_wc_engineering_gap "engineering-evidence-unreadable: $path"; return 3;
      }
      actual=$(_fm_wc_engineering_sha "$path") || return 3
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
  jq -c '
    .engineering as $e | if $e == null then empty else
    ($e.verification[]? | select(.scope == "provisioned-runtime" or .scope == "deployed-consumer") |
      {id,scope,owner,next_gate,source_identity,caller_identity,status:"open"}),
    ($e.skills[] | select(.trigger as $t | $e.triggers|index($t)) |
      {id:("skill:" + .id + ":consumer"),scope:"deployed-consumer",
       owner:"pocock-seven-skill-adoption",next_gate:"qualified actual consumer evidence",
       source_identity:.sha256,caller_identity:"pending",status:"open"}) end' "$1"
}

fm_work_context_engineering_brief() { # <data> <id>
  local data=$1 id=$2 line expected brief
  brief="$data/$id/brief.md"
  line=$(grep -F 'engineering SHA256 ' "$brief" 2>/dev/null || true)
  [ -n "$FM_WC_ENGINEERING" ] || {
    [ -z "$line" ] || { _fm_wc_engineering_gap 'stale-engineering-brief: declaration removed'; return 3; }
    return 0
  }
  expected="Task $id; generation $(printf '%s' "$FM_WC_ENGINEERING" | jq -r .generation); engineering SHA256 $FM_WC_ENGINEERING_DIGEST."
  [ "$line" = "$expected" ] || {
    _fm_wc_engineering_gap 'stale-engineering-brief: regenerate the brief from the current declared context before dispatch'; return 3;
  }
}
