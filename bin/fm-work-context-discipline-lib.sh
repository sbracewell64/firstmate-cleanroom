#!/usr/bin/env bash
# Single owner of the worker-discipline text a crewmate brief carries.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship or scout
# brief, and by bin/fm-promote.sh, which renders the ship block into the ship
# instructions a promoted scout receives, so a promoted worker gets the same
# engineering contract as a briefed one (the same single-owner reason
# bin/fm-dod-lib.sh exists). Worker engineering discipline lives here; the
# delivery definition of done stays in bin/fm-dod-lib.sh, a different owner.
# fm_discipline_block ship [--shared-boundary] [--proof-surface <text>] is the
# private fragment renderer.
# fm_discipline_prepare compiles accepted typed task facts into the optional
# engineering.discipline object in the existing work-context descriptor.
# fm_discipline_render reloads and checks that immutable receipt before printing
# the compact "# Worker discipline" section and its selected fragments.
# The receipt, engineering-context digest and ordinary stage identity together
# bind task, role, stage, selection generation, branch/head/tree when those exist,
# and the canonical fragment bytes without adding another registry.
# fm_discipline_block scout prints the epistemic, read-only subset only
# ("# Evidence discipline"): a scout gains no code-writing inner loop.
# A secondmate charter renders nothing from here, and neither firstmate nor a
# secondmate ever loads this text as an operating mode.
#
# PERSISTED CONTRACT. engineering.discipline is the one selection receipt:
# {schema,task,role,stage,level,facts[],proof_kind,proof_surface,
# outer_generation,fragment_sha256,generation}. Levels are base, shared-boundary and
# proof-surface. Facts are local, shared-api, schema, persisted-state, authority,
# lifecycle, identity, provenance or sibling-invariant. Proof kinds are
# accepted-surface and verification-lever. The compiler derives level,
# generation and fragment identity; callers cannot supply those conclusions.
# The existing engineering-context hash and stage record bind the receipt to the
# admitted branch/head/tree and retry. The existing engineering-evidence.json
# index carries one worker-discipline result whose discipline object binds the
# receipt plus producer=worker-candidate, outcome=OBSERVED|CNO, selected surface,
# command, oracle, artifact path/SHA256 and safety_facts[]. OBSERVED is candidate
# evidence, not PASS. CNO is never promoted. The independent no-mistakes result
# still owns qualification, and the guarded landing owner still owns landing.
# Runtime ACTIVE and fresh-production CONSUMED remain CNO residuals owned by
# runtime-pin-adoption-gap after source landing.
#
# Every block grants no authority: it never lets a worker spawn or steer other
# workers, choose a model or provider route, change fleet state, reinterpret the
# delivery mode or acceptance, or merge. The Rules and Definition of done in the
# brief own those boundaries; this text only shapes how the worker engineers
# and proves the change inside them. Selection is D1 engineering judgment only:
# it grants no sequencing, capacity, acceptance, qualification, retry, landing,
# finalization, protected effect, privacy relaxation or reserved decision, and
# concurrency remains separately owned.
# The one machine-readable outcome token is `could-not-observe (CNO)`: an
# unobservable fact is recorded as CNO, never as a pass and never as safe.
# There is deliberately no second token for "not proven".
# A worker's `note: verification-gap: {one line}` status event names recurring
# manual verification, a flaky proof, or missing observability; firstmate files
# it as its own bounded work item (AGENTS.md section 10) instead of widening the
# finished task, and the worker never holds the task on it.
# Provenance: re-expressed in Firstmate language from two MIT-licensed sources,
# neither copied nor vendored. pstack 0.14.7 (https://github.com/cursor/plugins,
# subtree pstack/, MIT, Lauren Tan) at commit
# efa2a531985e0a8084d36ff3cf87233be8a9f34b: principle-prove-it-works,
# principle-subtract-before-you-add, principle-sequence-verifiable-units,
# principle-build-the-lever, the factual core of blast-radius, and the
# complexity gate of how. Ponytail (https://github.com/DietrichGebert/ponytail,
# MIT, Dietrich Gebert) at commit 2ed6c52c9d7e5e56942508591085fd45dea277d3
# (three commits after the v4.9.0 tag at 0a4dd63): the understand-first rule,
# the minimality ladder, root-cause-over-symptom, and the never-simplify-away
# list. No pstack or Ponytail runtime, hook, plugin, router, intensity level,
# model rule, or fan-out mechanism is adopted.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

fm_discipline_block() {  # <ship|scout> [--shared-boundary] [--proof-surface <text>]
  local kind=$1 shared=0 surface='' want='' a block
  shift
  for a in "$@"; do
    if [ -n "$want" ]; then
      surface=$a
      want=''
      continue
    fi
    case "$a" in
      --shared-boundary) shared=1 ;;
      --proof-surface) want='proof-surface' ;;
      --proof-surface=*) surface=${a#--proof-surface=} ;;
      *) echo "error: fm_discipline_block: unknown argument '$a'" >&2; return 1 ;;
    esac
  done
  [ -z "$want" ] || { echo "error: fm_discipline_block: --$want requires a value" >&2; return 1; }
  case "$kind" in
    scout)
      [ "$shared" -eq 0 ] && [ -z "$surface" ] || {
        echo "error: fm_discipline_block: --shared-boundary and --proof-surface apply only to ship work" >&2
        return 1
      }
      IFS= read -r -d '' block <<'EOF' || true
# Evidence discipline
Read the task and the code it touches before concluding; observe primary evidence - source, runtime behavior, real output - and cite it by file:line or by the command you ran.
Prove a claim by running the real thing where that is cheap; otherwise label the claim as inferred.
Keep evidence, inference, and what you could not verify as separate labeled findings; a result you could not observe is reported as could-not-observe (CNO), never rounded to a pass.
This grants no authority: your deliverable stays the report, which recommends and never instructs a merge or landing - a scratch edit never becomes a shipped change - and you still never push, open a PR, spawn or steer other workers, choose a model route, or change fleet state.
EOF
      printf '%s' "${block%$'\n'}"
      return 0
      ;;
    ship) ;;
    *) echo "error: fm_discipline_block: unknown kind '$kind'" >&2; return 1 ;;
  esac
  IFS= read -r -d '' block <<'EOF' || true
# Worker discipline
This section shapes how you engineer and prove the change; it grants no authority beyond the Rules above.
1. Understand first: read the task and the code it touches, and trace the real flow end to end when the change crosses or depends on a shared boundary or the task is diagnostic; otherwise say in one line why you skipped that walk. A small diff in the wrong owner is a second bug, not minimality.
2. Then climb the ladder: explicit acceptance first, subtract unnecessary work, reuse the existing owner or pattern, then standard or installed capabilities, then the smallest correct change. Stop at the first sufficient solution; preserve required edge cases and never widen scope with speculative abstractions or dependencies.
3. A bug fix repairs the root cause: inspect the materially analogous callers and entry paths of what you touch, and prefer one repair in the shared owner over a patch per symptom when the evidence supports that owner.
4. Exercise the changed command, caller, protocol or runtime and record its artifact identity, independent expected result and observed behavior. At shared APIs, schemas, persisted state or authority boundaries, prove the affected safety facts. Mark anything unobserved as could-not-observe (CNO), never pass or safe.
5. When important proof would otherwise need a repeated manual or reasoning-heavy procedure, write the smallest deterministic rerunnable check, run it, and keep it with the change; trivial work manufactures no tooling, and a framework is never the answer.
6. Minimality never outranks explicit acceptance criteria, the project's required tests and validators, the selected delivery path's own gates, security and privacy, validation at trust boundaries, error handling that prevents data loss, accessibility, or exact-head, provenance, and authority constraints.
7. Stay inside this assignment: only this worktree and scope; never spawn or steer other workers, choose a model or provider route, change fleet state, reinterpret the delivery mode or acceptance, or merge anything the contract below does not grant.
8. Return evidence, not authority: put the proof you ran and every CNO item in your commit message or PR description as candidate evidence for review; it never satisfies the delivery path's own gates or firstmate's acceptance by itself.
If recurring manual verification, a flaky proof, or missing observability kept a proof from being cheap, append one `note: verification-gap: {one line}` to the status file before the final lifecycle transition so firstmate can file a bounded follow-up; a required acceptance gap still follows the existing blocker or decision contract.
EOF
  printf '%s' "${block%$'\n'}"
  if [ "$shared" -eq 1 ]; then
    IFS= read -r -d '' block <<'EOF' || true

# Shared boundary
Firstmate marked this change as crossing a shared seam, so point 1's trace and point 4's safety facts are mandatory here, not conditional.
Trace the path through that seam - every caller, reader, and persisted form that meets it - and keep the walk to that seam, not a survey of the project; prove each safety fact with a script or test that fails loudly if the fact is false, and record CNO for any you could not run.
EOF
    printf '%s' "${block%$'\n'}"
  fi
  if [ -n "$surface" ]; then
    IFS= read -r -d '' block <<'EOF' || true

# Proof surface
Completion requires exercising this real surface:
EOF
    block="${block}"$'\n'
    block="${block}${surface}"$'\n'
    IFS= read -r -d '' tail <<'EOF' || true
Passing tests alone do not satisfy it: drive the surface, record the observed result with your evidence, and if it cannot be reached record CNO rather than a pass.
EOF
    block="${block}${tail%$'\n'}"
    printf '%s' "${block%$'\n'}"
  fi
  return 0
}

FM_DISCIPLINE_RECEIPT=
FM_DISCIPLINE_LEVEL=
FM_DISCIPLINE_GENERATION=
FM_DISCIPLINE_FRAGMENT_SHA256=
FM_DISCIPLINE_PROOF_SURFACE=
FM_DISCIPLINE_PROOF_OUTCOME=
FM_DISCIPLINE_EVIDENCE_INDEX_JSON=
FM_DISCIPLINE_EVIDENCE_INDEX_DIGEST=
FM_DISCIPLINE_EVIDENCE_INDEX_PATH=
FM_DISCIPLINE_DESCRIPTOR_JSON=
FM_DISCIPLINE_DESCRIPTOR_DIGEST=
FM_DISCIPLINE_DESCRIPTOR_PATH=
FM_DISCIPLINE_DESCRIPTOR_REUSE=0
FM_DISCIPLINE_ARTIFACT_BYTES=
FM_DISCIPLINE_ARTIFACT_DIGEST=

fm_discipline_descriptor_capture() { # <path>
  local path=$1
  if [ "$FM_DISCIPLINE_DESCRIPTOR_REUSE" -eq 1 ] &&
    [ "$FM_DISCIPLINE_DESCRIPTOR_PATH" = "$path" ] &&
    [ -n "$FM_DISCIPLINE_DESCRIPTOR_DIGEST" ]; then
    return 0
  fi
  fm_discipline_capture "$path" || return 1
  FM_DISCIPLINE_DESCRIPTOR_JSON=$(<"$FM_DISCIPLINE_CAPTURE_PATH")
  FM_DISCIPLINE_DESCRIPTOR_DIGEST=$FM_DISCIPLINE_CAPTURE_SHA256
  FM_DISCIPLINE_DESCRIPTOR_PATH=$path
  fm_discipline_capture_cleanup
}

fm_discipline_gap() {
  # shellcheck disable=SC2034 # Typed result consumed by sourcing work-context callers.
  FM_WORK_CONTEXT_DETAIL=$1
  # shellcheck disable=SC2034 # Typed result consumed by sourcing work-context callers.
  FM_WORK_CONTEXT_VERDICT=refuse
  return 3
}

fm_discipline_sha() { # <readable-file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{print $1}'
  else
    return 1
  fi
}

fm_discipline_regular_file() { # <path>
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]
}

FM_DISCIPLINE_CAPTURE_DIR=
FM_DISCIPLINE_CAPTURE_PATH=
FM_DISCIPLINE_CAPTURE_SHA256=
FM_DISCIPLINE_CAPTURE_MODE=

fm_discipline_capture_cleanup() {
  [ -z "$FM_DISCIPLINE_CAPTURE_PATH" ] || rm -f -- "$FM_DISCIPLINE_CAPTURE_PATH" 2>/dev/null || true
  [ -z "$FM_DISCIPLINE_CAPTURE_DIR" ] || rmdir "$FM_DISCIPLINE_CAPTURE_DIR" 2>/dev/null || true
  FM_DISCIPLINE_CAPTURE_DIR=
  FM_DISCIPLINE_CAPTURE_PATH=
  FM_DISCIPLINE_CAPTURE_SHA256=
  FM_DISCIPLINE_CAPTURE_MODE=
}

fm_discipline_capture() { # <path>
  local path=$1 digest mode capture_result
  fm_discipline_capture_cleanup
  FM_DISCIPLINE_CAPTURE_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-discipline-capture.XXXXXX") || return 1
  FM_DISCIPLINE_CAPTURE_PATH=$(umask 077; mktemp "$FM_DISCIPLINE_CAPTURE_DIR/bytes.XXXXXX") || {
    fm_discipline_capture_cleanup; return 1;
  }
  digest=$(perl - "$path" "$FM_DISCIPLINE_CAPTURE_PATH" <<'PERL'
use strict;
use warnings;
use Fcntl qw(O_NOFOLLOW O_NONBLOCK O_RDONLY O_TRUNC O_WRONLY);
use Digest::SHA;
my ($source, $output) = @ARGV;
sysopen(my $in, $source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 1;
my @before = stat($in);
exit 1 unless @before && (($before[2] & 0170000) == 0100000);
sysopen(my $out, $output, O_WRONLY | O_TRUNC | O_NOFOLLOW) or exit 1;
my $sha = Digest::SHA->new(256);
my $captured = '';
my $buffer;
while (1) {
  my $read = sysread($in, $buffer, 65536);
  exit 1 unless defined $read;
  last if $read == 0;
  my $chunk = substr($buffer, 0, $read);
  $captured .= $chunk;
  $sha->add($chunk);
  my $offset = 0;
  while ($offset < $read) {
    my $written = syswrite($out, $buffer, $read - $offset, $offset);
    exit 1 unless defined $written && $written > 0;
    $offset += $written;
  }
}
my @after = stat($in);
exit 1 unless @after;
for my $i (0, 1, 2, 7, 9, 10) {
  exit 1 unless $after[$i] == $before[$i];
}
defined(sysseek($in, 0, 0)) or exit 1;
my $recheck = '';
my $recheck_sha = Digest::SHA->new(256);
while (1) {
  my $read = sysread($in, $buffer, 65536);
  exit 1 unless defined $read;
  last if $read == 0;
  my $chunk = substr($buffer, 0, $read);
  $recheck .= $chunk;
  $recheck_sha->add($chunk);
}
my @final = stat($in);
exit 1 unless @final;
for my $i (0, 1, 2, 7, 9, 10) {
  exit 1 unless $final[$i] == $before[$i];
}
my $first_digest = $sha->hexdigest;
my $second_digest = $recheck_sha->hexdigest;
exit 1 unless $recheck eq $captured && $second_digest eq $first_digest;
print $first_digest . "\t" . sprintf("%04o", $before[2] & 07777);
PERL
  ) || { fm_discipline_capture_cleanup; return 1; }
  capture_result=$digest
  digest=${capture_result%%$'\t'*}
  mode=${capture_result#*$'\t'}
  case "$digest" in
    [0-9a-f][0-9a-f]* ) [ "${#digest}" -eq 64 ] || { fm_discipline_capture_cleanup; return 1; } ;;
    * ) fm_discipline_capture_cleanup; return 1 ;;
  esac
  [ -n "$mode" ] || { fm_discipline_capture_cleanup; return 1; }
  FM_DISCIPLINE_CAPTURE_SHA256=$digest
  FM_DISCIPLINE_CAPTURE_MODE=$mode
}

fm_discipline_generation_json_valid() {
  jq -e '
    type == "string" and length > 0 and
    (explode | all(.[]; (. < 32 or . == 127 or (. >= 128 and . <= 159)) | not))
  ' >/dev/null 2>&1
}

fm_discipline_compile() { # <task> <ship> <implementation> [--fact <fact>] [--proof-kind <kind> --proof-surface <text>] [--outer-generation <generation>]
  local task=$1 role=$2 stage=$3 want='' a proof_kind='' proof_surface='' outer_generation='' local_fact=0 shared=0
  local runtime_surface=0 product_surface=0 repeated_verification=0
  local facts='[]' fact level block fragment preimage selection generation arg_kind
  local proof_kind_seen=0 proof_surface_seen=0 outer_generation_seen=0
  shift 3
  command -v jq >/dev/null 2>&1 || { fm_discipline_gap 'discipline-capability: jq required'; return 3; }
  for a in "$@"; do
    if [ -n "$want" ]; then
      arg_kind=$want
      case "$want" in
        fact) fact=$a ;;
        proof-kind)
          [ "$proof_kind_seen" -eq 0 ] || { fm_discipline_gap 'discipline-argument: duplicate --proof-kind'; return 3; }
          proof_kind_seen=1
          proof_kind=$a
          ;;
        proof-surface)
          [ "$proof_surface_seen" -eq 0 ] || { fm_discipline_gap 'discipline-argument: duplicate --proof-surface'; return 3; }
          proof_surface_seen=1
          proof_surface=$a
          ;;
        outer-generation)
          [ "$outer_generation_seen" -eq 0 ] || { fm_discipline_gap 'discipline-argument: duplicate --outer-generation'; return 3; }
          outer_generation_seen=1
          outer_generation=$a
          ;;
      esac
      want=
      if [ "$arg_kind" = fact ] && [ -z "${fact:-}" ]; then
        fm_discipline_gap 'empty-discipline-fact: --fact requires a non-empty typed value'; return 3;
      fi
      if [ "$arg_kind" = proof-kind ] && [ -z "$proof_kind" ]; then
        fm_discipline_gap 'empty-discipline-proof-kind: --proof-kind requires a non-empty value'; return 3;
      fi
      if [ "$arg_kind" = proof-surface ] && [ -z "$proof_surface" ]; then
        fm_discipline_gap 'empty-discipline-proof-surface: --proof-surface requires a non-empty value'; return 3;
      fi
      if [ "$arg_kind" = outer-generation ] && [ -z "$outer_generation" ]; then
        fm_discipline_gap 'empty-discipline-generation: --outer-generation requires a non-empty value'; return 3;
      fi
      if [ "${fact:-}" != '' ]; then
        case "$fact" in
          local) local_fact=1 ;;
          shared-api|schema|persisted-state|authority|lifecycle|identity|provenance|sibling-invariant) shared=1 ;;
          real-runtime-surface) runtime_surface=1 ;;
          real-product-surface) product_surface=1 ;;
          repeated-verification) repeated_verification=1 ;;
          *) fm_discipline_gap "unknown-discipline-fact: $fact"; return 3 ;;
        esac
        facts=$(printf '%s' "$facts" | jq -c --arg fact "$fact" '. + [$fact] | unique') || return 3
        fact=
      fi
      continue
    fi
    case "$a" in
      --fact) want=fact ;;
      --proof-kind) want='proof-kind' ;;
      --proof-surface) want='proof-surface' ;;
      --outer-generation) want='outer-generation' ;;
      *) fm_discipline_gap "discipline-argument: unknown argument '$a'"; return 3 ;;
    esac
  done
  [ -z "$want" ] || { fm_discipline_gap "discipline-argument: --$want requires a value"; return 3; }
  if [ -n "$outer_generation" ] && ! printf '%s' "$outer_generation" | jq -R -s . | fm_discipline_generation_json_valid; then
    fm_discipline_gap 'discipline-context: malformed engineering generation'; return 3
  fi
  [ "$role" = ship ] && [ "$stage" = implementation ] || {
    fm_discipline_gap "discipline-applicability: $role/$stage"; return 3;
  }
  [ "$(printf '%s' "$facts" | jq 'length')" -gt 0 ] || {
    facts='["local"]'; local_fact=1;
  }
  if [ "$local_fact" -eq 1 ] && [ "$shared" -eq 1 ]; then
    fm_discipline_gap 'contradictory-discipline-facts: local cannot be combined with a shared seam fact'
    return 3
  fi
  case "$proof_kind" in
    '')
      [ -z "$proof_surface" ] || { fm_discipline_gap 'proof-kind-required: --proof-surface needs accepted-surface or verification-lever'; return 3; }
      [ "$runtime_surface" -eq 0 ] && [ "$product_surface" -eq 0 ] && [ "$repeated_verification" -eq 0 ] || {
        fm_discipline_gap 'proof-fact-required: accepted proof kind and concrete surface are required'; return 3;
      }
      ;;
    accepted-surface)
      [ -n "$proof_surface" ] || { fm_discipline_gap "proof-surface-required: $proof_kind needs a concrete surface"; return 3; }
      [ "$runtime_surface" -eq 1 ] || [ "$product_surface" -eq 1 ] || {
        fm_discipline_gap 'proof-authority-required: accepted-surface needs real-runtime-surface or real-product-surface'; return 3;
      }
      [ "$repeated_verification" -eq 0 ] || { fm_discipline_gap 'proof-authority-cross-pair: accepted-surface cannot use repeated-verification'; return 3; }
      ;;
    verification-lever)
      [ -n "$proof_surface" ] || { fm_discipline_gap "proof-surface-required: $proof_kind needs a concrete surface"; return 3; }
      [ "$repeated_verification" -eq 1 ] || {
        fm_discipline_gap 'proof-authority-required: verification-lever needs repeated-verification'; return 3;
      }
      [ "$runtime_surface" -eq 0 ] && [ "$product_surface" -eq 0 ] || { fm_discipline_gap 'proof-authority-cross-pair: verification-lever cannot use a real surface fact'; return 3; }
      ;;
    *) fm_discipline_gap "unknown-proof-kind: $proof_kind"; return 3 ;;
  esac
  if ! jq -e -n --arg text "$task" '$text | test("[\u0000-\u001f\u007f]") | not' >/dev/null; then
    fm_discipline_gap 'discipline-text: task must be single-line text'
    return 3
  fi
  if ! jq -e -n --arg text "$proof_surface" '$text | test("[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]") | not' >/dev/null; then
    fm_discipline_gap 'discipline-text: proof surface contains an unsupported control character'
    return 3
  fi
  if [ -n "$proof_kind" ]; then
    level='proof-surface'
  elif [ "$shared" -eq 1 ]; then
    level='shared-boundary'
  else
    level=base
  fi
  local args=()
  [ "$shared" -eq 0 ] || args+=(--shared-boundary)
  [ -z "$proof_kind" ] || args+=(--proof-surface "$proof_surface")
  block=$(fm_discipline_block ship "${args[@]+"${args[@]}"}") || return 3
  fragment=$(printf '%s' "$block" | fm_discipline_sha /dev/stdin) || {
    fm_discipline_gap 'discipline-capability: SHA256 unavailable'; return 3;
  }
  preimage=$(jq -cS -n --arg task "$task" --arg role "$role" --arg stage "$stage" \
    --arg level "$level" --arg proof_kind "$proof_kind" --arg proof_surface "$proof_surface" \
    --arg outer_generation "$outer_generation" \
    --arg fragment "$fragment" --argjson facts "$facts" \
    '{schema:"fm-worker-discipline.v1",task:$task,role:$role,stage:$stage,level:$level,
      facts:$facts,proof_kind:$proof_kind,proof_surface:$proof_surface,outer_generation:$outer_generation,fragment_sha256:$fragment}') || return 3
  selection=$(printf '%s' "$preimage" | fm_discipline_sha /dev/stdin) || return 3
  generation="d1-$selection"
  FM_DISCIPLINE_RECEIPT=$(printf '%s' "$preimage" | jq -cS --arg generation "$generation" '. + {generation:$generation}') || return 3
  FM_DISCIPLINE_LEVEL=$level
  FM_DISCIPLINE_GENERATION=$generation
  FM_DISCIPLINE_FRAGMENT_SHA256=$fragment
  FM_DISCIPLINE_PROOF_SURFACE=$proof_surface
  return 0
}

fm_discipline_load() { # <data> <task> <ship> <implementation>
  local data=$1 task=$2 role=$3 stage=$4 desc task_dir receipt receipt_task receipt_role receipt_stage
  local proof_kind proof_surface fact compiled args=() outer_generation receipt_outer_generation
  FM_DISCIPLINE_RECEIPT=
  FM_DISCIPLINE_LEVEL=
  FM_DISCIPLINE_GENERATION=
  FM_DISCIPLINE_FRAGMENT_SHA256=
  FM_DISCIPLINE_PROOF_SURFACE=
  task_dir="$data/$task"
  [ -d "$task_dir" ] && [ ! -L "$task_dir" ] || {
    fm_discipline_gap "discipline-artifact: unsafe or missing task directory $task_dir"; return 3;
  }
  desc="$data/$task/work-context.json"
  [ -f "$desc" ] && [ ! -L "$desc" ] || { fm_discipline_gap "discipline-missing: $desc"; return 3; }
  if [ "$FM_DISCIPLINE_DESCRIPTOR_REUSE" -ne 1 ]; then
    FM_DISCIPLINE_DESCRIPTOR_JSON=
    FM_DISCIPLINE_DESCRIPTOR_DIGEST=
    FM_DISCIPLINE_DESCRIPTOR_PATH=
    fm_discipline_descriptor_capture "$desc" || { fm_discipline_gap "discipline-context: unreadable $desc"; return 3; }
  fi
  receipt=$(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -cS '.engineering.discipline // empty' 2>/dev/null) || {
    fm_discipline_gap "discipline-context: malformed $desc"; return 3;
  }
  [ -n "$receipt" ] || { fm_discipline_gap "discipline-missing: $desc"; return 3; }
  if ! printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -c '.engineering.generation' | fm_discipline_generation_json_valid; then
    fm_discipline_gap "discipline-context: malformed engineering generation in $desc"; return 3
  fi
  outer_generation=$(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -r '.engineering.generation')
  receipt_task=$(printf '%s' "$receipt" | jq -r '.task // empty')
  receipt_role=$(printf '%s' "$receipt" | jq -r '.role // empty')
  receipt_stage=$(printf '%s' "$receipt" | jq -r '.stage // empty')
  [ "$receipt_task" = "$task" ] || { fm_discipline_gap "discipline-task: receipt=$receipt_task caller=$task"; return 3; }
  [ "$receipt_role" = "$role" ] && [ "$receipt_stage" = "$stage" ] || {
    fm_discipline_gap "discipline-applicability: receipt=$receipt_role/$receipt_stage caller=$role/$stage"; return 3;
  }
  if ! printf '%s' "$receipt" | jq -c '.outer_generation' | fm_discipline_generation_json_valid; then
    fm_discipline_gap 'discipline-identity: malformed receipt generation'; return 3
  fi
  receipt_outer_generation=$(printf '%s' "$receipt" | jq -r '.outer_generation')
  [ "$receipt_outer_generation" = "$outer_generation" ] || {
    fm_discipline_gap 'discipline-identity: outer engineering generation changed or is missing'
    return 3
  }
  while IFS= read -r fact; do
    [ -n "$fact" ] && args+=(--fact "$fact")
  done < <(printf '%s' "$receipt" | jq -r '.facts[]?')
  proof_kind=$(printf '%s' "$receipt" | jq -r '.proof_kind // empty')
  proof_surface=$(printf '%s' "$receipt" | jq -j '.proof_surface // empty'; printf '\001')
  proof_surface=${proof_surface%$'\001'}
  [ -z "$proof_kind" ] || args+=(--proof-kind "$proof_kind" --proof-surface "$proof_surface")
  fm_discipline_compile "$task" "$role" "$stage" "${args[@]+"${args[@]}"}" --outer-generation "$outer_generation" || return 3
  compiled=$FM_DISCIPLINE_RECEIPT
  [ "$receipt" = "$compiled" ] || {
    fm_discipline_gap 'discipline-identity: selection, generation or fragment identity changed or was tampered'
    return 3
  }
  return 0
}

_fm_discipline_prepare_locked() { # <data> <task> [typed compiler arguments]
  local data=$1 task=$2 task_dir desc tmp tmp_dir current existing='' outer_generation desc_exists=0
  local original_descriptor_json='' original_descriptor_digest='' intended_descriptor_json='' intended_descriptor_digest='' intended_descriptor_mode=''
  local compile_args=()
  shift 2
  task_dir="$data/$task"
  if [ -e "$task_dir" ] || [ -L "$task_dir" ]; then
    [ -d "$task_dir" ] && [ ! -L "$task_dir" ] || {
      fm_discipline_gap "discipline-artifact: unsafe task directory $task_dir"; return 3;
    }
  fi
  desc="$task_dir/work-context.json"
  if [ -e "$desc" ] || [ -L "$desc" ]; then
    [ -f "$desc" ] && [ ! -L "$desc" ] || {
      fm_discipline_gap "discipline-artifact: unsafe descriptor $desc"; return 3;
    }
    desc_exists=1
    FM_DISCIPLINE_DESCRIPTOR_JSON=
    FM_DISCIPLINE_DESCRIPTOR_DIGEST=
    FM_DISCIPLINE_DESCRIPTOR_PATH=
    fm_discipline_descriptor_capture "$desc" || {
      fm_discipline_gap "discipline-context: unreadable $desc"; return 3;
    }
    original_descriptor_json=$FM_DISCIPLINE_DESCRIPTOR_JSON
    original_descriptor_digest=$FM_DISCIPLINE_DESCRIPTOR_DIGEST
    printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -se 'length == 1 and (.[0]|type == "object")' >/dev/null 2>&1 || {
      fm_discipline_gap "discipline-context: malformed $desc"; return 3;
    }
    existing=$(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -cS '.engineering.discipline // empty') || return 3
  fi
  if [ "$desc_exists" -eq 1 ]; then
    outer_generation=$(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON" | jq -r '.engineering.generation // empty') || return 3
  else
    outer_generation=
  fi
  if [ -z "$outer_generation" ]; then
    fm_discipline_compile "$task" ship implementation "$@" || return 3
    outer_generation=$FM_DISCIPLINE_GENERATION
  fi
  compile_args=("$@" --outer-generation "$outer_generation")
  fm_discipline_compile "$task" ship implementation "${compile_args[@]}" || return 3
  current=$FM_DISCIPLINE_RECEIPT
  if [ -n "$existing" ]; then
    [ "$existing" = "$current" ] || {
      fm_discipline_gap 'discipline-selection-immutable: an existing task selection cannot be rewritten'
      return 3
    }
    return 0
  fi
  mkdir -p "$data/$task" || { fm_discipline_gap "discipline-write: cannot create $data/$task"; return 3; }
  [ -d "$task_dir" ] && [ ! -L "$task_dir" ] || {
    fm_discipline_gap "discipline-artifact: task directory changed during preparation"; return 3;
  }
  tmp_dir=$(umask 077; mktemp -d "$data/$task/.discipline-prepare.XXXXXX") || {
    fm_discipline_gap 'discipline-write: temporary directory creation failed'; return 3;
  }
  [ -d "$tmp_dir" ] && [ ! -L "$tmp_dir" ] || { rmdir "$tmp_dir" 2>/dev/null || true; return 3; }
  tmp=$(umask 077; mktemp "$tmp_dir/work-context.XXXXXX") || { rmdir "$tmp_dir"; return 3; }
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true; return 3; }
  if [ "$desc_exists" -eq 1 ]; then
    jq --argjson discipline "$current" --arg generation "$outer_generation" '
    .engineering = ((.engineering // {triggers:[],skills:[],verification:[]}) +
      {generation:$generation,discipline:$discipline}) |
    .engineering.triggers = (.engineering.triggers // []) |
    .engineering.skills = (.engineering.skills // []) |
    .engineering.verification = (.engineering.verification // [])
    ' <(printf '%s' "$FM_DISCIPLINE_DESCRIPTOR_JSON") > "$tmp" || { rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true; fm_discipline_gap 'discipline-write: descriptor merge failed'; return 3; }
  else
    printf '%s\n' '{}' | jq --argjson discipline "$current" --arg generation "$outer_generation" '
      {engineering:{triggers:[],skills:[],verification:[],generation:$generation,discipline:$discipline}}
    ' > "$tmp" || { rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true; fm_discipline_gap 'discipline-write: descriptor merge failed'; return 3; }
  fi
  fm_discipline_capture "$tmp" || {
    rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true
    fm_discipline_gap 'discipline-write: temporary descriptor verification failed'; return 3;
  }
  intended_descriptor_json=$(<"$FM_DISCIPLINE_CAPTURE_PATH")
  intended_descriptor_digest=$FM_DISCIPLINE_CAPTURE_SHA256
  intended_descriptor_mode=$FM_DISCIPLINE_CAPTURE_MODE
  fm_discipline_capture_cleanup
  if [ "$desc_exists" -eq 1 ]; then
    fm_discipline_capture "$desc" || {
      rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true
      fm_discipline_gap 'discipline-write: descriptor changed during preparation'; return 3;
    }
    if [ "$FM_DISCIPLINE_CAPTURE_SHA256" != "$original_descriptor_digest" ] ||
      [ "$(<"$FM_DISCIPLINE_CAPTURE_PATH")" != "$original_descriptor_json" ]; then
      fm_discipline_capture_cleanup
      rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true
      fm_discipline_gap 'discipline-write: descriptor changed during preparation'; return 3;
    fi
    fm_discipline_capture_cleanup
  elif [ -e "$desc" ] || [ -L "$desc" ]; then
    rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true
    fm_discipline_gap 'discipline-write: descriptor appeared during preparation'; return 3;
  fi
  if [ "$desc_exists" -eq 1 ]; then
    mv -f "$tmp" "$desc" || { rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true; fm_discipline_gap 'discipline-write: descriptor publish failed'; return 3; }
  else
    ln "$tmp" "$desc" || { rm -f "$tmp"; rmdir "$tmp_dir" 2>/dev/null || true; fm_discipline_gap 'discipline-write: descriptor publish raced or failed'; return 3; }
  fi
  rm -f "$tmp"
  fm_discipline_capture "$desc" || {
    rmdir "$tmp_dir" 2>/dev/null || true
    fm_discipline_gap 'discipline-write: published descriptor verification failed'; return 3;
  }
  if [ "$FM_DISCIPLINE_CAPTURE_SHA256" != "$intended_descriptor_digest" ] ||
    [ "$FM_DISCIPLINE_CAPTURE_MODE" != "$intended_descriptor_mode" ] ||
    [ "$(<"$FM_DISCIPLINE_CAPTURE_PATH")" != "$intended_descriptor_json" ]; then
    fm_discipline_capture_cleanup
    rmdir "$tmp_dir" 2>/dev/null || true
    fm_discipline_gap 'discipline-write: published descriptor changed during verification'; return 3;
  fi
  fm_discipline_capture_cleanup
  rmdir "$tmp_dir" 2>/dev/null || true
  return 0
}

fm_discipline_prepare() { # <data> <task> [typed compiler arguments]
  local lock_path lock_acquired=0 rc
  lock_path=${FM_DISCIPLINE_WRITER_LOCK_PATH:-${STATE:-}/.control-$2.lock}
  if [ "${FM_DISCIPLINE_WRITER_LOCK_HELD:-0}" -ne 1 ]; then
    command -v fm_lock_try_acquire >/dev/null 2>&1 || {
      fm_discipline_gap 'discipline-write: authoritative writer lock unavailable'
      return 3
    }
    fm_lock_try_acquire "$lock_path" || {
      fm_discipline_gap 'discipline-write: another lifecycle action is already running'
      return 3
    }
    lock_acquired=1
  fi
  FM_DISCIPLINE_WRITER_LOCK_HELD=1
  _fm_discipline_prepare_locked "$@"
  rc=$?
  if [ "$lock_acquired" -eq 1 ]; then
    FM_DISCIPLINE_WRITER_LOCK_HELD=0
    fm_lock_release "$lock_path" || rc=3
  fi
  return "$rc"
}

fm_discipline_render() { # <data> <task> <ship> <implementation>
  local data=$1 task=$2 role=$3 stage=$4 block first rest tail
  fm_discipline_load "$data" "$task" "$role" "$stage" || return 3
  fm_discipline_render_loaded "$data" "$task" "$role" "$stage"
}

fm_discipline_render_loaded() { # <data> <task> <ship> <implementation>
  local data=$1 task=$2 role=$3 stage=$4 block first rest tail
  local args=() shared
  shared=$(printf '%s' "$FM_DISCIPLINE_RECEIPT" | jq -r '[.facts[] | select(. == "shared-api" or . == "schema" or . == "persisted-state" or . == "authority" or . == "lifecycle" or . == "identity" or . == "provenance" or . == "sibling-invariant")] | length')
  [ "$shared" -eq 0 ] || args+=(--shared-boundary)
  [ "$FM_DISCIPLINE_LEVEL" != proof-surface ] || args+=(--proof-surface "$FM_DISCIPLINE_PROOF_SURFACE")
  block=$(fm_discipline_block ship "${args[@]+"${args[@]}"}") || return 3
  first=${block%%$'\n'*}
  rest=${block#*$'\n'}
  printf '%s\n' "$first"
  printf 'Discipline receipt: task=%s role=%s stage=%s level=%s generation=%s fragment-sha256=%s. Candidate proof is validator evidence, never qualification or landing authority.\n' \
    "$task" "$role" "$stage" "$FM_DISCIPLINE_LEVEL" "$FM_DISCIPLINE_GENERATION" "$FM_DISCIPLINE_FRAGMENT_SHA256"
  printf '%s' "$rest"
}

fm_discipline_evidence() { # <data> <task> <run> <exact-head>
  local data=$1 task=$2 run=$3 head=$4 index proof path expected actual shared index_json
  local generation
  FM_DISCIPLINE_PROOF_OUTCOME=
  fm_discipline_load "$data" "$task" ship implementation || return 3
  generation=$(printf '%s' "$FM_DISCIPLINE_RECEIPT" | jq -r '.outer_generation') || return 3
  index="$data/$task/engineering-evidence.json"
  fm_discipline_capture "$index" || { fm_discipline_gap "discipline-evidence-unreadable: $index"; return 3; }
  index_json=$(<"$FM_DISCIPLINE_CAPTURE_PATH")
  FM_DISCIPLINE_EVIDENCE_INDEX_JSON=$index_json
  FM_DISCIPLINE_EVIDENCE_INDEX_DIGEST=$FM_DISCIPLINE_CAPTURE_SHA256
  FM_DISCIPLINE_EVIDENCE_INDEX_PATH=$index
  fm_discipline_capture_cleanup
  if [ -z "$run" ] || ! printf '%s' "$head" | grep -Eq '^[0-9a-f]{40}$' ||
    ! jq -se --arg task "$task" --arg run "$run" --arg head "$head" --arg generation "$generation" '
      length == 1 and (.[0] | .task == $task and .run == $run and .head == $head and .generation == $generation and
      (.results|type == "array") and (.results|map(.id)|length == (unique|length)))
    ' <(printf '%s' "$index_json") >/dev/null 2>&1; then
    fm_discipline_gap "discipline-evidence-identity: $index requires current task/run/head"
    return 3
  fi
  proof=$(printf '%s' "$index_json" | jq -c '.results[] | select(.id == "worker-discipline")' 2>/dev/null) || return 3
  [ -n "$proof" ] || { fm_discipline_gap 'discipline-evidence-missing: worker-discipline candidate evidence is required'; return 3; }
  if ! printf '%s' "$proof" | jq -e --arg task "$task" --arg generation "$FM_DISCIPLINE_GENERATION" \
      --arg level "$FM_DISCIPLINE_LEVEL" --arg fragment "$FM_DISCIPLINE_FRAGMENT_SHA256" \
      --argjson receipt "$FM_DISCIPLINE_RECEIPT" '
    (keys|sort) == ["discipline","id"] and
    (.discipline|type == "object") and
    (.discipline|keys|sort) == ["command","fragment_sha256","generation","level","oracle","outcome","path","producer","role","safety_facts","sha256","stage","surface","task"] and
    .discipline.task == $task and .discipline.role == "ship" and .discipline.stage == "implementation" and
    .discipline.generation == $generation and .discipline.level == $level and
    .discipline.fragment_sha256 == $fragment and .discipline.producer == "worker-candidate" and
    (.discipline.outcome == "OBSERVED" or .discipline.outcome == "CNO") and
    .discipline.surface == $receipt.proof_surface and
    ($level != "proof-surface" or .discipline.command == $receipt.proof_surface) and
    all([.discipline.command,.discipline.oracle,.discipline.path,.discipline.sha256][];
      type == "string" and length > 0) and
    (.discipline.path|startswith("/")) and
    (.discipline.sha256|test("^[0-9a-f]{64}$")) and
    (.discipline.safety_facts|type == "array") and
    (.discipline.safety_facts|all(type == "string" and length > 0))
  ' >/dev/null 2>&1; then
    fm_discipline_gap 'discipline-evidence-invalid: candidate evidence identity, outcome or artifact binding does not match the selected discipline'
    return 3
  fi
  shared=$(printf '%s' "$FM_DISCIPLINE_RECEIPT" | jq '[.facts[] | select(. == "shared-api" or . == "schema" or . == "persisted-state" or . == "authority" or . == "lifecycle" or . == "identity" or . == "provenance" or . == "sibling-invariant")] | length')
  if [ "$shared" -gt 0 ] && [ "$(printf '%s' "$proof" | jq '.discipline.safety_facts | length')" -eq 0 ]; then
    fm_discipline_gap 'discipline-evidence-safety-facts: shared-boundary evidence requires at least one explicit safety fact'
    return 3
  fi
  path=$(printf '%s' "$proof" | jq -r .discipline.path)
  expected=$(printf '%s' "$proof" | jq -r .discipline.sha256)
  fm_discipline_capture "$path" || { fm_discipline_gap "discipline-evidence-unreadable: $path"; return 3; }
  actual=$FM_DISCIPLINE_CAPTURE_SHA256
  fm_discipline_capture_cleanup
  [ "$actual" = "$expected" ] || { fm_discipline_gap "discipline-evidence-stale: $path"; return 3; }
  # shellcheck disable=SC2034 # Result consumed by work-context and stage callers.
  FM_DISCIPLINE_PROOF_OUTCOME=$(printf '%s' "$proof" | jq -r .discipline.outcome)
  return 0
}

fm_discipline_envelope_render() { # <data> <task>
  local data=$1 task=$2 begin end
  fm_discipline_load "$data" "$task" ship implementation || return 3
  begin="<!-- firstmate-discipline:v1 begin generation=$FM_DISCIPLINE_GENERATION fragment=$FM_DISCIPLINE_FRAGMENT_SHA256 -->"
  end="<!-- firstmate-discipline:v1 end generation=$FM_DISCIPLINE_GENERATION fragment=$FM_DISCIPLINE_FRAGMENT_SHA256 -->"
  printf '%s\n' "$begin"
  fm_discipline_render_loaded "$data" "$task" ship implementation
  printf '\n%s\n' "$end"
}

fm_discipline_envelope_validate() { # <data> <task> <artifact> <successor-prefix>
  local data=$1 task=$2 artifact=$3 successor=$4 bytes tmp_dir captured_artifact
  local expected_file actual_file combined_file
  tmp_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-discipline-envelope.XXXXXX") || {
    fm_discipline_gap 'discipline-artifact: temporary directory creation failed'; return 3;
  }
  chmod 700 "$tmp_dir" 2>/dev/null || {
    rmdir "$tmp_dir" 2>/dev/null || true
    fm_discipline_gap 'discipline-artifact: temporary directory permission failed'; return 3;
  }
  [ -d "$tmp_dir" ] && [ ! -L "$tmp_dir" ] || {
    rmdir "$tmp_dir" 2>/dev/null || true
    fm_discipline_gap 'discipline-artifact: unsafe temporary directory'; return 3;
  }
  expected_file=$(umask 077; mktemp "$tmp_dir/expected.XXXXXX") || { rmdir "$tmp_dir"; return 3; }
  actual_file=$(umask 077; mktemp "$tmp_dir/actual.XXXXXX") || { rm -f "$expected_file"; rmdir "$tmp_dir"; return 3; }
  combined_file=$(umask 077; mktemp "$tmp_dir/combined.XXXXXX") || { rm -f "$expected_file" "$actual_file"; rmdir "$tmp_dir"; return 3; }
  [ -f "$expected_file" ] && [ ! -L "$expected_file" ] &&
    [ -f "$actual_file" ] && [ ! -L "$actual_file" ] &&
    [ -f "$combined_file" ] && [ ! -L "$combined_file" ] || {
      rm -f "$expected_file" "$actual_file" "$combined_file"
      rmdir "$tmp_dir" 2>/dev/null || true
      fm_discipline_gap 'discipline-artifact: unsafe temporary comparison file'
      return 3
    }
  fm_discipline_envelope_render "$data" "$task" > "$expected_file" || {
    rm -f "$expected_file" "$actual_file" "$combined_file"; rmdir "$tmp_dir" 2>/dev/null || true; return 3;
  }
  { cat "$expected_file"; printf '%s\n' "$successor"; } > "$combined_file" || {
    rm -f "$expected_file" "$actual_file" "$combined_file"; rmdir "$tmp_dir" 2>/dev/null || true; return 3;
  }
  bytes=$(wc -c < "$combined_file") || {
    rm -f "$expected_file" "$actual_file" "$combined_file"; rmdir "$tmp_dir" 2>/dev/null || true; return 3;
  }
  fm_discipline_capture "$artifact" || {
    rm -f "$expected_file" "$actual_file" "$combined_file"
    rmdir "$tmp_dir" 2>/dev/null || true
    fm_discipline_gap "discipline-artifact: unsafe or unreadable $artifact"
    return 3
  }
  captured_artifact=$FM_DISCIPLINE_CAPTURE_PATH
  FM_DISCIPLINE_ARTIFACT_BYTES=$(<"$captured_artifact")
  FM_DISCIPLINE_ARTIFACT_DIGEST=$FM_DISCIPLINE_CAPTURE_SHA256
  head -c "$bytes" "$captured_artifact" > "$actual_file" 2>/dev/null || true
  if ! cmp -s "$combined_file" "$actual_file"; then
    fm_discipline_capture_cleanup
    rm -f "$expected_file" "$actual_file" "$combined_file"
    rmdir "$tmp_dir" 2>/dev/null || true
    fm_discipline_gap 'discipline-artifact: fixed envelope slot or successor prefix changed'
    return 3
  fi
  fm_discipline_capture_cleanup
  rm -f "$expected_file" "$actual_file" "$combined_file"
  rmdir "$tmp_dir" 2>/dev/null || true
  return 0
}

fm_discipline_brief() { # <data> <task> <ship|scout|secondmate> <brief>
  local data=$1 task=$2 kind=$3 brief=$4
  case "$kind" in
    secondmate) return 0 ;;
    scout) return 0 ;;
    ship) ;;
    *) fm_discipline_gap "discipline-role: unknown kind $kind"; return 3 ;;
  esac
  if ! fm_discipline_envelope_validate "$data" "$task" "$brief" \
    'You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.'; then
    fm_discipline_gap 'discipline-brief: fixed envelope slot or successor prefix changed'
    return 3
  fi
}
