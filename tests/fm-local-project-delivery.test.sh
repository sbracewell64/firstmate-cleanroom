#!/usr/bin/env bash
# tests/fm-local-project-delivery.test.sh - owner-bound admission for governed
# local programme deliveries through the public binding and verification CLI.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DELIVERY="$ROOT/bin/fm-local-project-delivery.py"
TMP_ROOT=$(fm_test_tmproot fm-local-project-delivery)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

write_programme() { # <home>
  local home=$1
  mkdir -p "$home/programme/evidence"
  cat > "$home/programme/programme.json" <<'JSON'
{
  "schema": "fm-af-programme/v1",
  "programme_id": "cleanroom-af-package",
  "project": "fixture-project",
  "authorization_basis": {
    "kind": "standing_sequence_grant",
    "programme_generation": "fm-af-programme/v1",
    "refs": ["fixture-grant"]
  },
  "reserved_axes": [],
  "binding": {
    "commission": {"work_id": "cleanroom-af-package", "work_generation": 1},
    "grant": {"owner": "control_grant", "ref": "fixture-grant", "id": 1},
    "ruling": {"owner": "control_ruling", "ref": "fixture-ruling", "id": 2},
    "consumer": {"contract": "fm-continuation-resolution/v1", "projection": "fm-programme-projection/v1"},
    "evidence_kinds": ["accepted_owner_evidence"],
    "programme_generation": "fm-af-programme/v1"
  },
  "steps": [
    {
      "id": "slice-a-s1-publication-integrity",
      "title": "A fixture",
      "classification_when_next": "SELF_HANDLE",
      "terminal_predicate": {
        "kind": "accepted_owner_evidence",
        "evidence": "evidence/slice-a.json",
        "accept": ["DELIVERED_QUALIFIED"],
        "local_delivery": {
          "schema": "fm-local-project-delivery-policy/v1",
          "owner_project": "exchange-work",
          "maker_checker": "distinct",
          "qualification_routes": ["independent-checker", "no-mistakes"],
          "artifacts": [
            {"source": "exchange/bin/render-manifest.py", "destination": "exchange/bin/render-manifest.py", "git_mode": "100755"},
            {"source": "exchange/bin/exchange-current.py", "destination": "exchange/bin/exchange-current.py", "git_mode": "100755"}
          ],
          "preservation": {
            "current": {"kind": "json_generation", "path": "exchange/chatgpt-project/PROJECT-SOURCE-MANIFEST.json", "generation": 7},
            "rollback": {"kind": "git_tree", "path": "exchange/chatgpt-project/upload.gen6", "generation": 6}
          }
        }
      }
    },
    {
      "id": "slice-b-s2-reference-catalog",
      "title": "B fixture",
      "depends_on": ["slice-a-s1-publication-integrity"],
      "classification_when_next": "SELF_HANDLE",
      "terminal_predicate": {
        "kind": "accepted_owner_evidence",
        "evidence": "evidence/slice-b.json",
        "accept": ["DELIVERED_QUALIFIED"],
        "local_delivery": {
          "schema": "fm-local-project-delivery-policy/v1",
          "owner_project": "exchange-work",
          "maker_checker": "distinct",
          "qualification_routes": ["independent-checker"],
          "artifacts": [
            {"source": "exchange/bin/render-check-catalog.py", "destination": "exchange/bin/render-check-catalog.py", "git_mode": "100755"}
          ],
          "preservation": {
            "current": {"kind": "json_generation", "path": "exchange/chatgpt-project/PROJECT-SOURCE-MANIFEST.json", "generation": 7},
            "rollback": {"kind": "git_tree", "path": "exchange/chatgpt-project/upload.gen6", "generation": 6}
          }
        }
      }
    },
    {
      "id": "slice-d-s4-synthesis-integrity",
      "title": "D fixture",
      "depends_on": ["slice-b-s2-reference-catalog"],
      "classification_when_next": "SELF_HANDLE",
      "terminal_predicate": {
        "kind": "accepted_owner_evidence",
        "evidence": "evidence/slice-d.json",
        "accept": ["DELIVERED_QUALIFIED"],
        "local_delivery": {
          "schema": "fm-local-project-delivery-policy/v1",
          "maker_checker": "distinct",
          "qualification_routes": ["independent-checker"],
          "artifacts": [
            {"source": "artifacts/synthesis/bin/synthesis-integrity.py", "destination": "artifacts/synthesis/bin/synthesis-integrity.py", "git_mode": "100755"},
            {"source": "artifacts/synthesis/synthesis-keys.tsv", "destination": "artifacts/synthesis/synthesis-keys.tsv", "git_mode": "100644"},
            {"source": "artifacts/synthesis/sources/ANTI-SLOP-2026-09-05__F2.txt", "destination": "artifacts/synthesis/sources/ANTI-SLOP-2026-09-05__F2.txt", "git_mode": "100644"},
            {"source": "artifacts/synthesis/sources/LLM-WIKI-2026-09-05__L2.txt", "destination": "artifacts/synthesis/sources/LLM-WIKI-2026-09-05__L2.txt", "git_mode": "100644"},
            {"source": "artifacts/synthesis/sources/LLM-WIKI-2026-09-05__L3.txt", "destination": "artifacts/synthesis/sources/LLM-WIKI-2026-09-05__L3.txt", "git_mode": "100644"},
            {"source": "artifacts/synthesis/sources/LLM-WIKI-2026-09-05__W1.txt", "destination": "artifacts/synthesis/sources/LLM-WIKI-2026-09-05__W1.txt", "git_mode": "100644"},
            {"source": "artifacts/plans/programme-authority-manager-loop-study.md", "destination": "artifacts/plans/programme-authority-manager-loop-study.md", "git_mode": "100644"}
          ]
        }
      }
    }
  ]
}
JSON
}

make_home() { # <name>
  local home="$TMP_ROOT/$1" repo
  mkdir -p "$home/data" "$home/projects" "$home/source/exchange/bin" \
    "$home/source/exchange/chatgpt-project/upload.gen6" "$home/source/artifacts/synthesis/bin" \
    "$home/source/artifacts/synthesis/sources" "$home/source/artifacts/plans"
  write_programme "$home"
  printf '%s\n' '- exchange-work [local-only] - fixture owner (added 2026-09-18)' > "$home/data/projects.md"
  printf '#!/usr/bin/env python3\nprint("manifest")\n' > "$home/source/exchange/bin/render-manifest.py"
  printf '#!/usr/bin/env python3\nprint("current")\n' > "$home/source/exchange/bin/exchange-current.py"
  printf '#!/usr/bin/env python3\nprint("catalog")\n' > "$home/source/exchange/bin/render-check-catalog.py"
  printf '{"generation":7}\n' > "$home/source/exchange/chatgpt-project/PROJECT-SOURCE-MANIFEST.json"
  printf 'rollback\n' > "$home/source/exchange/chatgpt-project/upload.gen6/member.txt"
  printf '#!/usr/bin/env python3\nprint("synthesis")\n' > "$home/source/artifacts/synthesis/bin/synthesis-integrity.py"
  printf 'keys\n' > "$home/source/artifacts/synthesis/synthesis-keys.tsv"
  for name in ANTI-SLOP-2026-09-05__F2.txt LLM-WIKI-2026-09-05__L2.txt LLM-WIKI-2026-09-05__L3.txt LLM-WIKI-2026-09-05__W1.txt; do
    printf '%s\n' "$name" > "$home/source/artifacts/synthesis/sources/$name"
  done
  printf 'manager loop\n' > "$home/source/artifacts/plans/programme-authority-manager-loop-study.md"
  repo="$home/projects/exchange-work"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  cp -R "$home/source/exchange" "$repo/"
  find "$repo/exchange/bin" -type f -exec chmod 755 {} +
  git -C "$repo" add .
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture
  printf '%s\n' "$home"
}

bind() { # <home> <step> [extra args...]
  local home=$1 step=$2 repo="$1/projects/exchange-work"
  shift 2
  (cd "$repo" && FM_HOME="$home" "$DELIVERY" bind \
    --programme "$home/programme/programme.json" --root "$home/source" --step "$step" \
    --project exchange-work --ref refs/heads/main --delivery-id "delivery-${step}" \
    --maker maker-one --checker checker-one --route independent-checker "$@")
}

expect_rejected_without_publication() { # <label> <home> <expected> <command...>
  local label=$1 home=$2 expected=$3 out rc before after
  shift 3
  before=$(find "$home/data" -mindepth 1 -maxdepth 5 -type f -print -exec sha256sum {} \; | sort)
  out=$("$@" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$label unexpectedly succeeded: $out"
  assert_contains "$out" "$expected" "$label did not report the expected typed refusal"
  after=$(find "$home/data" -mindepth 1 -maxdepth 5 -type f -print -exec sha256sum {} \; | sort)
  [ "$before" = "$after" ] || fail "$label changed durable data before refusing"
  pass "$label refuses before publication"
}

# The public bind path derives the immutable manifest from the programme owner,
# the registered local-only project, the exact source bytes, and the candidate.
home=$(make_home positive)
out=$(bind "$home" slice-a-s1-publication-integrity) || fail "positive bind failed: $out"
admission=$(printf '%s' "$out" | jq -r '.path')
[ "$(printf '%s' "$out" | jq -r '.status')" = ADMITTED ] || fail "positive bind did not report ADMITTED"
[ "$(stat -c %a "$admission")" = 600 ] || fail "admission is not mode 0600"
[ "$(jq -r '.owner.project + " " + .owner.mode' "$admission")" = 'exchange-work local-only' ] || fail "owner binding missing"
[ "$(jq -r '.preservation.current.generation' "$admission")" = 7 ] || fail "generation 7 is not bound as current"
[ "$(jq -r '.preservation.rollback.generation' "$admission")" = 6 ] || fail "generation 6 is not bound as rollback"
[ "$(jq -r '.artifacts | map(.git_mode) | unique | join(",")' "$admission")" = 100755 ] || fail "A executable modes are not exact"
verify=$(FM_HOME="$home" "$DELIVERY" verify --admission "$admission" \
  --programme "$home/programme/programme.json" --root "$home/source" --step slice-a-s1-publication-integrity) \
  || fail "positive verify failed: $verify"
[ "$(printf '%s' "$verify" | jq -r '.status')" = ACCEPTED ] || fail "positive verify was not accepted"
pass "bind publishes one private owner-bound A manifest and verify replays its exact identities"

registry_home=$(make_home registry-snapshot)
registry_out=$(bind "$registry_home" slice-a-s1-publication-integrity) || fail "registry snapshot setup bind failed: $registry_out"
registry_admission=$(printf '%s' "$registry_out" | jq -r '.path')
printf '%s\n' '- unrelated-project [local-only] - unrelated fixture (added 2026-09-18)' >> "$registry_home/data/projects.md"
registry_before=$(sha256_file "$registry_admission")
registry_out=$(FM_HOME="$registry_home" "$DELIVERY" verify --admission "$registry_admission" \
  --programme "$registry_home/programme/programme.json" --root "$registry_home/source" --step slice-a-s1-publication-integrity 2>&1); registry_rc=$?
[ "$registry_rc" -ne 0 ] || fail "registry snapshot mutation unexpectedly verified: $registry_out"
assert_contains "$registry_out" 'MANIFEST_AUTHENTICITY' "registry snapshot mutation did not invalidate the old admission"
[ "$(sha256_file "$registry_admission")" = "$registry_before" ] || fail "registry snapshot refusal changed the immutable admission"
pass "verify rejects an admission after an unrelated registry snapshot change"

# The programme continuation public interface accepts V2 only when the private
# delivery and checker receipts bind this exact pre-effect admission.
mkdir -p "$home/data/local-project-delivery" "$home/fake-bin"
head=$(jq -r '.destination.head' "$admission")
tree=$(jq -r '.destination.tree' "$admission")
admission_rel=${admission#"$home/"}
admission_sha=$(sha256_file "$admission")
policy_digest=$(jq -r '.action.local_delivery_policy_sha256' "$admission")
checker_rel=data/local-project-delivery/a-checker.json
checker_file="$home/$checker_rel"
jq -n --arg admission "$admission_sha" --arg head "$head" --arg tree "$tree" '
  {schema:"fm-local-checker-receipt/v2",receipt_id:"checker-a",admission_sha256:$admission,
   candidate:{head:$head,tree:$tree},maker:{id:"maker-one"},checker:{id:"checker-one"},
   pipeline:"independent-checker",outcome:"checks-passed"}' > "$checker_file"
chmod 600 "$checker_file"
checker_sha=$(sha256_file "$checker_file")
receipt_rel=data/local-project-delivery/a-delivery.json
receipt_file="$home/$receipt_rel"
jq -n --arg head "$head" --arg tree "$tree" --arg admission_rel "$admission_rel" --arg admission_sha "$admission_sha" \
  --arg policy_digest "$policy_digest" \
  --arg checker_rel "$checker_rel" --arg checker_sha "$checker_sha" '
  {schema:"fm-local-project-delivery-receipt/v2",delivery_id:"delivery-slice-a-s1-publication-integrity",generation:1,
   owner:{kind:"local_project_delivery",ref:"exchange-work"},
   candidate:{head:$head,tree:$tree,delivery_id:"delivery-slice-a-s1-publication-integrity",owner_project:"exchange-work",ref:"refs/heads/main"},
   admission:{path:$admission_rel,sha256:$admission_sha},maker:{id:"maker-one",commit:$head},checker:{id:"checker-one"},
   privacy:{classification:"private_local",exposure:"digests_only",published_private_bytes:false},
   qualification:{pipeline:"independent-checker",outcome:"checks-passed",evidence_refs:[{path:$checker_rel,sha256:$checker_sha}]},
   read_back:{status:"MATCH",observer:"checker-one"}}' > "$receipt_file"
chmod 600 "$receipt_file"
receipt_sha=$(sha256_file "$receipt_file")
evidence="$home/programme/evidence/slice-a.json"
jq -n --arg head "$head" --arg tree "$tree" --arg receipt_rel "$receipt_rel" --arg receipt_sha "$receipt_sha" \
  --arg checker_rel "$checker_rel" --arg checker_sha "$checker_sha" --arg policy_digest "$policy_digest" '
  {schema:"fm-accepted-owner-evidence/v1",evidence_id:"delivery-slice-a-s1-publication-integrity",programme_id:"cleanroom-af-package",
   step:"slice-a-s1-publication-integrity",project:"fixture-project",work_id:"cleanroom-af-package",generation:1,
   owner:{kind:"local_project_delivery",ref:"exchange-work"},outcome:"DELIVERED_QUALIFIED",
   candidate:{head:$head,tree:$tree,delivery_id:"delivery-slice-a-s1-publication-integrity",owner_project:"exchange-work",ref:"refs/heads/main"},
   policy:{id:"local-delivery-policy",digest:$policy_digest},
   verifier:{tool:"fm-local-project-delivery/v2"},
   qualification:{pipeline:"independent-checker",outcome:"checks-passed",evidence_refs:[{path:$checker_rel,sha256:$checker_sha}]},
   delivery:{receipt:{path:$receipt_rel,sha256:$receipt_sha}},
   privacy:{classification:"private_local",exposure:"digests_only",published_private_bytes:false},
   captures:[],sources:[],observed_bad:[],superseded_by:null}' > "$evidence"
evidence_sha=$(sha256_file "$evidence")
tmp="$home/programme/programme.json.tmp"
jq --arg sha "$evidence_sha" --arg head "$head" --arg tree "$tree" --arg policy_digest "$policy_digest" '
  (.steps[] | select(.id=="slice-a-s1-publication-integrity") | .terminal_predicate) +=
    {owner_ref:"exchange-work",evidence_sha256:$sha,evidence_generation:1,
     policy_digest:$policy_digest,
     candidate:{head:$head,tree:$tree,delivery_id:"delivery-slice-a-s1-publication-integrity",owner_project:"exchange-work",ref:"refs/heads/main"}}' \
  "$home/programme/programme.json" > "$tmp" && mv "$tmp" "$home/programme/programme.json"
cat > "$home/fake-bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 1
printf 'count: 0\n'
SH
chmod +x "$home/fake-bin/tasks-axi"
resolved=$(PATH="$home/fake-bin:$PATH" FM_HOME="$home" FM_CONTINUATION_TODAY=2026-09-18 \
  "$ROOT/bin/fm-continuation-resolve.sh" resolve --programme "$home/programme/programme.json" --root "$home/source") \
  || fail "V2 resolver integration failed: $resolved"
[ "$(printf '%s' "$resolved" | jq -r '.completed | map(.id) | join(",")')" = slice-a-s1-publication-integrity ] \
  || fail "resolver did not complete only A through V2 admission: $(printf '%s' "$resolved" | jq -c '.completed')"
[ "$(printf '%s' "$resolved" | jq -r '.next_action + " " + .reason_code')" = 'slice-b-s2-reference-catalog REQUIRED_BINDING_MISSING' ] \
  || fail "resolver advanced past unbound B after A admission"
pass "programme continuation consumes the exact admitted V2 delivery and advances only its matching slice"

# Reusing the same delivery identity is a replay, not an idempotent new admission.
expect_rejected_without_publication "replay" "$home" 'ADMISSION_REPLAY' bind "$home" slice-a-s1-publication-integrity

# Wrong invocation context/home/project refuses before the admission directory exists.
home=$(make_home wrong-cwd)
expect_rejected_without_publication "wrong working directory" "$home" 'WORKING_DIRECTORY_MISMATCH' \
  env FM_HOME="$home" "$DELIVERY" bind --programme "$home/programme/programme.json" --root "$home/source" \
  --step slice-a-s1-publication-integrity --project exchange-work --ref refs/heads/main \
  --delivery-id wrong-cwd --maker maker-one --checker checker-one --route independent-checker

home=$(make_home wrong-home-source)
out=$(bind "$home" slice-a-s1-publication-integrity) || fail "wrong-home setup bind failed: $out"
admission=$(printf '%s' "$out" | jq -r '.path')
other=$(make_home wrong-home-target)
mkdir -p "$other/data/local-project-delivery/admissions"
cp "$admission" "$other/data/local-project-delivery/admissions/$(basename "$admission")"
expect_rejected_without_publication "wrong home" "$other" 'HOME_MISMATCH' \
  bash -c 'cd "$1/projects/exchange-work" && FM_HOME="$1" "$2" verify --admission "$1/data/local-project-delivery/admissions/$(basename "$3")" --programme "$1/programme/programme.json" --root "$1/source" --step slice-a-s1-publication-integrity' _ "$other" "$DELIVERY" "$admission"

home=$(make_home wrong-project)
expect_rejected_without_publication "wrong project" "$home" 'OWNER_PROJECT_MISMATCH' \
  bash -c 'cd "$1/projects/exchange-work" && FM_HOME="$1" "$2" bind --programme "$1/programme/programme.json" --root "$1/source" --step slice-a-s1-publication-integrity --project other-owner --ref refs/heads/main --delivery-id wrong-project --maker maker-one --checker checker-one --route independent-checker' _ "$home" "$DELIVERY"

home=$(make_home missing-registered-row)
printf '%s\n' '- ghost-work [local-only] - unavailable registered owner (added 2026-09-18)' >> "$home/data/projects.md"
expect_rejected_without_publication "missing registered project" "$home" 'PROJECT_UNAVAILABLE' \
  bash -c 'cd "$1/projects/exchange-work" && FM_HOME="$1" "$2" bind --programme "$1/programme/programme.json" --root "$1/source" --step slice-a-s1-publication-integrity --project exchange-work --ref refs/heads/main --delivery-id missing-registered-row --maker maker-one --checker checker-one --route independent-checker' _ "$home" "$DELIVERY"

home=$(make_home missing-requested-ref)
expect_rejected_without_publication "missing requested ref" "$home" 'IDENTITY_UNREADABLE' \
  bash -c 'cd "$1/projects/exchange-work" && FM_HOME="$1" "$2" bind --programme "$1/programme/programme.json" --root "$1/source" --step slice-a-s1-publication-integrity --project exchange-work --ref refs/heads/missing --delivery-id missing-requested-ref --maker maker-one --checker checker-one --route independent-checker' _ "$home" "$DELIVERY"

home=$(make_home contradictory-registry-mode)
sed -i 's/\[local-only\]/[local-only direct-PR]/' "$home/data/projects.md"
expect_rejected_without_publication "contradictory registry mode" "$home" 'OWNER_MODE_MALFORMED' \
  bind "$home" slice-a-s1-publication-integrity

home=$(make_home collapsed)
expect_rejected_without_publication "maker/checker collapse" "$home" 'MAKER_CHECKER_COLLAPSE' \
  bash -c 'cd "$1/projects/exchange-work" && FM_HOME="$1" "$2" bind --programme "$1/programme/programme.json" --root "$1/source" --step slice-a-s1-publication-integrity --project exchange-work --ref refs/heads/main --delivery-id collapsed --maker same --checker same --route independent-checker' _ "$home" "$DELIVERY"

# Missing/incomplete D ownership is CNO and does not invent or register an owner.
home=$(make_home missing-owner)
expect_rejected_without_publication "missing D owner" "$home" 'OWNER_MISSING' \
  bash -c 'cd "$1" && FM_HOME="$1" "$2" bind --programme "$1/programme/programme.json" --root "$1/source" --step slice-d-s4-synthesis-integrity --project auto --ref refs/heads/main --delivery-id d-missing --maker maker-one --checker checker-one --route independent-checker' _ "$home" "$DELIVERY"
[ "$(grep -c '^-' "$home/data/projects.md")" = 1 ] || fail "missing-owner CNO changed the registry"

# Verification is the public negative surface for independently load-bearing
# source, destination, mode, programme, family, and manifest identities.
mutate_case() { # <name> <expected> <mutation command>
  local name=$1 expected=$2 mutation=$3 h a out rc post_mutation after
  h=$(make_home "$name")
  out=$(bind "$h" slice-a-s1-publication-integrity) || fail "$name setup bind failed: $out"
  a=$(printf '%s' "$out" | jq -r '.path')
  bash -c "$mutation" _ "$h" "$a"
  post_mutation=$(sha256_file "$a")
  out=$(FM_HOME="$h" "$DELIVERY" verify --admission "$a" --programme "$h/programme/programme.json" \
    --root "$h/source" --step slice-a-s1-publication-integrity 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$name unexpectedly verified: $out"
  assert_contains "$out" "$expected" "$name did not isolate its expected axis"
  [ -f "$a" ] || fail "$name removed the adverse immutable evidence"
  after=$(sha256_file "$a")
  [ "$after" = "$post_mutation" ] || fail "$name changed the immutable admission while refusing"
  pass "$name cannot qualify through verify"
}

mutate_case source-mismatch SOURCE_DESTINATION_MISMATCH 'printf changed >> "$1/source/exchange/bin/render-manifest.py"'
mutate_case destination-mismatch DESTINATION_READBACK_MISMATCH 'printf changed >> "$1/projects/exchange-work/exchange/bin/render-manifest.py"'
mutate_case wrong-object-mode DESTINATION_MODE_MISMATCH 'chmod 644 "$1/projects/exchange-work/exchange/bin/render-manifest.py"'
mutate_case stale-head CANDIDATE_HEAD_MISMATCH 'printf advance > "$1/projects/exchange-work/advance"; git -C "$1/projects/exchange-work" add advance; git -C "$1/projects/exchange-work" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m advance'
mutate_case stale-tree CANDIDATE_TREE_MISMATCH 'tmp="$2.tmp"; jq ".destination.tree=\"1111111111111111111111111111111111111111\"" "$2" > "$tmp"; mv "$tmp" "$2"; chmod 600 "$2"'
mutate_case stale-programme PROGRAMME_POLICY_MISMATCH 'tmp="$1/programme/programme.json.tmp"; jq "(.steps[] | select(.id==\"slice-a-s1-publication-integrity\") | .terminal_predicate.local_delivery.qualification_routes) |= reverse" "$1/programme/programme.json" > "$tmp"; mv "$tmp" "$1/programme/programme.json"'
mutate_case stale-manifest MANIFEST_DIGEST_MISMATCH 'tmp="$2.tmp"; jq ".manifest_sha256=\"0000000000000000000000000000000000000000000000000000000000000000\"" "$2" > "$tmp"; mv "$tmp" "$2"; chmod 600 "$2"'
mutate_case source-destination-mismatch FAMILY_MISMATCH 'tmp="$2.tmp"; jq ".artifacts[0].destination=\"exchange/bin/other.py\"" "$2" > "$tmp"; mv "$tmp" "$2"; chmod 600 "$2"'
mutate_case wrong-family ACTION_MISMATCH 'tmp="$2.tmp"; jq ".action.step=\"slice-b-s2-reference-catalog\"" "$2" > "$tmp"; mv "$tmp" "$2"; chmod 600 "$2"'
mutate_case unreadable-identity SOURCE_UNREADABLE 'rm "$1/source/exchange/bin/render-manifest.py"'

# A complete D owner is accepted only when one registered local-only project
# tracks the entire seven-member family, including the registry-named plan.
home=$(make_home d-complete)
partial="$home/projects/docs-work"
printf '%s\n' '- docs-work [local-only] - partial synthesis fixture (added 2026-09-18)' >> "$home/data/projects.md"
mkdir -p "$partial/artifacts/synthesis/bin"
cp "$home/source/artifacts/synthesis/bin/synthesis-integrity.py" "$partial/artifacts/synthesis/bin/"
chmod 755 "$partial/artifacts/synthesis/bin/synthesis-integrity.py"
git -C "$partial" init -q -b main
git -C "$partial" add .
git -C "$partial" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m partial
repo="$home/projects/synthesis-work"
printf '%s\n' '- synthesis-work [local-only] - synthesis fixture (added 2026-09-18)' >> "$home/data/projects.md"
mkdir -p "$repo"; git -C "$repo" init -q -b main
cp -R "$home/source/artifacts" "$repo/"
chmod 755 "$repo/artifacts/synthesis/bin/synthesis-integrity.py"
git -C "$repo" add .
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m synthesis
out=$(cd "$repo" && FM_HOME="$home" "$DELIVERY" bind --programme "$home/programme/programme.json" \
  --root "$home/source" --step slice-d-s4-synthesis-integrity --project auto --ref refs/heads/main \
  --delivery-id delivery-d --maker maker-one --checker checker-one --route independent-checker) \
  || fail "complete D family did not admit: $out"
[ "$(printf '%s' "$out" | jq -r '.project')" = synthesis-work ] || fail "D auto-owner did not select the complete lawful owner"
[ "$(jq -r '.artifacts | length' "$(printf '%s' "$out" | jq -r '.path')")" = 7 ] || fail "D admission did not bind the complete family"
pass "D auto-owner selection admits exactly one complete registered local-only family"

printf '\n# fm-local-project-delivery.test.sh: all assertions passed\n'
