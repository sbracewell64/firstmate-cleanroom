#!/usr/bin/env bash
# Behavior tests for FirstMate-selected worker discipline through the public
# brief, promotion and work-context interfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-work-context-discipline)
command -v jq >/dev/null 2>&1 || {
  printf 'ok - skipped (jq is not installed; worker discipline uses work-context JSON)\n'
  exit 0
}

BRIEF="$ROOT/bin/fm-brief.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
CONTEXT="$ROOT/bin/fm-work-context.sh"

make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state"
}

level() {
  jq -r '.engineering.discipline.level' "$1"
}

fragment() {
  jq -r '.engineering.discipline.fragment_sha256' "$1"
}

generation() {
  jq -r '.engineering.discipline.generation' "$1"
}

extract_discipline() { # <brief> <output>
  awk '
    /^# Worker discipline$/ { on=1 }
    on && /^<!-- firstmate-discipline:v1 end / { exit }
    on && /^# Engineering context$/ { exit }
    on && /^# Firstmate instruction inbox$/ { exit }
    on { print }
  ' "$1" > "$2"
}

extract_engineering() { # <brief> <output>
  awk '
    /^# Engineering context$/ { on=1 }
    on && /^# Firstmate instruction inbox$/ { exit }
    on { print }
  ' "$1" > "$2"
}

test_compiler_selects_three_levels() {
  local home desc out rc marker surface multiline
  home="$TMP_ROOT/levels"
  make_home "$home"

  FM_HOME="$home" "$BRIEF" base repo --mode local-only --discipline-fact local >/dev/null \
    || fail "base discipline did not compile"
  desc="$home/data/base/work-context.json"
  [ "$(level "$desc")" = base ] || fail "local fact did not select base"
  assert_grep 'level=base' "$home/data/base/brief.md" "base receipt was not rendered"
  assert_no_grep '# Shared boundary' "$home/data/base/brief.md" "base rendered shared-boundary"
  assert_no_grep '# Proof surface' "$home/data/base/brief.md" "base rendered proof-surface"

  FM_HOME="$home" "$BRIEF" shared repo --mode local-only --discipline-fact schema >/dev/null \
    || fail "shared discipline did not compile"
  desc="$home/data/shared/work-context.json"
  [ "$(level "$desc")" = shared-boundary ] || fail "schema fact did not select shared-boundary"
  assert_grep '# Shared boundary' "$home/data/shared/brief.md" "shared fragment was not rendered"

  FM_HOME="$home" "$BRIEF" proof repo --mode local-only --discipline-fact real-runtime-surface \
    --proof-kind accepted-surface --proof-surface 'bin/example --status' >/dev/null \
    || fail "proof discipline did not compile"
  desc="$home/data/proof/work-context.json"
  [ "$(level "$desc")" = proof-surface ] || fail "accepted surface did not select proof-surface"
  assert_grep '# Proof surface' "$home/data/proof/brief.md" "proof fragment was not rendered"
  assert_grep 'bin/example --status' "$home/data/proof/brief.md" "proof surface was not preserved"

  marker="$home/proof-surface-side-effect"
  surface='$(touch '
  surface="${surface}${marker}) \`uname\` \${PATH} \"quoted\" \\\\"
  FM_HOME="$home" "$BRIEF" literal repo --mode local-only --discipline-fact real-runtime-surface \
    --proof-kind accepted-surface --proof-surface "$surface" >/dev/null \
    || fail "literal proof surface did not compile"
  [ ! -e "$marker" ] || fail "proof surface executed command substitution"
  assert_grep "$surface" "$home/data/literal/brief.md" "proof surface bytes were not preserved literally"
  multiline=$'```sh\n$(touch '
  multiline="${multiline}${home}/multiline-side-effect)"$'\n\tprintf '\''\"quoted\"'\''\n# Engineering context\n# Firstmate instruction inbox\n# Worker discipline\nDiscipline receipt: literal\n\n```\n'
  FM_HOME="$home" "$BRIEF" multiline repo --mode local-only --discipline-fact real-runtime-surface \
    --proof-kind accepted-surface --proof-surface "$multiline" >/dev/null \
    || fail "multiline proof surface did not compile"
  [ ! -e "$home/multiline-side-effect" ] || fail "multiline proof surface executed command substitution"
  printf '%s' "$multiline" > "$home/multiline.expected"
  jq -j '.engineering.discipline.proof_surface' "$home/data/multiline/work-context.json" > "$home/multiline.actual"
  cmp -s "$home/multiline.expected" "$home/multiline.actual" || fail "multiline proof surface bytes changed in receipt"
  pass "discipline compiler: accepted typed facts independently select base, shared-boundary and proof-surface"

  out=$(FM_HOME="$home" "$BRIEF" legacy repo --mode local-only --shared-boundary 2>&1); rc=$?
  expect_code 1 "$rc" "manual level selection must be refused"
  assert_contains "$out" 'typed --discipline-fact' "legacy selection refusal did not name the authority input"
  out=$(FM_HOME="$home" "$BRIEF" contradiction repo --mode local-only \
    --discipline-fact local --discipline-fact schema 2>&1); rc=$?
  expect_code 3 "$rc" "local and shared facts must contradict"
  assert_contains "$out" 'contradictory-discipline-facts' "contradiction was not typed"
  out=$(FM_HOME="$home" "$BRIEF" unknown repo --mode local-only --discipline-fact preference 2>&1); rc=$?
  expect_code 3 "$rc" "unknown discipline fact must refuse"
  assert_contains "$out" 'unknown-discipline-fact' "unknown fact refusal was not typed"
  out=$(FM_HOME="$home" "$BRIEF" unjustified repo --mode local-only \
    --discipline-fact local --proof-surface 'bin/example --status' 2>&1); rc=$?
  expect_code 3 "$rc" "proof surface without an accepted proof kind must refuse"
  assert_contains "$out" 'proof-kind-required' "unjustified proof surface refusal was not typed"
  out=$(FM_HOME="$home" "$BRIEF" missing-authority repo --mode local-only --discipline-fact local \
    --proof-kind accepted-surface --proof-surface 'bin/example --status' 2>&1); rc=$?
  expect_code 3 "$rc" "accepted surface without authority fact must refuse"
  assert_contains "$out" 'proof-authority-required' "missing accepted-surface authority was not typed"
  out=$(FM_HOME="$home" "$BRIEF" cross-authority repo --mode local-only --discipline-fact real-runtime-surface --discipline-fact repeated-verification \
    --proof-kind accepted-surface --proof-surface 'bin/example --status' 2>&1); rc=$?
  expect_code 3 "$rc" "cross-paired authority fact must refuse"
  assert_contains "$out" 'proof-authority-cross-pair' "cross-paired authority refusal was not typed"
  pass "discipline compiler: contradictory, unknown and unjustified stronger selections refuse"
}

test_roles_promotion_and_stable_identity() {
  local home ship scout charter promoted desc first second original_generation malformed_generation
  home="$TMP_ROOT/roles"
  make_home "$home"

  FM_HOME="$home" "$BRIEF" ship repo --mode no-mistakes --discipline-fact persisted-state >/dev/null \
    || fail "ship discipline fixture failed"
  ship="$home/data/ship/brief.md"
  desc="$home/data/ship/work-context.json"
  [ "$(jq -r '.engineering.discipline.task' "$desc")" = ship ] || fail "receipt lost task identity"
  [ "$(jq -r '.engineering.discipline.role' "$desc")" = ship ] || fail "receipt lost ship role"
  [ "$(jq -r '.engineering.discipline.stage' "$desc")" = implementation ] || fail "receipt lost implementation stage"
  [ "$(fragment "$desc")" != null ] || fail "receipt lost canonical fragment identity"
  [ "$(generation "$desc")" != null ] || fail "receipt lost context generation"
  first=$(FM_HOME="$home" "$CONTEXT" discipline ship ship implementation) \
    || fail "checked discipline could not render"
  second=$(FM_HOME="$home" "$CONTEXT" discipline ship ship implementation) \
    || fail "checked discipline could not render after resume"
  [ "$first" = "$second" ] || fail "restart/resume changed the selected discipline identity"
  original_generation=$(jq -r '.engineering.generation' "$desc")
  malformed_generation=$'g1\nx'
  jq --arg generation "$malformed_generation" \
    '.engineering.generation=$generation | .engineering.discipline.outer_generation=$generation' \
    "$desc" > "$desc.tmp" && mv "$desc.tmp" "$desc"
  out=$(FM_HOME="$home" "$CONTEXT" discipline ship ship implementation 2>&1); rc=$?
  expect_code 3 "$rc" "malformed matching outer generation must refuse discipline rendering"
  assert_contains "$out" 'malformed engineering generation' "malformed generation refusal was not typed"
  jq --arg generation "$original_generation" \
    '.engineering.generation=$generation | .engineering.discipline.outer_generation=$generation' \
    "$desc" > "$desc.tmp" && mv "$desc.tmp" "$desc"
  jq '.engineering.generation="outer-generation-changed"' "$desc" > "$desc.tmp" && mv "$desc.tmp" "$desc"
  out=$(FM_HOME="$home" "$CONTEXT" discipline ship ship implementation 2>&1); rc=$?
  expect_code 3 "$rc" "changed outer generation must refuse discipline rendering"
  assert_contains "$out" 'discipline-identity' "outer generation refusal was not typed"

  FM_HOME="$home" "$BRIEF" scout repo --scout >/dev/null || fail "scout fixture failed"
  scout="$home/data/scout/brief.md"
  assert_grep '# Evidence discipline' "$scout" "knowledge-only scout lost its evidence subset"
  assert_no_grep '# Worker discipline' "$scout" "knowledge-only scout received coding discipline"
  [ ! -f "$home/data/scout/work-context.json" ] || \
    [ "$(jq -r '.engineering.discipline // empty' "$home/data/scout/work-context.json")" = '' ] || \
    fail "knowledge-only scout persisted ship discipline"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$BRIEF" mate --secondmate --no-projects >/dev/null \
    || fail "charter fixture failed"
  charter="$home/data/mate/brief.md"
  assert_no_grep 'Discipline receipt:' "$charter" \
    "secondmate charter received coding-worker discipline"

  printf '%s\n' '{"authority":{"classes":["A"]},"engineering":{"generation":"existing-g1","triggers":[],"skills":[],"verification":[]}}' \
    > "$home/data/scout/work-context.json"
  printf '%s\n' 'kind=scout' 'worktree=/tmp/unused-discipline-fixture' > "$home/state/scout.meta"
  FM_HOME="$home" "$PROMOTE" scout --mode no-mistakes --yolo off \
    --discipline-fact persisted-state >/dev/null || fail "promotion discipline did not compile"
  promoted="$home/data/scout/ship-instructions.md"
  [ "$(level "$home/data/scout/work-context.json")" = shared-boundary ] || \
    fail "promotion did not persist the selected level"
  [ "$(jq -r .engineering.generation "$home/data/scout/work-context.json")" = existing-g1 ] || \
    fail "promotion replaced the existing work-context generation"
  [ "$(jq -r '.authority.classes[0]' "$home/data/scout/work-context.json")" = A ] || \
    fail "promotion replaced an unrelated work-context owner"
  extract_discipline "$ship" "$home/ship.discipline"
  extract_discipline "$promoted" "$home/promoted.discipline"
  # Task-specific receipt identity differs; the canonical fragment identity and
  # all instruction bytes after that receipt must remain the same.
  tail -n +3 "$home/ship.discipline" > "$home/ship.fragment"
  tail -n +3 "$home/promoted.discipline" > "$home/promoted.fragment"
  cmp -s "$home/ship.fragment" "$home/promoted.fragment" || \
    fail "fresh ship and promoted scout received different canonical discipline"
  pass "discipline roles: ship/promotion parity, scout evidence subset, charter isolation and stable resume identity"
}

test_behavioral_fixtures_drive_each_selected_surface() {
  local home fixture out
  home="$TMP_ROOT/behavior"
  fixture="$home/project"
  make_home "$home"
  mkdir -p "$fixture/bin" "$fixture/state"

  # Base: a trivial local edit exercises only its direct command and creates no
  # verifier or shared-seam ceremony.
  cat > "$fixture/bin/local-value" <<'SH'
#!/usr/bin/env bash
printf 'local-ok\n'
SH
  chmod +x "$fixture/bin/local-value"
  FM_HOME="$home" "$BRIEF" behavior-base repo --mode local-only --discipline-fact local >/dev/null
  out=$("$fixture/bin/local-value")
  [ "$out" = local-ok ] || fail "base fixture did not exercise its direct local surface"
  [ "$(level "$home/data/behavior-base/work-context.json")" = base ] || fail "trivial fixture escalated above base"
  [ "$(find "$fixture" -maxdepth 2 -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "trivial base fixture manufactured proof tooling"

  # Shared boundary: one producer persists a schema consumed by two siblings.
  # The executable check traces that whole seam and proves both acceptance and
  # malformed-state rejection rather than trusting a source-only assertion.
  cat > "$fixture/bin/write-state" <<'SH'
#!/usr/bin/env bash
printf 'schema=v1\nvalue=ready\n' > "${1:?state file}"
SH
  cat > "$fixture/bin/read-state" <<'SH'
#!/usr/bin/env bash
name=$1 file=$2
grep -qx 'schema=v1' "$file" && grep -qx 'value=ready' "$file" || exit 9
printf '%s:ready\n' "$name"
SH
  chmod +x "$fixture/bin/write-state" "$fixture/bin/read-state"
  FM_HOME="$home" "$BRIEF" behavior-shared repo --mode local-only --discipline-fact schema >/dev/null
  "$fixture/bin/write-state" "$fixture/state/record"
  {
    "$fixture/bin/read-state" reader-a "$fixture/state/record"
    "$fixture/bin/read-state" reader-b "$fixture/state/record"
  } > "$home/shared-proof.txt"
  printf 'schema=v2\nvalue=ready\n' > "$fixture/state/bad"
  ! "$fixture/bin/read-state" reader-a "$fixture/state/bad" >/dev/null 2>&1 || \
    fail "shared seam fixture accepted an unknown schema"
  assert_grep 'reader-a:ready' "$home/shared-proof.txt" "shared trace missed reader-a"
  assert_grep 'reader-b:ready' "$home/shared-proof.txt" "shared trace missed reader-b"
  assert_grep '# Shared boundary' "$home/data/behavior-shared/brief.md" "shared behavior lacked its selected trace contract"

  # Proof surface: drive the exact accepted runtime command and retain output.
  cat > "$fixture/bin/example" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --status ] || exit 2
printf '{"status":"ready"}\n'
SH
  chmod +x "$fixture/bin/example"
  FM_HOME="$home" "$BRIEF" behavior-proof repo --mode local-only --discipline-fact real-runtime-surface \
    --proof-kind accepted-surface --proof-surface 'bin/example --status' >/dev/null
  (cd "$fixture" && bin/example --status) > "$home/proof-surface.txt"
  assert_grep '"status":"ready"' "$home/proof-surface.txt" "real proof surface was not exercised"
  assert_grep 'bin/example --status' "$home/data/behavior-proof/brief.md" "proof command was not rendered from selection"
  pass "discipline behavior: trivial base, shared producer/persistence/readers and a real proof-surface command were exercised"
}

test_candidate_evidence_is_bound_but_not_authority() {
  local home desc receipt head run artifact evidence out rc mutation surface
  home="$TMP_ROOT/evidence"
  make_home "$home"
  surface=$'bin/example --status\n'
  FM_HOME="$home" "$BRIEF" evidence repo --mode no-mistakes --discipline-fact schema --discipline-fact real-runtime-surface \
    --proof-kind accepted-surface --proof-surface "$surface" >/dev/null \
    || fail "evidence fixture did not compile"
  desc="$home/data/evidence/work-context.json"
  receipt=$(jq -c '.engineering.discipline' "$desc")
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  run=01DISCIPLINE
  artifact="$home/data/evidence/discipline-proof.txt"
  printf 'observed command output; safety fact: schema reader rejects unknown state\n' > "$artifact"
  evidence="$home/data/evidence/engineering-evidence.json"
  jq -n --arg task evidence --arg run "$run" --arg head "$head" \
    --arg generation "$(printf '%s' "$receipt" | jq -r .generation)" \
    --arg level "$(printf '%s' "$receipt" | jq -r .level)" \
    --arg fragment "$(printf '%s' "$receipt" | jq -r .fragment_sha256)" \
    --arg surface "$surface" \
    --arg path "$artifact" --arg sha "$(sha256sum < "$artifact" | cut -d' ' -f1)" \
    '{task:$task,run:$run,head:$head,results:[{id:"worker-discipline",discipline:{task:$task,role:"ship",stage:"implementation",generation:$generation,level:$level,fragment_sha256:$fragment,producer:"worker-candidate",outcome:"OBSERVED",surface:$surface,command:$surface,oracle:"exit zero and expected status",path:$path,sha256:$sha,safety_facts:["schema reader rejects unknown state"]}}]}' > "$evidence"
  cp "$evidence" "$home/valid-evidence.json"
  out=$(FM_HOME="$home" "$CONTEXT" discipline-evidence evidence "$run" "$head") \
    || fail "bound observed evidence was refused"
  assert_contains "$out" 'verdict=candidate-evidence outcome=OBSERVED qualification=unchanged landing=unchanged' \
    "candidate evidence acquired authority"

  jq '.results[0].discipline.outcome="CNO"' "$home/valid-evidence.json" > "$evidence"
  out=$(FM_HOME="$home" "$CONTEXT" discipline-evidence evidence "$run" "$head") \
    || fail "honest CNO evidence was refused"
  assert_contains "$out" 'outcome=CNO qualification=unchanged landing=unchanged' \
    "CNO was rounded to pass or authority"

  for mutation in \
    '.results[0].discipline.outcome="PASS"' \
    '.results[0].discipline.producer="worker-approved"' \
    '.results[0].discipline.generation="stale"' \
    '.results[0].discipline.fragment_sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    '.results[0].discipline.command="some other surface"' \
    '.results[0].discipline.extra="tamper"' \
    '.results[0].discipline.safety_facts=[]' \
    '.task="other"' \
    '.head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'; do
    jq "$mutation" "$home/valid-evidence.json" > "$evidence"
    out=$(FM_HOME="$home" "$CONTEXT" discipline-evidence evidence "$run" "$head" 2>&1); rc=$?
    expect_code 3 "$rc" "invalid candidate evidence must refuse: $mutation"
  done
  cp "$home/valid-evidence.json" "$evidence"
  printf 'tampered after indexing\n' >> "$artifact"
  out=$(FM_HOME="$home" "$CONTEXT" discipline-evidence evidence "$run" "$head" 2>&1); rc=$?
  expect_code 3 "$rc" "tampered proof artifact must refuse"
  assert_contains "$out" 'discipline-evidence-stale' "tampered artifact refusal was not typed"
  pass "discipline evidence: exact identity and maker/checker boundary hold; CNO remains CNO and self-proof grants no authority"
}

test_tampering_and_prompt_bounds() {
  local home desc out rc base_bytes shared_bytes proof_bytes kernel_bytes
  local base_total shared_total proof_total
  home="$TMP_ROOT/tamper"
  make_home "$home"
  FM_HOME="$home" "$BRIEF" task repo --mode no-mistakes --discipline-fact authority --discipline-fact repeated-verification \
    --proof-kind verification-lever --proof-surface 'bin/fm-work-context.sh discipline-check' >/dev/null \
    || fail "tamper fixture did not compile"
  desc="$home/data/task/work-context.json"
  cp "$desc" "$home/original.json"

  for mutation in \
    '.engineering.discipline.task="other"' \
    '.engineering.discipline.role="scout"' \
    '.engineering.discipline.stage="review"' \
    '.engineering.discipline.generation="stale"' \
    '.engineering.discipline.level="base"' \
    '.engineering.discipline.fragment_sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'; do
    jq "$mutation" "$home/original.json" > "$desc"
    out=$(FM_HOME="$home" "$CONTEXT" discipline task ship implementation 2>&1); rc=$?
    expect_code 3 "$rc" "tampered discipline must refuse: $mutation"
    assert_contains "$out" 'discipline-' "tamper refusal did not identify the discipline contract"
  done
  cp "$home/original.json" "$desc"
  out=$(FM_HOME="$home" "$CONTEXT" discipline task scout diagnosis 2>&1); rc=$?
  expect_code 3 "$rc" "wrong caller role/stage must refuse"
  assert_contains "$out" 'discipline-applicability' "wrong caller refusal was not typed"

  make_home "$home/bounds"
  FM_HOME="$home/bounds" "$BRIEF" base repo --mode local-only --discipline-fact local >/dev/null
  FM_HOME="$home/bounds" "$BRIEF" shared repo --mode local-only --discipline-fact identity >/dev/null
  FM_HOME="$home/bounds" "$BRIEF" proof repo --mode local-only --discipline-fact real-runtime-surface \
    --proof-kind accepted-surface --proof-surface 'bin/example --status' >/dev/null
  extract_discipline "$home/bounds/data/base/brief.md" "$home/base.block"
  extract_discipline "$home/bounds/data/shared/brief.md" "$home/shared.block"
  extract_discipline "$home/bounds/data/proof/brief.md" "$home/proof.block"
  extract_engineering "$home/bounds/data/base/brief.md" "$home/base.engineering"
  extract_engineering "$home/bounds/data/shared/brief.md" "$home/shared.engineering"
  extract_engineering "$home/bounds/data/proof/brief.md" "$home/proof.engineering"
  base_bytes=$(wc -c < "$home/base.block" | tr -d ' ')
  shared_bytes=$(wc -c < "$home/shared.block" | tr -d ' ')
  proof_bytes=$(wc -c < "$home/proof.block" | tr -d ' ')
  kernel_bytes=$(grep -v '^Discipline receipt:' "$home/base.block" | wc -c | tr -d ' ')
  base_total=$((base_bytes + $(wc -c < "$home/base.engineering")))
  shared_total=$((shared_bytes + $(wc -c < "$home/shared.engineering")))
  proof_total=$((proof_bytes + $(wc -c < "$home/proof.engineering")))
  [ "$base_bytes" -le 3000 ] || fail "base discipline exceeds the accepted compact-kernel bound: $base_bytes"
  [ $((base_total - kernel_bytes)) -le 1500 ] || fail "receipt and checked-context overhead is disproportionate"
  [ $((shared_total - base_total)) -le 650 ] || fail "shared fragment exceeds proportionate bound"
  [ $((proof_total - base_total)) -le 500 ] || fail "proof fragment exceeds proportionate bound"
  printf 'ok - discipline prompt bounds: base=%sB/~%s tokens shared=%sB/~%s proof=%sB/~%s compact-kernel=%sB\n' \
    "$base_total" "$((base_total / 4))" "$shared_total" "$((shared_total / 4))" \
    "$proof_total" "$((proof_total / 4))" "$kernel_bytes"
  pass "discipline identity: task/role/stage/generation/selection/fragment tampering refuses before work"
}

test_compiler_selects_three_levels
test_roles_promotion_and_stable_identity
test_behavioral_fixtures_drive_each_selected_surface
test_candidate_evidence_is_bound_but_not_authority
test_tampering_and_prompt_bounds
