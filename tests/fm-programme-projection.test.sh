#!/usr/bin/env bash
# tests/fm-programme-projection.test.sh - the programme projection substrate
# (bin/fm-programme-projection.sh) as a stateless composition over the
# continuation owner (bin/fm-continuation-resolve.sh): its typed authority
# fields equal the resolver's for the same canonical state, its applicability
# tuple goes stale on every structural change, it returns delegation bounds
# without enforcing them, and a call writes nothing anywhere.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/bin/fm-programme-projection.sh"
RESOLVE="$ROOT/bin/fm-continuation-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-projection)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# shellcheck source=bin/fm-continuation-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-continuation-lib.sh"

# --- fixtures ------------------------------------------------------------------

# Every tasks-axi call the substrate (through the resolver) makes is logged by
# this shim before being forwarded to the real tool, so the suite can prove the
# substrate only ever reads the backlog.
REAL_TASKS_AXI=$(command -v tasks-axi)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
AXI_LOG="$TMP_ROOT/tasks-axi.log"
cat > "$FAKEBIN/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$AXI_LOG'
exec '$REAL_TASKS_AXI' "\$@"
SH
chmod +x "$FAKEBIN/tasks-axi"
export PATH="$FAKEBIN:$PATH"

# make_home <name> [jq-filter]: an isolated FM_HOME with an empty tasks-axi
# backlog, a programme root, and config/programme pointing at the pinned file.
make_home() {  # <name> [jq-filter]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/cleanroom/artifacts/proofs"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  write_programme "$home" "${2:-.}"
  printf 'programme=%s\nroot=%s\n' "$home/cleanroom/programme.json" "$home/cleanroom" > "$home/config/programme"
  printf '%s\n' "$home"
}

# write_programme <home> [jq-filter]: a two-proof sequence under a standing
# grant with one reserved axis; the filter mutates it.
write_programme() {  # <home> [jq-filter]
  local home=$1 filter=${2:-.}
  jq "$filter" <<'JSON' > "$home/cleanroom/programme.json"
{
  "schema": "fm-requal-programme/v1",
  "programme_id": "cleanroom-requalification",
  "authorization_basis": {
    "kind": "standing_sequence_grant",
    "refs": ["control#3 requalification programme"]
  },
  "reserved_axes": ["new_paid_spend", "destructive_or_irreversible"],
  "steps": [
    {"id": "proof-a", "title": "fresh Proof A", "artifact_root": "artifacts/proofs/proof-a",
     "terminal_predicate": {"kind": "latest_attempt_disposition_outcome_in", "accept": ["PROVED"]},
     "classification_when_next": "SELF_HANDLE"},
    {"id": "proof-b", "title": "fresh Proof B", "artifact_root": "artifacts/proofs/proof-b",
     "terminal_predicate": {"kind": "latest_attempt_disposition_outcome_in", "accept": ["PROVED"]},
     "classification_when_next": "SELF_HANDLE"},
    {"id": "review", "title": "architecture review", "artifact_root": "artifacts/proofs/review",
     "terminal_predicate": {"kind": "latest_attempt_disposition_outcome_in", "accept": ["PROVED"]},
     "classification_when_next": "SELF_HANDLE"}
  ]
}
JSON
}

disposition() {  # <home> <proof> <attempt> <outcome>
  local dir="$1/cleanroom/artifacts/proofs/$2/attempt-$3"
  mkdir -p "$dir"
  jq -n --arg o "$4" '{schema:"fm-proof-disposition/v1", outcome:$o}' > "$dir/disposition.json"
}

# The compatibility verdict is passed in so the captain-hold owner's probes are
# skipped; the skip guard above already proved tasks-axi present. The date is
# pinned so the resolver's own tuple is stable across the two calls a
# determinism check makes.
with_home() {  # <home> <command...>
  local home=$1
  shift
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-05 "$@"
}

run_project() {  # <home> [args...]
  local home=$1
  shift
  with_home "$home" "$PROJECT" "$@"
}

run_resolve() {  # <home> [args...]
  local home=$1
  shift
  with_home "$home" "$RESOLVE" "$@"
}

tasks_in() {  # <home> [tasks-axi args...]
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

# bound_hold <home> <id> <kind> <action> <axis> <programme> <wait>: a held task
# carrying the typed binding line the captain-hold owner writes.
bound_hold() {  # <home> <id> <kind> <action> <axis> <programme> <wait>
  local home=$1 id=$2 kind=$3 line
  line=$(fm_continuation_binding_line "$4" "$6" "$5" "$7")
  tasks_in "$home" add "$id" "fixture $id" --kind task --body "$line" >/dev/null || fail "could not add $id"
  tasks_in "$home" hold "$id" --reason "fixture hold on $id" --kind "$kind" >/dev/null || fail "could not hold $id"
}

field() {  # <json> <jq-path>
  printf '%s' "$1" | jq -r "$2"
}

# A content snapshot of every path under <dir>: the path set plus each regular
# file's digest, so a created, removed, or rewritten file shows up.
tree_snapshot() {  # <dir>
  (cd "$1" && find . -print | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null)
}

# assert_composed <home> <label>: the substrate's authority fields equal the
# resolver's for the same canonical state, field for field.
assert_composed() {  # <home> <label>
  local home=$1 label=$2 proj res key
  proj=$(run_project "$home" project) || fail "$label: project failed: $proj"
  res=$(run_resolve "$home" resolve) || fail "$label: resolve failed: $res"
  for key in next_action next_action_title action_generation classification authority_state reason_code basis_refs; do
    [ "$(field "$proj" ".$key | tojson")" = "$(field "$res" ".$key | tojson")" ] \
      || fail "$label: $key diverges from the resolver: $(field "$proj" ".$key | tojson") != $(field "$res" ".$key | tojson")"
  done
  [ "$(field "$proj" '.resolver.applicability_digest')" = "$(field "$res" '.applicability_digest')" ] \
    || fail "$label: the resolver's applicability digest must be carried verbatim"
  [ "$(field "$proj" '.programme | tojson')" = "$(field "$res" '.programme | tojson')" ] \
    || fail "$label: the programme identity (path, root, sha256) must be the resolver's"
  printf '%s' "$proj"
}

# --- composition: the substrate follows the resolver wherever it goes --------------

test_composition_follows_resolver() {
  local home out
  home=$(make_home compose)
  disposition "$home" proof-a 1 PROVED
  disposition "$home" proof-b 1 CNO_AT_B-S3

  out=$(assert_composed "$home" "authorized")
  [ "$(field "$out" '.schema')" = fm-programme-projection/v1 ] || fail "schema"
  [ "$(field "$out" '.next_action')" = proof-b ] || fail "next action is proof-b"
  [ "$(field "$out" '.classification')/$(field "$out" '.authority_state')/$(field "$out" '.reason_code')" = SELF_HANDLE/AUTHORIZED/STANDING_GRANT ] \
    || fail "authorized continuation is composed verbatim"
  [ "$(field "$out" '.phase')" = proof-b ] || fail "a step with no phase field is its own phase"
  [ "$(field "$out" '.phase_generation')" = 1 ] || fail "phase generation counts proof-b's one attempt"
  [ "$(field "$out" '.action_generation')" = 2 ] || fail "action generation is the resolver's"
  [ "$(field "$out" '.work_generation')" = null ] || fail "no bound task meta means a null worker epoch"
  [ "$(field "$out" '.programme.root')" = "$home/cleanroom" ] || fail "the artifact root is the one the resolver located"
  case "$(field "$out" '.applicability.predecessor_disposition.disposition')" in
    "$home/cleanroom/"*) ;;
    *) fail "the predecessor disposition path resolves against the resolver's root" ;;
  esac
  pass "an authorized continuation is composed verbatim from the resolver with its own phase fields added"

  # Drive the resolver to CAPTAIN through a bound reserved-axis captain hold;
  # the substrate must follow without a classification table of its own.
  bound_hold "$home" spend-call captain proof-b new_paid_spend cleanroom-requalification ''
  out=$(assert_composed "$home" "captain")
  [ "$(field "$out" '.classification')/$(field "$out" '.authority_state')/$(field "$out" '.reason_code')" = CAPTAIN/REQUIRES_CAPTAIN/HOLD_RESERVED_AXIS ] \
    || fail "captain hold: composed result must be CAPTAIN/REQUIRES_CAPTAIN/HOLD_RESERVED_AXIS"
  [ "$(field "$out" '.resolver.holds.gating | tojson')" = '["spend-call"]' ] || fail "the gating hold is carried by task id"
  pass "a bound reserved-axis captain hold moves the resolver to CAPTAIN and the substrate follows"

  # Lift it and bind a Browser Sol ruling wait instead.
  tasks_in "$home" unhold spend-call >/dev/null || fail "could not lift spend-call"
  bound_hold "$home" sol-ruling external proof-b '' '' ruling
  out=$(assert_composed "$home" "ruling")
  [ "$(field "$out" '.classification')/$(field "$out" '.authority_state')/$(field "$out" '.reason_code')" = BROWSER_SOL/REQUIRES_RULING/HOLD_RULING_WAIT ] \
    || fail "ruling wait: composed result must be BROWSER_SOL/REQUIRES_RULING/HOLD_RULING_WAIT"
  pass "a bound ruling wait moves the resolver to BROWSER_SOL and the substrate follows"

  # A complete programme: no next action, no phase, bounds still reported.
  tasks_in "$home" unhold sol-ruling >/dev/null || fail "could not lift sol-ruling"
  disposition "$home" proof-b 2 PROVED
  disposition "$home" review 1 PROVED
  out=$(assert_composed "$home" "complete")
  [ "$(field "$out" '.next_action')" = null ] || fail "complete: next_action null"
  [ "$(field "$out" '.reason_code')" = PROGRAMME_COMPLETE ] || fail "complete: reason PROGRAMME_COMPLETE"
  [ "$(field "$out" '.phase')" = null ] && [ "$(field "$out" '.phase_generation')" = null ] || fail "complete: phase fields null"
  [ "$(field "$out" '.delegation.concurrency.ceiling')" = 2 ] || fail "complete: bounds still reported"
  pass "a complete programme composes as complete with null phase and still reports bounds"
}

# --- applicability: every structural change makes a prior tuple non-matching ---------

test_applicability_tuple_goes_stale() {
  local home wt base moved k
  home=$(make_home stale '.steps[0].phase = "proofs" | .steps[1].phase = "proofs"')
  disposition "$home" proof-a 1 PROVED
  disposition "$home" proof-b 1 CNO_AT_B-S3
  wt="$TMP_ROOT/stale-wt"
  fm_git_init_commit "$wt"
  fm_write_meta "$home/state/proof-b.meta" "spawn_gen=1" "worktree=$wt" "pr_head=0123456789abcdef0123456789abcdef01234567"

  base=$(run_project "$home" project) || fail "baseline project failed: $base"
  [ "$(field "$base" '.applicability.phase_id')" = proofs ] || fail "phase id from the step's phase field"
  [ "$(field "$base" '.applicability.phase_generation')" = 2 ] || fail "phase generation counts attempts across proof-a and proof-b"
  [ "$(field "$base" '.delegation.phase_steps | tojson')" = '["proof-a","proof-b"]' ] || fail "phase steps"
  [ "$(field "$base" '.applicability.work_generation')" = 1 ] || fail "work generation is the bound task's spawn_gen"
  [ "$(field "$base" '.applicability.candidate_identity.head')" = "$(git -C "$wt" rev-parse HEAD)" ] || fail "candidate head is the worktree HEAD"
  [ "$(field "$base" '.applicability.candidate_identity.tree')" = "$(git -C "$wt" rev-parse 'HEAD^{tree}')" ] || fail "candidate tree is the worktree tree"
  [ "$(field "$base" '.applicability.candidate_identity.pr_head')" = 0123456789abcdef0123456789abcdef01234567 ] || fail "pr_head is read from meta"
  [ "$(field "$base" '.applicability.hold_grant_generation | length')" = 64 ] || fail "hold/grant generation is a sha256"
  [ "$(field "$base" '.applicability_digest | length')" = 64 ] || fail "applicability digest is a sha256"
  pass "the applicability tuple binds phase, generations, worker epoch, candidate head and tree, predecessor, and hold/grant identity"

  # A moved candidate head and tree: only the candidate member changes.
  printf 'moved\n' >> "$wt/README.md"
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -qam moved
  moved=$(run_project "$home" project) || fail "moved-head project failed"
  [ "$(field "$moved" '.applicability_digest')" != "$(field "$base" '.applicability_digest')" ] || fail "a moved head must change the applicability digest"
  [ "$(field "$moved" '.applicability.candidate_identity.head')" != "$(field "$base" '.applicability.candidate_identity.head')" ] || fail "head member moved"
  for k in phase_generation work_generation hold_grant_generation resolver_applicability_digest; do
    [ "$(field "$moved" ".applicability.$k")" = "$(field "$base" ".applicability.$k")" ] || fail "a moved head must leave $k unchanged"
  done
  pass "a moved candidate head or tree makes the prior tuple non-matching while every other member holds"

  # A new worker epoch.
  fm_write_meta "$home/state/proof-b.meta" "spawn_gen=2" "worktree=$wt"
  base=$moved
  moved=$(run_project "$home" project) || fail "new-epoch project failed"
  [ "$(field "$moved" '.work_generation')" = 2 ] || fail "work generation follows spawn_gen"
  [ "$(field "$moved" '.applicability_digest')" != "$(field "$base" '.applicability_digest')" ] || fail "a new worker epoch must change the digest"
  pass "a new worker epoch makes the prior tuple non-matching"

  # A new attempt: phase and action generations advance together.
  mkdir -p "$home/cleanroom/artifacts/proofs/proof-b/attempt-2"
  base=$moved
  moved=$(run_project "$home" project) || fail "new-attempt project failed"
  [ "$(field "$moved" '.phase_generation')" = 3 ] || fail "a new attempt advances the phase generation"
  [ "$(field "$moved" '.action_generation')" = 3 ] || fail "the resolver's action generation advances"
  [ "$(field "$moved" '.reason_code')" = NEWER_ATTEMPT_WITHOUT_DISPOSITION ] || fail "the resolver's CNO reason is composed verbatim"
  [ "$(field "$moved" '.applicability_digest')" != "$(field "$base" '.applicability_digest')" ] || fail "a new attempt must change the digest"
  pass "a new attempt makes the prior tuple non-matching"

  # A hold appears, then is lifted: the lifted state equals never-held, because
  # a lifted record is non-authoritative rather than a second store entry.
  disposition "$home" proof-b 2 CNO_AT_B-S5
  base=$(run_project "$home" project) || fail "pre-hold project failed"
  bound_hold "$home" spend-call captain proof-b new_paid_spend cleanroom-requalification ''
  moved=$(run_project "$home" project) || fail "held project failed"
  [ "$(field "$moved" '.applicability.hold_grant_generation')" != "$(field "$base" '.applicability.hold_grant_generation')" ] || fail "a gating hold must change the hold/grant generation"
  [ "$(field "$moved" '.classification')" = CAPTAIN ] || fail "held: CAPTAIN"
  tasks_in "$home" unhold spend-call >/dev/null || fail "could not lift spend-call"
  moved=$(run_project "$home" project) || fail "lifted project failed"
  [ "$(field "$moved" '.applicability.hold_grant_generation')" = "$(field "$base" '.applicability.hold_grant_generation')" ] || fail "a lifted hold is non-authoritative: the tuple returns to the never-held identity"
  [ "$(field "$moved" '.applicability_digest')" = "$(field "$base" '.applicability_digest')" ] || fail "lifted equals never-held"
  pass "a gating hold changes the tuple and a lifted hold restores the never-held identity"

  # A superseded grant.
  write_programme "$home" '.steps[0].phase = "proofs" | .steps[1].phase = "proofs" | .authorization_basis.superseded_by = "control#9"'
  moved=$(assert_composed "$home" "superseded")
  [ "$(field "$moved" '.applicability.hold_grant_generation')" != "$(field "$base" '.applicability.hold_grant_generation')" ] || fail "a superseded grant must change the hold/grant generation"
  [ "$(field "$moved" '.reason_code')" = GRANT_SUPERSEDED ] && [ "$(field "$moved" '.authority_state')" = CNO ] || fail "the resolver's superseded-grant CNO is composed verbatim"
  pass "a superseded grant makes the prior tuple non-matching and the composed authority follows the resolver"
}

# --- records that cannot be composed are refused, never nulled -----------------------

test_uncomposable_records_refused() {
  local home wt out err rc
  home=$(make_home refuse)
  disposition "$home" proof-a 1 PROVED

  # A worktree path that is not a directory is an absent candidate: null.
  fm_write_meta "$home/state/proof-b.meta" "spawn_gen=1" "worktree=$TMP_ROOT/refuse-missing-wt"
  out=$(run_project "$home" project) || fail "absent worktree project failed: $out"
  [ "$(field "$out" '.applicability.candidate_identity | [.head, .tree] | tojson')" = '[null,null]' ] || fail "an absent worktree directory yields a null head and tree"
  pass "an absent worktree directory yields a null candidate head and tree"

  # A worktree directory git cannot read must not collapse to the same null
  # tuple: it is refused, naming the worktree.
  wt="$TMP_ROOT/refuse-wt"
  mkdir -p "$wt"
  fm_write_meta "$home/state/proof-b.meta" "spawn_gen=1" "worktree=$wt"
  err=$(run_project "$home" project 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "an unreadable worktree directory is refused"
  assert_contains "$err" "$wt" "the refusal names the worktree"
  out=$(run_project "$home" project 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] || fail "an unreadable worktree must print no projection on stdout"
  pass "a present worktree whose head and tree git cannot read is refused rather than nulled"

  # Once the same directory is a readable repository the projection binds to it.
  fm_git_init_commit "$wt"
  out=$(run_project "$home" project) || fail "readable worktree project failed: $out"
  [ "$(field "$out" '.applicability.candidate_identity.head')" = "$(git -C "$wt" rev-parse HEAD)" ] || fail "a readable worktree binds its head"
  pass "the same directory, once readable, binds its head and tree"

  # A plain directory nested inside that repository is discoverable by git but
  # is not a work tree: it must be refused, never bound to the parent's head.
  mkdir -p "$wt/nested/plain"
  fm_write_meta "$home/state/proof-b.meta" "spawn_gen=1" "worktree=$wt/nested/plain"
  err=$(run_project "$home" project 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "a plain directory inside a repository is refused"
  assert_contains "$err" "$wt/nested/plain" "the refusal names the recorded worktree"
  assert_contains "$err" "$(cd "$wt" && pwd -P)" "the refusal names the enclosing work tree"
  pass "a plain directory nested inside a repository is refused rather than binding the enclosing head"

  # A linked git worktree is its own work tree and still resolves to its own head.
  git -C "$wt" worktree add --quiet -b linked "$TMP_ROOT/refuse-linked-wt" >/dev/null 2>&1 || fail "could not add a linked worktree"
  printf 'linked\n' >> "$TMP_ROOT/refuse-linked-wt/README.md"
  git -C "$TMP_ROOT/refuse-linked-wt" -c user.name=t -c user.email=t@example.invalid commit -qam linked
  fm_write_meta "$home/state/proof-b.meta" "spawn_gen=1" "worktree=$TMP_ROOT/refuse-linked-wt"
  out=$(run_project "$home" project) || fail "linked worktree project failed: $out"
  [ "$(field "$out" '.applicability.candidate_identity.head')" = "$(git -C "$TMP_ROOT/refuse-linked-wt" rev-parse HEAD)" ] || fail "a linked worktree binds its own head"
  [ "$(field "$out" '.applicability.candidate_identity.head')" != "$(git -C "$wt" rev-parse HEAD)" ] || fail "a linked worktree must not bind the main worktree's head"
  pass "a linked git worktree resolves to its own head and tree"

  # A duplicated step id is not an injective fact identity; the programme is
  # refused even though the resolver walks it positionally.
  write_programme "$home" '.steps[1].id = "proof-a"'
  err=$(run_project "$home" project 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "duplicate step ids are refused"
  assert_contains "$err" "duplicated: proof-a" "the refusal names the duplicated id"
  write_programme "$home"
  out=$(run_project "$home" project) || fail "unique ids project failed: $out"
  [ "$(field "$out" '.next_action')" = proof-b ] || fail "unique ids project again"
  pass "a programme carrying duplicate step ids is refused, naming the id"
}

# --- determinism and zero side effects -----------------------------------------------

test_deterministic_and_side_effect_free() {
  local home wt before after first second head_before
  home=$(make_home pure)
  disposition "$home" proof-a 1 PROVED
  wt="$TMP_ROOT/pure-wt"
  fm_git_init_commit "$wt"
  fm_write_meta "$home/state/proof-b.meta" "spawn_gen=3" "worktree=$wt"
  # A gating hold so the resolver's show path runs through tasks-axi too.
  bound_hold "$home" ci-wait external proof-b '' '' external
  head_before=$(git -C "$wt" rev-parse HEAD)

  before=$(tree_snapshot "$home")
  : > "$AXI_LOG"
  first=$(run_project "$home" project) || fail "first project failed"
  second=$(run_project "$home" project) || fail "second project failed"
  after=$(tree_snapshot "$home")
  [ "$first" = "$second" ] || fail "two calls over unchanged canonical state must be byte-identical"
  [ "$before" = "$after" ] || fail "a projection must create, remove, or rewrite nothing under the home:"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
  [ "$(field "$first" '.classification')" = EXTERNAL_DEPENDENCY ] || fail "external wait composed"
  pass "two calls over unchanged canonical state are identical and persist no store"

  # The only backlog operations are reads.
  [ -s "$AXI_LOG" ] || fail "the resolver must have read the backlog through tasks-axi"
  if grep -vE '^(list|show) ' "$AXI_LOG"; then
    fail "the substrate must never issue a mutating tasks-axi command"
  fi
  pass "every backlog access was a read (list/show); no hold, add, done, or unhold was issued"

  # The candidate worktree is untouched: same head, clean status.
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "the candidate worktree head must not move"
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "the candidate worktree must stay clean"
  pass "reading candidate identity leaves the worktree untouched"
}

# --- delegation: bounds returned, never enforced ------------------------------------

test_delegation_bounds() {
  local home out err rc state_before
  home=$(make_home bounds)
  disposition "$home" proof-a 1 PROVED
  state_before=$(ls -A "$home/state")

  out=$(run_project "$home" project) || fail "default bounds failed"
  [ "$(field "$out" '.delegation.concurrency | [.ceiling, .hard_max, .source, (.ladder | tojson), .hidden_fanout_counts_under_ceiling, .ramps] | join(" ")')" = '2 6 ladder_floor [2,3,4,6] true false' ] \
    || fail "default delegation: $(field "$out" '.delegation.concurrency | tojson')"
  [ "$(field "$out" '.delegation | [.enforces, .picks_model_or_effort, .dispatch_profiles_configured, .enforcer] | join(" ")')" = 'false false false bin/fm-spawn.sh' ] \
    || fail "delegation flags: $(field "$out" '.delegation | tojson')"
  [ "$(field "$out" '.delegation | has("model") or has("effort") or has("harness")')" = false ] || fail "delegation must not pick a model, effort, or harness"
  pass "with no configured ceiling the ladder floor is returned with the enforcer named and no model or effort choice"

  write_programme "$home" '.delegation = {max_concurrency: 4}'
  out=$(run_project "$home" project) || fail "programme ceiling failed"
  [ "$(field "$out" '.delegation.concurrency.ceiling')" = 4 ] && [ "$(field "$out" '.delegation.concurrency.source')" = 'programme:delegation.max_concurrency' ] \
    || fail "programme-level ceiling 4: $(field "$out" '.delegation.concurrency | tojson')"
  write_programme "$home" '.delegation = {max_concurrency: 4} | .steps[1].delegation = {max_concurrency: 6}'
  out=$(run_project "$home" project) || fail "step ceiling failed"
  [ "$(field "$out" '.delegation.concurrency.ceiling')" = 6 ] && [ "$(field "$out" '.delegation.concurrency.source')" = 'programme:steps[1].delegation.max_concurrency' ] \
    || fail "step override ceiling 6: $(field "$out" '.delegation.concurrency | tojson')"
  pass "a configured programme ceiling and a step override are returned as rungs with their source named"

  for bad in 5 8 1 '"4"' 2.5; do
    write_programme "$home" ".delegation = {max_concurrency: $bad}"
    err=$(run_project "$home" project 2>&1 >/dev/null); rc=$?
    expect_code 1 "$rc" "max_concurrency $bad is refused"
    assert_contains "$err" "ladder rung" "refusal names the ladder for $bad"
  done
  write_programme "$home" '.delegation = "loose"'
  err=$(run_project "$home" project 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "a non-object delegation is refused"
  pass "an off-ladder, over-max, or malformed ceiling is refused rather than selected around"

  write_programme "$home"
  printf '{"rules":[],"default":[{"harness":"claude"}]}\n' > "$home/config/crew-dispatch.json"
  out=$(run_project "$home" project) || fail "profiles-present failed"
  [ "$(field "$out" '.delegation.dispatch_profiles_configured')" = true ] || fail "dispatch profiles reported as configured"
  [ "$(field "$out" '.delegation | has("model") or has("effort") or has("harness")')" = false ] || fail "profiles present must not make the substrate pick"
  pass "configured dispatch profiles are reported, never resolved into a model or effort"

  [ "$(ls -A "$home/state")" = "$state_before" ] || fail "returning bounds must spawn nothing and write no task record"
  pass "returning delegation bounds spawns nothing"
}

# --- not applicable, refused authority, summary ------------------------------------------

test_not_configured_and_summary() {
  local home out rc err
  home=$(make_home plain)
  disposition "$home" proof-a 1 PROVED

  out=$(run_project "$home" summary) || fail "summary failed"
  assert_contains "$out" "projection cleanroom-requalification@fm-requal-programme/v1: next=proof-b phase=proof-b@0 gen=1/- SELF_HANDLE/AUTHORIZED reason=STANDING_GRANT ceiling=2 applicability=" "summary token"
  pass "summary prints the one-line typed token"

  err=$(run_project "$home" project --materialize 2>&1 >/dev/null); rc=$?
  expect_code 2 "$rc" "--materialize is refused"
  assert_contains "$err" "no authority to create a hold" "refusal explains the missing authority"
  pass "the substrate refuses --materialize because it holds no hold-creating authority"

  rm "$home/config/programme"
  out=$(run_project "$home" project 2>/dev/null); rc=$?
  expect_code 3 "$rc" "no programme configured"
  [ -z "$out" ] || fail "exit 3 must print nothing on stdout: $out"
  out=$(run_project "$home" summary 2>/dev/null); rc=$?
  expect_code 3 "$rc" "summary with no programme"
  [ -z "$out" ] || fail "summary exit 3 must print nothing on stdout"
  pass "with no programme configured the substrate exits 3 silently, mirroring the resolver"
}

# --- owner-evidence steps compose unchanged -----------------------------------------

# A programme whose A-E steps are bound to accepted owner records (the A-F
# package shape): the substrate's authority fields are still the resolver's
# verbatim, owner-evidence steps count no attempts, and the pilot's ceiling
# is the configured rung.
test_owner_evidence_programme_composes() {
  local home out prog
  home=$(make_home owner-evidence)
  prog="$home/cleanroom/programme.json"
  mkdir -p "$home/cleanroom/evidence" "$home/cleanroom/artifacts/proofs/proof-b/attempt-3"
  jq -n '{schema:"fm-proof-disposition/v1", outcome:"CNO_AT_B-S9"}' > "$home/cleanroom/artifacts/proofs/proof-b/attempt-3/disposition.json"
  local psha
  psha=$(shasum -a 256 "$home/cleanroom/artifacts/proofs/proof-b/attempt-3/disposition.json" 2>/dev/null | awk '{print $1}' || sha256sum "$home/cleanroom/artifacts/proofs/proof-b/attempt-3/disposition.json" | awk '{print $1}')
  jq -n --arg psha "$psha" '{schema:"fm-accepted-owner-evidence/v1", evidence_id:"ev-ruling", programme_id:"cleanroom-af-package", step:"ruling",
    work_id:"cleanroom-af-package", owner:{kind:"control_ruling", ref:"control#3#issuecomment-5554585623"}, outcome:"PROCEED_WITH_CONDITIONS",
    sources:[{kind:"local_file", path:"artifacts/proofs/proof-b/attempt-3/disposition.json", sha256:$psha, outcome:"CNO_AT_B-S9"}]}' > "$home/cleanroom/evidence/ruling.json"
  jq -n '{schema:"fm-accepted-owner-evidence/v1", evidence_id:"ev-slice-c", programme_id:"cleanroom-af-package", step:"slice-c",
    work_id:"cleanroom-af-package", owner:{kind:"pull_request_merge", ref:"sbracewell64/firstmate-cleanroom#5"}, outcome:"MERGED_QUALIFIED",
    candidate:{merge_commit:"dc66ba5ce35be4917424a529a45e61f4a9fa556c"}, qualification:{pipeline:"no-mistakes", evidence_refs:["x"]}}' > "$home/cleanroom/evidence/slice-c.json"
  jq -n '{schema:"fm-af-programme/v1", programme_id:"cleanroom-af-package",
    authorization_basis:{kind:"standing_sequence_grant", refs:["grant"]},
    binding:{commission:{work_id:"cleanroom-af-package", work_generation:1}, grant:{owner:"control_grant", ref:"control#3#issuecomment-5554812621", id:5554812621},
             consumer:{contract:"fm-continuation-resolution/v1"}, evidence_kinds:["latest_attempt_disposition_outcome_in","accepted_owner_evidence"],
             programme_generation:"fm-af-programme/v1"},
    reserved_axes:["new_paid_spend"],
    steps:[
      {id:"ruling", phase:"predecessor-obligations", terminal_predicate:{kind:"accepted_owner_evidence", evidence:"evidence/ruling.json", accept:["PROCEED_WITH_CONDITIONS"]}, classification_when_next:"BROWSER_SOL"},
      {id:"slice-c", phase:"package-qualification", depends_on:["ruling"], terminal_predicate:{kind:"accepted_owner_evidence", evidence:"evidence/slice-c.json", accept:["MERGED_QUALIFIED"]}, classification_when_next:"SELF_HANDLE"},
      {id:"slice-a", phase:"package-qualification", depends_on:["ruling"], terminal_predicate:{kind:"accepted_owner_evidence", evidence:"evidence/slice-a.json", accept:["MERGED_QUALIFIED"]}, classification_when_next:"SELF_HANDLE"},
      {id:"pilot-f", phase:"pilot", depends_on:["slice-c","slice-a"], artifact_root:"artifacts/proofs/af-pilot-f", terminal_predicate:{kind:"latest_attempt_disposition_outcome_in", accept:["PROVED"]}, classification_when_next:"SELF_HANDLE", delegation:{max_concurrency:2}}]}' > "$prog"

  out=$(assert_composed "$home" "owner-evidence programme, slice-a unbound")
  [ "$(field "$out" '.next_action')" = slice-a ] && [ "$(field "$out" '.authority_state')" = CNO ] && [ "$(field "$out" '.reason_code')" = REQUIRED_BINDING_MISSING ] \
    || fail "an unbound slice projects as REQUIRED_BINDING_MISSING/CNO: $(field "$out" '{next_action, authority_state, reason_code}')"
  [ "$(field "$out" '.phase')" = package-qualification ] && [ "$(field "$out" '.phase_generation')" = 0 ] || fail "owner-evidence steps count no attempts"
  [ "$(field "$out" '.applicability.predecessor_disposition.id')" = slice-c ] && [ "$(field "$out" '.applicability.predecessor_disposition.attempt')" = null ] \
    || fail "the predecessor identity is the accepted owner record"
  [ "$(field "$out" '.resolver.cno.reason_code')" = REQUIRED_BINDING_MISSING ] || fail "the resolver's CNO is carried for traceability"
  [ "$(field "$out" '.delegation.concurrency.ceiling')" = 2 ] || fail "the package phase returns the ladder floor"
  pass "the substrate composes an owner-evidence programme unchanged: authority fields equal the resolver's and an unbound slice is REQUIRED_BINDING_MISSING/CNO"

  jq -n '{schema:"fm-accepted-owner-evidence/v1", evidence_id:"ev-slice-a", programme_id:"cleanroom-af-package", step:"slice-a",
    work_id:"cleanroom-af-package", owner:{kind:"pull_request_merge", ref:"sbracewell64/firstmate-cleanroom#9"}, outcome:"MERGED_QUALIFIED",
    qualification:{pipeline:"no-mistakes", evidence_refs:["x"]}}' > "$home/cleanroom/evidence/slice-a.json"
  out=$(assert_composed "$home" "owner-evidence programme, pilot next")
  [ "$(field "$out" '.next_action')" = pilot-f ] && [ "$(field "$out" '.authority_state')" = AUTHORIZED ] || fail "the pilot is projected as the authorized next action"
  [ "$(field "$out" '.phase')" = pilot ] && [ "$(field "$out" '.delegation.concurrency.ceiling')" = 2 ] && [ "$(field "$out" '.delegation.concurrency.source')" = 'programme:steps[3].delegation.max_concurrency' ] \
    || fail "the pilot phase returns the pre-frozen concurrency-2 bound: $(field "$out" '.delegation.concurrency | tojson')"
  [ "$(field "$out" '.delegation.enforces')" = false ] || fail "the substrate never enforces or launches"
  [ -z "$(ls -A "$home/state")" ] || fail "projecting the pilot writes nothing"
  pass "with A-E accepted the substrate projects the pilot with its concurrency-2 bound returned, not enforced, and launches nothing"

  # The same sibling fixture under the resolver's dependency-entry law: a pilot
  # whose one dependency entry names two steps is refused by the resolver, and
  # the substrate propagates that refusal (exit 1, the entry named, nothing on
  # stdout) rather than projecting an empty or partial tuple.
  local err rc
  jq '.steps[3].depends_on = ["slice-c slice-a"]' "$prog" > "$prog.tmp" && mv "$prog.tmp" "$prog"
  err=$(run_project "$home" project 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "a dependency entry naming two steps is refused through the projection"
  assert_contains "$err" "depends_on entry 0 'slice-c slice-a' contains whitespace" "the projection carries the resolver's refusal naming the entry"
  out=$(run_project "$home" project 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] || fail "a refused programme must print no projection on stdout"
  jq '.steps[3].depends_on = [""]' "$prog" > "$prog.tmp" && mv "$prog.tmp" "$prog"
  err=$(run_project "$home" project 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "an empty dependency entry is refused through the projection"
  assert_contains "$err" "depends_on entry 0 is an empty string" "the projection carries the empty-entry refusal"
  pass "the sibling owner-evidence fixture is refused through the projection when a dependency entry is malformed, never composed to an empty tuple"
}

timed() {  # <test-function>
  local start=$SECONDS
  "$1"
  [ -z "${FM_TEST_TIMING:-}" ] || printf '# %s: %ss\n' "$1" "$((SECONDS - start))"
}

timed test_composition_follows_resolver
timed test_applicability_tuple_goes_stale
timed test_uncomposable_records_refused
timed test_deterministic_and_side_effect_free
timed test_delegation_bounds
timed test_not_configured_and_summary
timed test_owner_evidence_programme_composes

echo "# fm-programme-projection.test.sh: all assertions passed"
