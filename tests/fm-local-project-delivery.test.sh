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
        "local_delivery_source": {"identity": "canonical_artifact_root"},
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
        "local_delivery_source": {"identity": "canonical_artifact_root"},
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
        "local_delivery_source": {"identity": "owner_project_root"},
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

bind_as() { # <cwd> <home> <step> <project> <ref> <delivery-id> <maker> <checker> [extra args...]
  local cwd=$1 home=$2 step=$3 project=$4 ref=$5 delivery_id=$6 maker=$7 checker=$8
  shift 8
  (cd "$cwd" && FM_HOME="$home" "$DELIVERY" bind \
    --programme "$home/programme/programme.json" --root "$home/source" --step "$step" \
    --project "$project" --ref "$ref" --delivery-id "$delivery_id" \
    --maker "$maker" --checker "$checker" --route independent-checker "$@")
}

verify_as() { # <cwd> <home> <admission> <step>
  local cwd=$1 home=$2 admission=$3 step=$4
  (cd "$cwd" && FM_HOME="$home" "$DELIVERY" verify --admission "$admission" \
    --programme "$home/programme/programme.json" --root "$home/source" --step "$step")
}

bind() { # <home> <step> [extra args...]
  local home=$1 step=$2
  shift 2
  bind_as "$home/projects/exchange-work" "$home" "$step" exchange-work refs/heads/main \
    "delivery-${step}" maker-one checker-one "$@"
}

bind_with_root() { # <cwd> <home> <root> <step> <project> <delivery-id>
  local cwd=$1 home=$2 root=$3 step=$4 project=$5 delivery_id=$6
  (cd "$cwd" && FM_HOME="$home" "$DELIVERY" bind \
    --programme "$home/programme/programme.json" --root "$root" --step "$step" \
    --project "$project" --ref refs/heads/main --delivery-id "$delivery_id" \
    --maker maker-one --checker checker-one --route independent-checker)
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
  verify_as "$other/projects/exchange-work" "$other" \
  "$other/data/local-project-delivery/admissions/$(basename "$admission")" slice-a-s1-publication-integrity

home=$(make_home wrong-project)
expect_rejected_without_publication "wrong project" "$home" 'OWNER_PROJECT_MISMATCH' \
  bind_as "$home/projects/exchange-work" "$home" slice-a-s1-publication-integrity \
  other-owner refs/heads/main wrong-project maker-one checker-one

home=$(make_home missing-registered-row)
printf '%s\n' '- ghost-work [local-only] - unavailable registered owner (added 2026-09-18)' >> "$home/data/projects.md"
expect_rejected_without_publication "missing registered project" "$home" 'PROJECT_UNAVAILABLE' \
  bind_as "$home/projects/exchange-work" "$home" slice-a-s1-publication-integrity \
  exchange-work refs/heads/main missing-registered-row maker-one checker-one

home=$(make_home missing-requested-ref)
expect_rejected_without_publication "missing requested ref" "$home" 'IDENTITY_UNREADABLE' \
  bind_as "$home/projects/exchange-work" "$home" slice-a-s1-publication-integrity \
  exchange-work refs/heads/missing missing-requested-ref maker-one checker-one

home=$(make_home contradictory-registry-mode)
sed -i 's/\[local-only\]/[local-only direct-PR]/' "$home/data/projects.md"
expect_rejected_without_publication "contradictory registry mode" "$home" 'OWNER_MODE_MALFORMED' \
  bind "$home" slice-a-s1-publication-integrity

home=$(make_home collapsed)
expect_rejected_without_publication "maker/checker collapse" "$home" 'MAKER_CHECKER_COLLAPSE' \
  bind_as "$home/projects/exchange-work" "$home" slice-a-s1-publication-integrity \
  exchange-work refs/heads/main collapsed same same

# Missing/incomplete D ownership is CNO and does not invent or register an owner.
home=$(make_home missing-owner)
expect_rejected_without_publication "missing D owner" "$home" 'OWNER_MISSING' \
  bind_as "$home" "$home" slice-d-s4-synthesis-integrity \
  auto refs/heads/main d-missing maker-one checker-one
[ "$(grep -c '^-' "$home/data/projects.md")" = 1 ] || fail "missing-owner CNO changed the registry"

# Verification is the public negative surface for independently load-bearing
# source, destination, mode, programme, family, and manifest identities.
# Each mutation is a function taking the fixture home and its admission path.
mutate_append_source() { # <home> <admission>
  printf changed >> "$1/source/exchange/bin/render-manifest.py"
}

mutate_remove_source() { # <home> <admission>
  rm "$1/source/exchange/bin/render-manifest.py"
}

mutate_append_destination() { # <home> <admission>
  printf changed >> "$1/projects/exchange-work/exchange/bin/render-manifest.py"
}

mutate_destination_mode() { # <home> <admission>
  chmod 644 "$1/projects/exchange-work/exchange/bin/render-manifest.py"
}

mutate_advance_destination_head() { # <home> <admission>
  local repo="$1/projects/exchange-work"
  printf advance > "$repo/advance"
  git -C "$repo" add advance
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m advance
}

mutate_admission_json() { # <home> <admission> <jq filter>
  local admission=$2 filter=$3 tmp="$2.tmp"
  jq "$filter" "$admission" > "$tmp"
  mv "$tmp" "$admission"
  chmod 600 "$admission"
}

mutate_programme_json() { # <home> <admission> <jq filter>
  local programme="$1/programme/programme.json" filter=$3 tmp="$1/programme/programme.json.tmp"
  jq "$filter" "$programme" > "$tmp"
  mv "$tmp" "$programme"
}

mutate_case() { # <name> <expected> <mutation function> [mutation args...]
  local name=$1 expected=$2 mutation=$3 h a out rc post_mutation after
  shift 3
  h=$(make_home "$name")
  out=$(bind "$h" slice-a-s1-publication-integrity) || fail "$name setup bind failed: $out"
  a=$(printf '%s' "$out" | jq -r '.path')
  "$mutation" "$h" "$a" "$@"
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

mutate_case source-mismatch SOURCE_DESTINATION_MISMATCH mutate_append_source
mutate_case destination-mismatch DESTINATION_READBACK_MISMATCH mutate_append_destination
mutate_case wrong-object-mode DESTINATION_MODE_MISMATCH mutate_destination_mode
mutate_case stale-head CANDIDATE_HEAD_MISMATCH mutate_advance_destination_head
mutate_case stale-tree CANDIDATE_TREE_MISMATCH mutate_admission_json \
  '.destination.tree="1111111111111111111111111111111111111111"'
mutate_case stale-programme PROGRAMME_POLICY_MISMATCH mutate_programme_json \
  '(.steps[] | select(.id=="slice-a-s1-publication-integrity") | .terminal_predicate.local_delivery.qualification_routes) |= reverse'
mutate_case stale-manifest MANIFEST_DIGEST_MISMATCH mutate_admission_json \
  '.manifest_sha256="0000000000000000000000000000000000000000000000000000000000000000"'
mutate_case source-destination-mismatch FAMILY_MISMATCH mutate_admission_json \
  '.artifacts[0].destination="exchange/bin/other.py"'
mutate_case wrong-family ACTION_MISMATCH mutate_admission_json \
  '.action.step="slice-b-s2-reference-catalog"'
mutate_case unreadable-identity SOURCE_UNREADABLE mutate_remove_source

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
  --root "$repo" --step slice-d-s4-synthesis-integrity --project auto --ref refs/heads/main \
  --delivery-id delivery-d --maker maker-one --checker checker-one --route independent-checker) \
  || fail "complete D family did not admit: $out"
[ "$(printf '%s' "$out" | jq -r '.project')" = synthesis-work ] || fail "D auto-owner did not select the complete lawful owner"
[ "$(jq -r '.artifacts | length' "$(printf '%s' "$out" | jq -r '.path')")" = 7 ] || fail "D admission did not bind the complete family"
pass "D auto-owner selection admits exactly one complete registered local-only family"

# The public per-step source-root identity refuses a self-delivery whose source
# root is the destination project itself: with source and destination the same
# working files no byte or read-back mismatch could ever fire.
expect_rejected_without_publication "A self-delivery source root" "$home" 'SOURCE_IDENTITY_MISMATCH' \
  bind_with_root "$home/projects/exchange-work" "$home" "$home/projects/exchange-work" \
  slice-a-s1-publication-integrity exchange-work a-self-root

# The same pin refuses the reverse substitution: D's authorized same-root owner
# identity is not satisfied by the canonical artifact root.
expect_rejected_without_publication "D canonical-root substitution" "$home" 'SOURCE_IDENTITY_MISMATCH' \
  bind_with_root "$repo" "$home" "$home/source" slice-d-s4-synthesis-integrity auto d-canonical-root

# A forbidden source root and an absent owner are distinct authority classes for
# the same auto-census invocation: the complete registered owner makes the root a
# typed refusal, while no registered owner at all stays CNO OWNER_MISSING.
out=$(bind_with_root "$repo" "$home" "$home/source" slice-d-s4-synthesis-integrity auto d-forbidden-root 2>&1); rc=$?
[ "$rc" = 4 ] || fail "a forbidden root with a complete registered owner is not a typed refusal: rc=$rc $out"
[ "$(printf '%s' "$out" | jq -r '.status + " " + .reason_code')" = 'REFUSED SOURCE_IDENTITY_MISMATCH' ] \
  || fail "a forbidden root with a complete registered owner did not name the source identity axis: $out"
absent=$(make_home d-owner-absent)
out=$(bind_with_root "$absent" "$absent" "$absent/source" slice-d-s4-synthesis-integrity auto d-owner-absent 2>&1); rc=$?
[ "$rc" = 5 ] || fail "absent D ownership is not CNO: rc=$rc $out"
[ "$(printf '%s' "$out" | jq -r '.status + " " + .reason_code')" = 'CNO OWNER_MISSING' ] \
  || fail "absent D ownership did not stay one census CNO: $out"
pass "the census separates a forbidden source root from genuinely absent ownership"

# An unrelated registered project neither blocks nor relabels a lawful same-root
# bind: the census skips every project that is not the source root before it
# opens their Git identity, ref, or family.
home=$(make_home d-unrelated-projects)
repo="$home/projects/synthesis-work"
printf '%s\n' '- synthesis-work [local-only] - synthesis fixture (added 2026-09-20)' >> "$home/data/projects.md"
printf '%s\n' '- synthesis-backup [local-only] - second complete family (added 2026-09-20)' >> "$home/data/projects.md"
printf '%s\n' '- master-only-work [local-only] - no refs/heads/main (added 2026-09-20)' >> "$home/data/projects.md"
mkdir -p "$repo"; git -C "$repo" init -q -b main
cp -R "$home/source/artifacts" "$repo/"
chmod 755 "$repo/artifacts/synthesis/bin/synthesis-integrity.py"
git -C "$repo" add .
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m synthesis
cp -R "$repo" "$home/projects/synthesis-backup"
master="$home/projects/master-only-work"
mkdir -p "$master"; git -C "$master" init -q -b master
printf 'unrelated\n' > "$master/README.md"
git -C "$master" add .
git -C "$master" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m unrelated
out=$(bind_with_root "$repo" "$home" "$repo" slice-d-s4-synthesis-integrity auto delivery-d-unrelated) \
  || fail "unrelated registered projects blocked the lawful same-root D bind: $out"
[ "$(printf '%s' "$out" | jq -r '.status + " " + .project')" = 'ADMITTED synthesis-work' ] \
  || fail "the census did not admit the sealed source root owner: $out"
[ "$(jq -r '.artifacts | length' "$(printf '%s' "$out" | jq -r '.path')")" = 7 ] \
  || fail "the admitted same-root candidate is not the complete family"
pass "unrelated registered projects do not block the same-root owner census"

# A D successor admission seals its same-root source independently of the
# programme's canonical artifact root. The shared resolver must consume that
# sealed identity rather than substitute its one ambient/global root.
home=$(make_home d-sealed-root)
repo="$home/projects/synthesis-work"
printf '%s\n' '- synthesis-work [local-only] - synthesis fixture (added 2026-09-20)' >> "$home/data/projects.md"
mkdir -p "$repo"; git -C "$repo" init -q -b main
cp -R "$home/source/artifacts" "$repo/"
chmod 755 "$repo/artifacts/synthesis/bin/synthesis-integrity.py"
git -C "$repo" add .
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m synthesis
out=$(cd "$repo" && FM_HOME="$home" "$DELIVERY" bind --programme "$home/programme/programme.json" \
  --root "$repo" --step slice-d-s4-synthesis-integrity --project auto --ref refs/heads/main \
  --delivery-id delivery-d-sealed --maker maker-one --checker checker-one --route independent-checker) \
  || fail "same-root D bind failed: $out"
admission=$(printf '%s' "$out" | jq -r '.path')
admission_sha=$(sha256_file "$admission")
head=$(jq -r '.destination.head' "$admission")
tree=$(jq -r '.destination.tree' "$admission")
policy_digest=$(jq -r '.action.local_delivery_policy_sha256' "$admission")
registry_generation=$(jq -r '.owner.registry_sha256' "$admission")
sealed=$(FM_HOME="$home" "$DELIVERY" verify --admission "$admission" \
  --programme "$home/programme/programme.json" --root-from-admission --step slice-d-s4-synthesis-integrity) \
  || fail "same-root D sealed verification failed: $sealed"
[ "$(printf '%s' "$sealed" | jq -r '.status')" = ACCEPTED ] || fail "same-root D sealed verification was not accepted"
pass "sealed verification consumes the D admission source root without ambient substitution"

# Wrong-root negative 1: the canonical seed root is not a fallback for the
# admitted repaired/same-root candidate.
printf '#!/usr/bin/env python3\nprint("defective canonical")\n' > "$home/source/artifacts/synthesis/bin/synthesis-integrity.py"
out=$(FM_HOME="$home" "$DELIVERY" verify --admission "$admission" \
  --programme "$home/programme/programme.json" --root "$home/source" --step slice-d-s4-synthesis-integrity 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "canonical seed root unexpectedly verified the same-root D admission"
assert_contains "$out" 'SOURCE_IDENTITY_MISMATCH' "canonical seed root fallback did not refuse"
pass "wrong-root negative: canonical seed root fallback refuses"

# Wrong-root negative 2: cwd and an ambient root variable cannot replace the
# source root sealed in the admission.
mkdir -p "$home/ambient/artifacts/synthesis/bin"
printf 'ambient\n' > "$home/ambient/artifacts/synthesis/bin/synthesis-integrity.py"
sealed=$(cd "$home/ambient" && FM_PROGRAMME_ROOT="$home/ambient" FM_HOME="$home" "$DELIVERY" verify \
  --admission "$admission" --programme "$home/programme/programme.json" --root-from-admission \
  --step slice-d-s4-synthesis-integrity) || fail "ambient cwd/root displaced sealed verification: $sealed"
[ "$(printf '%s' "$sealed" | jq -r '.status')" = ACCEPTED ] || fail "ambient cwd/root changed sealed verification outcome"
out=$(cd "$home/ambient" && FM_HOME="$home" "$DELIVERY" verify --admission "$admission" \
  --programme "$home/programme/programme.json" --root "$PWD" --step slice-d-s4-synthesis-integrity 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "ambient cwd/root substitution unexpectedly verified"
assert_contains "$out" 'SOURCE_IDENTITY_MISMATCH' "ambient cwd/root substitution did not refuse"
pass "wrong-root negative: ambient cwd and root substitution refuses"

# Wrong-root negative 3: a source-root edit to another project is not accepted
# as the sealed project/root identity.
wrong="$home/projects/wrong-synthesis"
cp -R "$repo" "$wrong"
mutated="$home/data/local-project-delivery/admissions/delivery-d-wrong-project.json"
jq --arg root "$wrong" '.admission_id="delivery-d-wrong-project" | .delivery_id="delivery-d-wrong-project" | .source.root=$root' "$admission" > "$mutated"
chmod 600 "$mutated"
out=$(FM_HOME="$home" "$DELIVERY" verify --admission "$mutated" --programme "$home/programme/programme.json" \
  --root-from-admission --step slice-d-s4-synthesis-integrity 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "mismatched project/root admission unexpectedly verified"
assert_contains "$out" 'SOURCE_IDENTITY_MISMATCH' "mismatched project/root did not refuse as an identity mismatch"
pass "wrong-root negative: mismatched project id and root refuses"

# A sealed root that is not one readable absolute path is the same typed
# authenticity refusal, never an untyped interpreter failure.
null_root="$home/data/local-project-delivery/admissions/delivery-d-null-root.json"
python3 - "$admission" "$null_root" <<'NULLROOT'
import json, sys

doc = json.load(open(sys.argv[1]))
doc["admission_id"] = doc["delivery_id"] = "delivery-d-null-root"
doc["source"]["root"] = doc["source"]["root"] + "\x00b"
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(doc, sort_keys=True, indent=2) + "\n")
NULLROOT
chmod 600 "$null_root"
out=$(FM_HOME="$home" "$DELIVERY" verify --admission "$null_root" --programme "$home/programme/programme.json" \
  --root-from-admission --step slice-d-s4-synthesis-integrity 2>&1); rc=$?
[ "$rc" = 4 ] || fail "malformed sealed root did not return one typed refusal: rc=$rc $out"
assert_contains "$out" 'MANIFEST_AUTHENTICITY' "malformed sealed root did not refuse as an authenticity mismatch"
case "$out" in *Traceback*) fail "malformed sealed root escaped as an untyped traceback: $out" ;; esac
pass "wrong-root negative: a malformed sealed source root is the typed authenticity refusal"

checker_rel=data/local-project-delivery/d-sealed-checker.json
checker_file="$home/$checker_rel"
jq -n --arg admission "$admission_sha" --arg head "$head" --arg tree "$tree" '
  {schema:"fm-local-checker-receipt/v2",receipt_id:"checker-d-sealed",admission_sha256:$admission,
   candidate:{head:$head,tree:$tree},maker:{id:"maker-one"},checker:{id:"checker-one"},
   pipeline:"independent-checker",outcome:"checks-passed"}' > "$checker_file"
chmod 600 "$checker_file"
checker_sha=$(sha256_file "$checker_file")
receipt_rel=data/local-project-delivery/d-sealed-delivery.json
receipt_file="$home/$receipt_rel"
jq -n --arg head "$head" --arg tree "$tree" --arg admission_rel "${admission#"$home/"}" --arg admission_sha "$admission_sha" \
  --arg checker_rel "$checker_rel" --arg checker_sha "$checker_sha" '
  {schema:"fm-local-project-delivery-receipt/v2",delivery_id:"delivery-d-sealed",generation:1,
   owner:{kind:"local_project_delivery",ref:"synthesis-work"},
   candidate:{head:$head,tree:$tree,delivery_id:"delivery-d-sealed",owner_project:"synthesis-work",ref:"refs/heads/main"},
   admission:{path:$admission_rel,sha256:$admission_sha},maker:{id:"maker-one",commit:$head},checker:{id:"checker-one"},
   privacy:{classification:"private_local",exposure:"digests_only",published_private_bytes:false},
   qualification:{pipeline:"independent-checker",outcome:"checks-passed",evidence_refs:[{path:$checker_rel,sha256:$checker_sha}]},
   read_back:{status:"MATCH",observer:"checker-one"}}' > "$receipt_file"
chmod 600 "$receipt_file"
receipt_sha=$(sha256_file "$receipt_file")
evidence="$home/programme/evidence/slice-d.json"
jq -n --arg head "$head" --arg tree "$tree" --arg receipt_rel "$receipt_rel" --arg receipt_sha "$receipt_sha" \
  --arg checker_rel "$checker_rel" --arg checker_sha "$checker_sha" --arg policy_digest "$policy_digest" '
  {schema:"fm-accepted-owner-evidence/v1",evidence_id:"delivery-d-sealed",programme_id:"cleanroom-af-package",
   step:"slice-d-s4-synthesis-integrity",project:"fixture-project",work_id:"cleanroom-af-package",generation:1,
   owner:{kind:"local_project_delivery",ref:"synthesis-work"},outcome:"DELIVERED_QUALIFIED",
   candidate:{head:$head,tree:$tree,delivery_id:"delivery-d-sealed",owner_project:"synthesis-work",ref:"refs/heads/main"},
   policy:{id:"local-delivery-policy",digest:$policy_digest},verifier:{tool:"fm-local-project-delivery/v2"},
   qualification:{pipeline:"independent-checker",outcome:"checks-passed",evidence_refs:[{path:$checker_rel,sha256:$checker_sha}]},
   delivery:{receipt:{path:$receipt_rel,sha256:$receipt_sha}},
   privacy:{classification:"private_local",exposure:"digests_only",published_private_bytes:false},
   captures:[],sources:[],observed_bad:[],superseded_by:null}' > "$evidence"
evidence_sha=$(sha256_file "$evidence")
tmp="$home/programme/programme.json.tmp"
jq --arg sha "$evidence_sha" --arg head "$head" --arg tree "$tree" --arg policy "$policy_digest" '
  .steps = [.steps[] | select(.id=="slice-d-s4-synthesis-integrity") | del(.depends_on)] |
  (.steps[0].terminal_predicate) +=
    {owner_ref:"synthesis-work",evidence_sha256:$sha,evidence_generation:1,policy_digest:$policy,
     candidate:{head:$head,tree:$tree,delivery_id:"delivery-d-sealed",owner_project:"synthesis-work",ref:"refs/heads/main"}}' \
  "$home/programme/programme.json" > "$tmp" && mv "$tmp" "$home/programme/programme.json"
mkdir -p "$home/fake-bin"
cat > "$home/fake-bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 1
printf 'count: 0\n'
SH
chmod +x "$home/fake-bin/tasks-axi"
resolved=$(PATH="$home/fake-bin:$PATH" FM_HOME="$home" FM_CONTINUATION_TODAY=2026-09-20 \
  "$ROOT/bin/fm-continuation-resolve.sh" resolve --programme "$home/programme/programme.json" --root "$home/source") \
  || fail "sealed-root resolver integration failed: $resolved"
[ "$(printf '%s' "$resolved" | jq -r '.next_action // "COMPLETE"')" = COMPLETE ] \
  || fail "resolver substituted the canonical root for D: $(printf '%s' "$resolved" | jq -c '{next_action,reason_code,cno}')"
[ "$(printf '%s' "$resolved" | jq -r '.completed | map(.id) | join(",")')" = slice-d-s4-synthesis-integrity ] \
  || fail "resolver did not complete the same-root D admission"
pass "shared continuation verification consumes the exact source root sealed in the D admission"

# Wrong-root negative 4: stale registry generation remains a refusal.
printf '%s\n' '- later-owner [local-only] - later generation (added 2026-09-20)' >> "$home/data/projects.md"
out=$(FM_HOME="$home" "$DELIVERY" verify --admission "$admission" --programme "$home/programme/programme.json" \
  --root-from-admission --step slice-d-s4-synthesis-integrity 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "stale registry generation unexpectedly verified"
assert_contains "$out" 'MANIFEST_AUTHENTICITY' "stale registry generation did not refuse"
pass "wrong-root negative: stale registry generation refuses"

# Wrong-root negative 6: a positive admission cannot later be verified through
# a different source root.
out=$(FM_HOME="$home" "$DELIVERY" verify --admission "$admission" \
  --programme "$home/programme/programme.json" --root "$home/source" --step slice-d-s4-synthesis-integrity 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "successful admission later verified against another root"
assert_contains "$out" 'SOURCE_IDENTITY_MISMATCH' "post-admission wrong-root verification did not refuse"
pass "wrong-root negative: successful admission followed by another-root verification refuses"

# The sealed D admission itself carries the registry generation it was bound
# under; this literal makes the stale-registry expectation above independent of
# resolver presentation.
[ "$registry_generation" != "$(sha256_file "$home/data/projects.md")" ] \
  || fail "registry mutation did not create the intended successor-generation mismatch"

# Qualify one admitted delivery the way its owners do: a private checker
# receipt, a private delivery receipt that binds the admission by digest, the
# public digests-only owner record, and the programme pins for that record.
qualify_local_delivery() { # <home> <step> <admission> <project> <delivery-id> <generation>
  local home=$1 step=$2 admission=$3 project=$4 delivery=$5 generation=$6
  local head tree admission_rel admission_sha policy_digest checker_rel checker_file checker_sha
  local receipt_rel receipt_file receipt_sha evidence_rel evidence evidence_sha tmp
  head=$(jq -r '.destination.head' "$admission")
  tree=$(jq -r '.destination.tree' "$admission")
  admission_rel=${admission#"$home/"}
  admission_sha=$(sha256_file "$admission")
  policy_digest=$(jq -r '.action.local_delivery_policy_sha256' "$admission")
  mkdir -p "$home/data/local-project-delivery"
  checker_rel="data/local-project-delivery/$delivery-checker.json"
  checker_file="$home/$checker_rel"
  jq -n --arg admission "$admission_sha" --arg head "$head" --arg tree "$tree" --arg delivery "$delivery" '
    {schema:"fm-local-checker-receipt/v2",receipt_id:("checker-"+$delivery),admission_sha256:$admission,
     candidate:{head:$head,tree:$tree},maker:{id:"maker-one"},checker:{id:"checker-one"},
     pipeline:"independent-checker",outcome:"checks-passed"}' > "$checker_file"
  chmod 600 "$checker_file"
  checker_sha=$(sha256_file "$checker_file")
  receipt_rel="data/local-project-delivery/$delivery-delivery.json"
  receipt_file="$home/$receipt_rel"
  jq -n --arg head "$head" --arg tree "$tree" --arg admission_rel "$admission_rel" --arg admission_sha "$admission_sha" \
    --arg checker_rel "$checker_rel" --arg checker_sha "$checker_sha" --arg project "$project" \
    --arg delivery "$delivery" --argjson generation "$generation" '
    {schema:"fm-local-project-delivery-receipt/v2",delivery_id:$delivery,generation:$generation,
     owner:{kind:"local_project_delivery",ref:$project},
     candidate:{head:$head,tree:$tree,delivery_id:$delivery,owner_project:$project,ref:"refs/heads/main"},
     admission:{path:$admission_rel,sha256:$admission_sha},maker:{id:"maker-one",commit:$head},checker:{id:"checker-one"},
     privacy:{classification:"private_local",exposure:"digests_only",published_private_bytes:false},
     qualification:{pipeline:"independent-checker",outcome:"checks-passed",evidence_refs:[{path:$checker_rel,sha256:$checker_sha}]},
     read_back:{status:"MATCH",observer:"checker-one"}}' > "$receipt_file"
  chmod 600 "$receipt_file"
  receipt_sha=$(sha256_file "$receipt_file")
  evidence_rel=$(jq -r --arg step "$step" '.steps[] | select(.id==$step) | .terminal_predicate.evidence' "$home/programme/programme.json")
  evidence="$home/programme/$evidence_rel"
  jq -n --arg head "$head" --arg tree "$tree" --arg receipt_rel "$receipt_rel" --arg receipt_sha "$receipt_sha" \
    --arg checker_rel "$checker_rel" --arg checker_sha "$checker_sha" --arg policy_digest "$policy_digest" \
    --arg step "$step" --arg project "$project" --arg delivery "$delivery" --argjson generation "$generation" '
    {schema:"fm-accepted-owner-evidence/v1",evidence_id:$delivery,programme_id:"cleanroom-af-package",
     step:$step,project:"fixture-project",work_id:"cleanroom-af-package",generation:$generation,
     owner:{kind:"local_project_delivery",ref:$project},outcome:"DELIVERED_QUALIFIED",
     candidate:{head:$head,tree:$tree,delivery_id:$delivery,owner_project:$project,ref:"refs/heads/main"},
     policy:{id:"local-delivery-policy",digest:$policy_digest},verifier:{tool:"fm-local-project-delivery/v2"},
     qualification:{pipeline:"independent-checker",outcome:"checks-passed",evidence_refs:[{path:$checker_rel,sha256:$checker_sha}]},
     delivery:{receipt:{path:$receipt_rel,sha256:$receipt_sha}},
     privacy:{classification:"private_local",exposure:"digests_only",published_private_bytes:false},
     captures:[],sources:[],observed_bad:[],superseded_by:null}' > "$evidence"
  evidence_sha=$(sha256_file "$evidence")
  tmp="$home/programme/programme.json.tmp"
  jq --arg step "$step" --arg sha "$evidence_sha" --arg head "$head" --arg tree "$tree" \
    --arg policy_digest "$policy_digest" --arg project "$project" --arg delivery "$delivery" \
    --argjson generation "$generation" '
    (.steps[] | select(.id==$step) | .terminal_predicate) +=
      {owner_ref:$project,evidence_sha256:$sha,evidence_generation:$generation,policy_digest:$policy_digest,
       candidate:{head:$head,tree:$tree,delivery_id:$delivery,owner_project:$project,ref:"refs/heads/main"}}' \
    "$home/programme/programme.json" > "$tmp" && mv "$tmp" "$home/programme/programme.json"
}

# Mixed A/B/D registry generations. A and B qualify together under one registry
# snapshot; registering D's owner advances that snapshot, so the current D
# record cannot complete alongside the earlier A and B records even though it
# verifies on its own; only restarting the complete successor sequence under the
# current snapshot resolves all three.
home=$(make_home mixed-generations)
mkdir -p "$home/fake-bin"
cat > "$home/fake-bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 1
printf 'count: 0\n'
SH
chmod +x "$home/fake-bin/tasks-axi"
resolve_mixed() {
  PATH="$home/fake-bin:$PATH" FM_HOME="$home" FM_CONTINUATION_TODAY=2026-09-20 \
    "$ROOT/bin/fm-continuation-resolve.sh" resolve --programme "$home/programme/programme.json" --root "$home/source"
}
out=$(bind_with_root "$home/projects/exchange-work" "$home" "$home/source" \
  slice-a-s1-publication-integrity exchange-work mixed-a-g1) || fail "generation-1 A bind failed: $out"
qualify_local_delivery "$home" slice-a-s1-publication-integrity "$(printf '%s' "$out" | jq -r '.path')" exchange-work mixed-a-g1 1
out=$(bind_with_root "$home/projects/exchange-work" "$home" "$home/source" \
  slice-b-s2-reference-catalog exchange-work mixed-b-g1) || fail "generation-1 B bind failed: $out"
qualify_local_delivery "$home" slice-b-s2-reference-catalog "$(printf '%s' "$out" | jq -r '.path')" exchange-work mixed-b-g1 1
resolved=$(resolve_mixed) || fail "generation-1 A/B resolver integration failed: $resolved"
[ "$(printf '%s' "$resolved" | jq -r '.completed | map(.id) | join(",")')" = 'slice-a-s1-publication-integrity,slice-b-s2-reference-catalog' ] \
  || fail "same-snapshot A and B did not complete: $(printf '%s' "$resolved" | jq -c '.completed')"
[ "$(printf '%s' "$resolved" | jq -r '.next_action')" = slice-d-s4-synthesis-integrity ] \
  || fail "unbound D is not the next action: $(printf '%s' "$resolved" | jq -c '{next_action,reason_code}')"
pass "A and B qualify together under one registry snapshot"

repo="$home/projects/synthesis-work"
printf '%s\n' '- synthesis-work [local-only] - synthesis fixture (added 2026-09-20)' >> "$home/data/projects.md"
mkdir -p "$repo"; git -C "$repo" init -q -b main
cp -R "$home/source/artifacts" "$repo/"
chmod 755 "$repo/artifacts/synthesis/bin/synthesis-integrity.py"
git -C "$repo" add .
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m synthesis
out=$(bind_with_root "$repo" "$home" "$repo" slice-d-s4-synthesis-integrity auto mixed-d-g1) \
  || fail "successor-snapshot D bind failed: $out"
admission_d=$(printf '%s' "$out" | jq -r '.path')
qualify_local_delivery "$home" slice-d-s4-synthesis-integrity "$admission_d" synthesis-work mixed-d-g1 1
sealed=$(FM_HOME="$home" "$DELIVERY" verify --admission "$admission_d" \
  --programme "$home/programme/programme.json" --root-from-admission --step slice-d-s4-synthesis-integrity) \
  || fail "current-generation D admission does not verify on its own: $sealed"
[ "$(printf '%s' "$sealed" | jq -r '.status')" = ACCEPTED ] || fail "current-generation D admission was not accepted"
mixed=$(resolve_mixed) || fail "mixed-generation resolver invocation failed structurally: $mixed"
[ "$(printf '%s' "$mixed" | jq -r '.completed | length')" = 0 ] \
  || fail "mixed registry generations still completed steps: $(printf '%s' "$mixed" | jq -c '.completed')"
[ "$(printf '%s' "$mixed" | jq -r '.next_action + " " + .reason_code')" = 'slice-a-s1-publication-integrity OWNER_EVIDENCE_CANDIDATE_MISMATCH' ] \
  || fail "mixed registry generations did not stop continuation: $(printf '%s' "$mixed" | jq -c '{next_action,authority_state,reason_code,cno}')"
pass "A/B/D records mixed across registry generations refuse while the current D record verifies alone"

out=$(bind_with_root "$home/projects/exchange-work" "$home" "$home/source" \
  slice-a-s1-publication-integrity exchange-work mixed-a-g2) || fail "successor A bind failed: $out"
qualify_local_delivery "$home" slice-a-s1-publication-integrity "$(printf '%s' "$out" | jq -r '.path')" exchange-work mixed-a-g2 2
out=$(bind_with_root "$home/projects/exchange-work" "$home" "$home/source" \
  slice-b-s2-reference-catalog exchange-work mixed-b-g2) || fail "successor B bind failed: $out"
qualify_local_delivery "$home" slice-b-s2-reference-catalog "$(printf '%s' "$out" | jq -r '.path')" exchange-work mixed-b-g2 2
resolved=$(resolve_mixed) || fail "successor sequence resolver integration failed: $resolved"
[ "$(printf '%s' "$resolved" | jq -r '.completed | map(.id) | join(",")')" = 'slice-a-s1-publication-integrity,slice-b-s2-reference-catalog,slice-d-s4-synthesis-integrity' ] \
  || fail "the restarted successor sequence did not complete A/B/D: $(printf '%s' "$resolved" | jq -c '.completed')"
[ "$(printf '%s' "$resolved" | jq -r '.next_action // "COMPLETE"')" = COMPLETE ] \
  || fail "the restarted successor sequence did not exhaust the programme: $(printf '%s' "$resolved" | jq -c '{next_action,reason_code}')"
pass "restarting the complete successor sequence under the current snapshot qualifies A/B/D"

printf '\n# fm-local-project-delivery.test.sh: all assertions passed\n'
