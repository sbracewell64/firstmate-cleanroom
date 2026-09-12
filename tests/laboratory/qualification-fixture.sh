#!/usr/bin/env bash
set -euo pipefail
ROOT=${FM_PAIR_STAGE_ROOT:-${FM_QUALIFICATION_CONSUMER_ROOT:?}}
LAB=$1
export LAB
export NM_HOME=$2 NO_MISTAKES_HOME=$2
WT=$3
export HOME="$LAB/home" FM_HOME="$LAB/fm" FM_STATE_OVERRIDE="$LAB/fm/state" FM_DATA_OVERRIDE="$LAB/fm/data"
export NO_MISTAKES_NO_UPDATE_CHECK=1 NO_MISTAKES_TELEMETRY=0
mkdir -p "$HOME" "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE/source" "$LAB/bin"
export PATH="$LAB/bin:$PATH"
cat > "$LAB/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
 --version) echo 'no-mistakes version v1.61.0 (0af0be6) 2026-08-31T14:04:25Z' ;;
 'axi status'*)
  jq -r '"run:\n  id: \""+.run+"\"\n  branch: "+.branch+"\n  status: ci\n  head: \""+.head+"\"\n  pr: \""+.evidence.pr+"\"\nbranch_sync:\n  state: pipeline_owned"' "$LAB/qualification.json" |
   { if [ -f "$LAB/canonical-head" ]; then sed "s/  head:.*/  head: \"$(cat "$LAB/canonical-head")\"/"; else cat; fi; }
  ;;
 'axi logs'*)
  if [ "${FM_PAIR_LEGACY:-}" = 1 ] && [ "${FM_PAIR_RACE:-}" = 1 ]; then
   touch "$LAB/race-ready"
   for ((i=0; i<1200; i++)); do
    [ ! -f "$LAB/race-release" ] || break
    sleep .05
   done
   [ -f "$LAB/race-release" ] || exit 92
  fi
  echo 'all CI checks passed - still monitoring until merged or closed'
  ;;
 'axi qualification'*)
  [ "$(sha256sum "$NM_QUALIFICATION_TEST_BINARY" | cut -d' ' -f1)" = "$NM_QUALIFICATION_TEST_SHA256" ] || exit 91
  call_dir=$(mktemp -d "$LAB/artifact-call.XXXXXX")
  rc=0
  "$NM_QUALIFICATION_TEST_BINARY" "$@" > "$call_dir/stdout" 2> "$call_dir/stderr" || rc=$?
  jq -nc --arg executable "$NM_QUALIFICATION_TEST_BINARY" --arg sha "$NM_QUALIFICATION_TEST_SHA256" \
   --arg home "$HOME" --arg nm_home "$NM_HOME" --argjson status "$rc" \
   --rawfile output "$call_dir/stdout" --rawfile error "$call_dir/stderr" \
   --argjson argv "$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]')" \
   '{executable:$executable,executable_sha256:$sha,home:$home,nm_home:$nm_home,argv:$argv,status:$status,stdout:$output,stderr:$error}' > "$call_dir/invocation.json"
  [ "$rc" -eq 0 ] || exit "$rc"
  if [ "${FM_PAIR_LEGACY:-}" != 1 ] && [ "${FM_PAIR_RACE:-}" = 1 ] && [ ! -f "$LAB/race-ready" ] \
      && { [ "${FM_PAIR_LATE:-}" != 1 ] || [[ " $* " == *' --attempt '* ]]; }; then
   touch "$LAB/race-ready"
   for ((i=0; i<1200; i++)); do
    [ ! -f "$LAB/race-release" ] || break
    sleep .05
   done
   [ -f "$LAB/race-release" ] || exit 92
  fi
  cat "$call_dir/stdout"
  ;;
 *) echo "forbidden producer call: $*" >&2; exit 93 ;;
esac
EOF
cat > "$LAB/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$*" in
 *headRefOid*) jq -r .head "$LAB/qualification.json" ;;
 *) echo "forbidden forge call: $*" >&2; exit 94 ;;
esac
EOF
for tool in gh-axi glab curl wget ssh; do
 printf '#!/usr/bin/env bash\necho forbidden-transport >&2\nexit 95\n' > "$LAB/bin/$tool"
done
chmod +x "$LAB/bin/"*
printf '{"pid":4242,"started_at":"2026-09-06T00:00:00Z"}\n' > "$NM_HOME/daemon.pid"
RUN=$(jq -r .run "$LAB/qualification.json")
B=$(jq -r .head "$LAB/qualification.json")
PR=$(jq -r .evidence.pr "$LAB/qualification.json")
A=$(git -C "$WT" rev-parse HEAD^)
git -C "$WT" reset --hard "$A" >/dev/null
printf 'worktree=%s\nproject=%s\nharness=echo\nkind=ship\nmode=no-mistakes\nyolo=off\nspawn_gen=admission-generation\n' "$WT" "$WT" > "$FM_STATE_OVERRIDE/source.meta"
printf '# Synthetic admission\n' > "$FM_DATA_OVERRIDE/source/brief.md"
stage() { "$ROOT/bin/fm-stage.sh" source "$@"; }
meta() { sed -n "s/^$1=//p" "$FM_STATE_OVERRIDE/source.meta"; }
refuses() {
 local result
 result=$(mktemp "$LAB/refusal.XXXXXX")
 printf '%s\n' "$@" > "$result.argv"
 if "$@" > "$result" 2>&1; then echo "unexpected success: $*" >&2; exit 1; fi
 cp "$result" "$LAB/refusal.out"
}
