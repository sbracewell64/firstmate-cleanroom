#!/usr/bin/env bash
# fm-tool-profile.sh - single owner of the qualified tool-profile observation.
#
# Observes, from the shell it is invoked in, the identity of every tool the
# deterministic gates execute and reports each as exactly one state, so the
# same probe can run from every real consumer - a session start, a worker
# command, a gate agent's shell, the deterministic lint shell, a login shell,
# and the CI fixture - and the observations can be compared instead of assumed.
# It only observes: it never installs, never edits PATH, and never starts a
# service. A tool that is required but not QUALIFIED is reported as one typed
# ENVIRONMENT_UNREADY line naming the owner action, and the exit status is 1.
#
# States (exactly one per tool):
#   QUALIFIED            resolves and satisfies its pin, floor, and capability probe
#   ABSENT               no executable resolves on PATH
#   PRESENT_BELOW_FLOOR  resolves but is below its floor or fails its feature probe
#   PINNED_MISMATCH      resolves but is not the exact pinned version (shellcheck
#                        and actionlint always; tasks-axi only under --strict-pin)
#   CAPABILITY_MISSING   resolves but cannot execute what a gate executes (node-ts)
# Profile facts are observed alongside: NM_HOME, PATH[0], and the parent
# command. --expect-nm-home and --expect-path0 turn a divergence into a
# PROFILE_MISMATCH row, which also fails the probe. Run the probe FROM the shell
# under test (for example `bash -lc bin/fm-tool-profile.sh ...` for a login
# shell); it reports that shell's PATH, not its own.
#
# Pins and floors are projected from their owners and never retyped here:
#   ShellCheck   exact pin   bin/fm-lint.sh --required-version
#   actionlint   exact pin   bin/fm-lint-workflows.sh --required-version
#   tasks-axi    floor       FM_TASKS_AXI_MIN plus the feature probe in bin/fm-tasks-axi-lib.sh
#                exact pin   FM_TASKS_AXI_PIN in the same file (CI installs exactly this)
#   no-mistakes  floor       NO_MISTAKES_MIN in bin/fm-bootstrap.sh
#   node-ts      capability  plain execution of a .ts file, which is what the Pi
#                            extension tests do; process.features.typescript is
#                            reported as the structural detail
# A pin below its own floor is refused by --pin, so CI cannot install a version
# the local floor would reject.
#
# The default required set is what the deterministic lint and test gates
# execute: shellcheck actionlint tasks-axi node-ts workflow-yaml. no-mistakes is observed and
# reported but only required when --require names it.
#
# Usage:
#   fm-tool-profile.sh [--expect-nm-home <path>] [--expect-path0 <dir>]
#                      [--require <tool>[,<tool>...]] [--strict-pin] [--json]
#   fm-tool-profile.sh --pin shellcheck|actionlint|tasks-axi     print the exact pin
#   fm-tool-profile.sh --floor tasks-axi|no-mistakes             print the floor
#   fm-tool-profile.sh --help
# Exit: 0 every required tool QUALIFIED and no PROFILE_MISMATCH; 1 otherwise;
#       2 usage or an owner that could not be projected.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-tool-profile.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

KNOWN_TOOLS="shellcheck actionlint tasks-axi no-mistakes node-ts workflow-yaml"
DEFAULT_REQUIRE="shellcheck actionlint tasks-axi node-ts workflow-yaml"

fm_tool_profile_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

die_usage() {
  printf 'fm-tool-profile.sh: %s\n' "$*" >&2
  exit 2
}

# fm_tool_profile_ver_ge <have x.y.z> <min x.y.z>: 0 when have >= min.
fm_tool_profile_ver_ge() {
  local a b c x y z
  IFS=. read -r a b c <<< "$1"
  IFS=. read -r x y z <<< "$2"
  [ "$a" -gt "$x" ] && return 0
  [ "$a" -eq "$x" ] || return 1
  [ "$b" -gt "$y" ] && return 0
  [ "$b" -eq "$y" ] || return 1
  [ "$c" -ge "$z" ]
}

# First x.y.z triple in a tool's --version output, or nothing. Used only for
# the floor-based tools (tasks-axi, no-mistakes, node); the exact-pin tools are
# read exactly as their gate reads them so the probe can never pass a version
# the gate refuses.
fm_tool_profile_semver_of() {
  printf '%s\n' "$1" | sed -nE 's/.*[^0-9.]([0-9]+\.[0-9]+\.[0-9]+).*/\1/p; s/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1
}

# The version string bin/fm-lint.sh compares to its pin: the `version:` line.
fm_tool_profile_shellcheck_version_of() {
  printf '%s\n' "$1" | awk '/^version:/ {print $2; exit}'
}

# The version string bin/fm-lint-workflows.sh compares to its pin: the whole
# first line of `actionlint -version`.
fm_tool_profile_actionlint_version_of() {
  printf '%s\n' "$1" | awk 'NR==1 {print; exit}'
}

pin_of() {  # <tool> -> exact pin, projected from the owner
  case "$1" in
    shellcheck) "$ROOT/bin/fm-lint.sh" --required-version ;;
    actionlint) "$ROOT/bin/fm-lint-workflows.sh" --required-version ;;
    tasks-axi)
      # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
      ( . "$ROOT/bin/fm-tasks-axi-lib.sh" && printf '%s\n' "${FM_TASKS_AXI_PIN:-}" )
      ;;
    *) return 1 ;;
  esac
}

floor_of() {  # <tool> -> floor, projected from the owner
  case "$1" in
    tasks-axi)
      # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
      ( . "$ROOT/bin/fm-tasks-axi-lib.sh" && printf '%s\n' "${FM_TASKS_AXI_MIN:-}" )
      ;;
    no-mistakes)
      # bin/fm-bootstrap.sh is the owner of NO_MISTAKES_MIN; it cannot be sourced
      # without running session sweeps, so the constant is projected from it.
      sed -nE 's/^NO_MISTAKES_MIN=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$ROOT/bin/fm-bootstrap.sh" | head -1
      ;;
    *) return 1 ;;
  esac
}

owner_of() {  # <tool> -> the owner action to run when the tool is not QUALIFIED
  case "$1" in
    shellcheck) printf 'bin/fm-install-shellcheck.sh <destination-directory> (installs ShellCheck %s; put that directory ahead of any other copy on PATH)\n' "$PIN_SHELLCHECK" ;;
    actionlint) printf 'bin/fm-install-actionlint.sh <destination-directory> (installs actionlint %s; put that directory ahead of any other copy on PATH)\n' "$PIN_ACTIONLINT" ;;
    tasks-axi) printf 'install tasks-axi %s ahead of any older copy on PATH (bin/fm-bootstrap.sh install tasks-axi, or the environment'"'"'s scoped pin owner)\n' "$PIN_TASKS_AXI" ;;
    no-mistakes) printf 'install no-mistakes %s or newer ahead of any older copy on PATH (bin/fm-bootstrap.sh install no-mistakes, or the environment'"'"'s scoped pin owner)\n' "$FLOOR_NO_MISTAKES" ;;
    node-ts) printf 'put a Node build that executes .ts files without flags ahead of the current node on PATH (official Node release binaries from 23.6 do; distro node packages are often built without process.features.typescript)\n' ;;
    workflow-yaml) printf 'provision PyYAML in the validation Python environment (or Ruby with YAML/JSON); bin/fm-workflow-yaml.sh --probe owns the capability and selected backend\n' ;;
    profile) printf 'the launcher or environment that exports NM_HOME and PATH (export both before starting the session server and re-select them after any login-shell initialization)\n' ;;
  esac
}

EXPECT_NM_HOME=
EXPECT_NM_HOME_SET=0
EXPECT_PATH0=
REQUIRE="$DEFAULT_REQUIRE"
STRICT_PIN=0
JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) fm_tool_profile_usage; exit 0 ;;
    --pin)
      [ "$#" -ge 2 ] || die_usage "--pin requires a tool"
      pin=$(pin_of "$2") || die_usage "no exact pin is owned for $2"
      [ -n "$pin" ] || die_usage "the pin for $2 could not be projected from its owner"
      if [ "$2" = tasks-axi ]; then
        floor=$(floor_of tasks-axi)
        [ -n "$floor" ] || die_usage "the tasks-axi floor could not be projected from its owner"
        fm_tool_profile_ver_ge "$pin" "$floor" \
          || die_usage "FM_TASKS_AXI_PIN $pin is below FM_TASKS_AXI_MIN $floor; raise the pin in bin/fm-tasks-axi-lib.sh"
      fi
      printf '%s\n' "$pin"
      exit 0
      ;;
    --floor)
      [ "$#" -ge 2 ] || die_usage "--floor requires a tool"
      floor=$(floor_of "$2") || die_usage "no floor is owned for $2"
      [ -n "$floor" ] || die_usage "the floor for $2 could not be projected from its owner"
      printf '%s\n' "$floor"
      exit 0
      ;;
    --expect-nm-home)
      [ "$#" -ge 2 ] || die_usage "--expect-nm-home requires a path"
      EXPECT_NM_HOME=$2; EXPECT_NM_HOME_SET=1; shift 2 ;;
    --expect-nm-home=*) EXPECT_NM_HOME=${1#*=}; EXPECT_NM_HOME_SET=1; shift ;;
    --expect-path0)
      [ "$#" -ge 2 ] || die_usage "--expect-path0 requires a directory"
      EXPECT_PATH0=$2; shift 2 ;;
    --expect-path0=*) EXPECT_PATH0=${1#*=}; shift ;;
    --require)
      [ "$#" -ge 2 ] || die_usage "--require requires a tool list"
      REQUIRE=$(printf '%s' "$2" | tr ',' ' '); shift 2 ;;
    --require=*) REQUIRE=$(printf '%s' "${1#*=}" | tr ',' ' '); shift ;;
    --strict-pin) STRICT_PIN=1; shift ;;
    --json) JSON=1; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
for t in $REQUIRE; do
  case " $KNOWN_TOOLS " in
    *" $t "*) ;;
    *) die_usage "unknown tool in --require: $t (known: $KNOWN_TOOLS)" ;;
  esac
done
if [ "$JSON" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
  die_usage "--json requires jq"
fi

PIN_SHELLCHECK=$(pin_of shellcheck) || PIN_SHELLCHECK=
PIN_ACTIONLINT=$(pin_of actionlint) || PIN_ACTIONLINT=
PIN_TASKS_AXI=$(pin_of tasks-axi) || PIN_TASKS_AXI=
FLOOR_TASKS_AXI=$(floor_of tasks-axi) || FLOOR_TASKS_AXI=
FLOOR_NO_MISTAKES=$(floor_of no-mistakes) || FLOOR_NO_MISTAKES=
for v in PIN_SHELLCHECK PIN_ACTIONLINT PIN_TASKS_AXI FLOOR_TASKS_AXI FLOOR_NO_MISTAKES; do
  [ -n "${!v}" ] || die_usage "$v could not be projected from its owner"
done
fm_tool_profile_ver_ge "$PIN_TASKS_AXI" "$FLOOR_TASKS_AXI" \
  || die_usage "FM_TASKS_AXI_PIN $PIN_TASKS_AXI is below FM_TASKS_AXI_MIN $FLOOR_TASKS_AXI; raise the pin in bin/fm-tasks-axi-lib.sh"

# Per-tool observation. Each sets STATE VERSION PATHV DETAIL BOUND for one tool.
observe_pinned() {  # <tool> <pin> <version-flag>
  local tool=$1 pin=$2 flag=$3 output
  BOUND="pin=$pin"
  if ! PATHV=$(command -v "$tool" 2>/dev/null); then
    STATE=ABSENT; VERSION=; PATHV=; DETAIL="no $tool on PATH"; return
  fi
  output=$("$PATHV" "$flag" 2>/dev/null </dev/null || true)
  case "$tool" in
    shellcheck) VERSION=$(fm_tool_profile_shellcheck_version_of "$output") ;;
    actionlint) VERSION=$(fm_tool_profile_actionlint_version_of "$output") ;;
    *) VERSION=$(fm_tool_profile_semver_of "$output") ;;
  esac
  if [ -z "$VERSION" ]; then
    STATE=PINNED_MISMATCH; DETAIL="version unreadable, pinned $pin"
  elif [ "$VERSION" != "$pin" ]; then
    STATE=PINNED_MISMATCH; DETAIL="found $VERSION, pinned $pin"
  else
    STATE=QUALIFIED; DETAIL="exact pin"
  fi
}

observe_tasks_axi() {
  BOUND="floor=$FLOOR_TASKS_AXI pin=$PIN_TASKS_AXI"
  if ! PATHV=$(command -v tasks-axi 2>/dev/null); then
    STATE=ABSENT; VERSION=; PATHV=; DETAIL="no tasks-axi on PATH"; return
  fi
  VERSION=$(fm_tool_profile_semver_of "$(tasks-axi --version 2>/dev/null </dev/null || true)")
  # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
  if ( . "$ROOT/bin/fm-tasks-axi-lib.sh" >/dev/null 2>&1 && fm_tasks_axi_compatible ); then
    if [ "$STRICT_PIN" -eq 1 ] && [ "$VERSION" != "$PIN_TASKS_AXI" ]; then
      STATE=PINNED_MISMATCH; DETAIL="found ${VERSION:-unreadable}, pinned $PIN_TASKS_AXI"
    else
      STATE=QUALIFIED; DETAIL="floor and feature probe satisfied"
    fi
  else
    STATE=PRESENT_BELOW_FLOOR; DETAIL="found ${VERSION:-unreadable}, floor $FLOOR_TASKS_AXI or its feature probe not satisfied"
  fi
}

observe_no_mistakes() {
  local output build
  BOUND="floor=$FLOOR_NO_MISTAKES"
  if ! PATHV=$(command -v no-mistakes 2>/dev/null); then
    STATE=ABSENT; VERSION=; PATHV=; DETAIL="no no-mistakes on PATH"; return
  fi
  output=$(no-mistakes --version 2>/dev/null </dev/null || true)
  VERSION=$(fm_tool_profile_semver_of "$output")
  build=$(printf '%s\n' "$output" | sed -nE 's/.*\(([0-9a-f]{6,40})\).*/\1/p' | head -1)
  if [ -z "$VERSION" ]; then
    STATE=PRESENT_BELOW_FLOOR; DETAIL="version unreadable, floor $FLOOR_NO_MISTAKES"
  elif fm_tool_profile_ver_ge "$VERSION" "$FLOOR_NO_MISTAKES"; then
    STATE=QUALIFIED; DETAIL="build ${build:-unknown}"
  else
    STATE=PRESENT_BELOW_FLOOR; DETAIL="found $VERSION build ${build:-unknown}, floor $FLOOR_NO_MISTAKES"
  fi
}

observe_workflow_yaml() {
  local out backend
  BOUND="capability=workflow-yaml-to-json"
  if out=$("$ROOT/bin/fm-workflow-yaml.sh" --probe 2>/dev/null); then
    IFS=$'\t' read -r backend VERSION PATHV <<< "$out"
    STATE=QUALIFIED; DETAIL="backend=$backend; parser capability passed"
  else
    STATE=CAPABILITY_MISSING; VERSION=; PATHV=; DETAIL="no usable workflow YAML parser"
  fi
}

observe_node_ts() {
  local tmp out feature
  BOUND="capability=execute-ts"
  if ! PATHV=$(command -v node 2>/dev/null); then
    STATE=ABSENT; VERSION=; PATHV=; DETAIL="no node on PATH"; return
  fi
  VERSION=$(fm_tool_profile_semver_of "$(node --version 2>/dev/null </dev/null || true)")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-tool-profile.XXXXXX") || { STATE=CAPABILITY_MISSING; DETAIL="could not create a probe directory"; return; }
  printf 'const answer: number = 41;\nconsole.log("fm-tool-profile:ts-ok", answer + 1);\n' > "$tmp/probe.ts"
  out=$(cd "$tmp" && node ./probe.ts 2>/dev/null </dev/null || true)
  feature=$(node -p 'String(process.features.typescript)' 2>/dev/null </dev/null || printf 'unknown')
  rm -rf "$tmp"
  if [ "$out" = "fm-tool-profile:ts-ok 42" ]; then
    STATE=QUALIFIED; DETAIL="executes .ts (process.features.typescript=$feature)"
  else
    STATE=CAPABILITY_MISSING; DETAIL="cannot execute a .ts file (process.features.typescript=$feature)"
  fi
}

ROWS=
UNREADY=
rc=0
is_required() {
  case " $REQUIRE " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
record() {  # <tool>
  local tool=$1 owner required=no
  is_required "$tool" && required=yes
  ROWS="$ROWS$STATE"$'\t'"$tool"$'\t'"${VERSION:--}"$'\t'"$BOUND"$'\t'"${PATHV:--}"$'\t'"$required"$'\t'"$DETAIL"$'\n'
  if [ "$required" = yes ] && [ "$STATE" != QUALIFIED ]; then
    owner=$(owner_of "$tool")
    UNREADY="${UNREADY}ENVIRONMENT_UNREADY: $tool $STATE ($DETAIL); owner: $owner"$'\n'
    rc=1
  fi
}

observe_pinned shellcheck "$PIN_SHELLCHECK" --version; record shellcheck
observe_pinned actionlint "$PIN_ACTIONLINT" -version; record actionlint
observe_tasks_axi; record tasks-axi
observe_no_mistakes; record no-mistakes
observe_node_ts; record node-ts
observe_workflow_yaml; record workflow-yaml

# Profile facts observed from this invocation's own environment.
OBS_NM_HOME=${NM_HOME-}
OBS_NM_HOME_SET=0
[ -z "${NM_HOME+x}" ] || OBS_NM_HOME_SET=1
OBS_PATH0=${PATH%%:*}
OBS_PARENT=$(ps -o comm= -p "$PPID" 2>/dev/null | head -1 || true)
[ -n "$OBS_PARENT" ] || OBS_PARENT=unknown
PROFILE_STATE=OBSERVED
PROFILE_DETAIL=
if [ "$EXPECT_NM_HOME_SET" -eq 1 ]; then
  if [ "$OBS_NM_HOME_SET" -eq 0 ]; then
    PROFILE_STATE=PROFILE_MISMATCH; PROFILE_DETAIL="NM_HOME is unset, expected $EXPECT_NM_HOME"
  elif [ "$OBS_NM_HOME" != "$EXPECT_NM_HOME" ]; then
    PROFILE_STATE=PROFILE_MISMATCH; PROFILE_DETAIL="NM_HOME is $OBS_NM_HOME, expected $EXPECT_NM_HOME"
  fi
fi
if [ -n "$EXPECT_PATH0" ] && [ "${OBS_PATH0%/}" != "${EXPECT_PATH0%/}" ]; then
  PROFILE_STATE=PROFILE_MISMATCH
  PROFILE_DETAIL="${PROFILE_DETAIL:+$PROFILE_DETAIL; }PATH[0] is $OBS_PATH0, expected $EXPECT_PATH0"
fi
if [ "$PROFILE_STATE" = PROFILE_MISMATCH ]; then
  UNREADY="${UNREADY}ENVIRONMENT_UNREADY: profile PROFILE_MISMATCH ($PROFILE_DETAIL); owner: $(owner_of profile)"$'\n'
  rc=1
fi

if [ "$JSON" -eq 1 ]; then
  tools_json=$(printf '%s' "$ROWS" | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t")
      | {state: .[0], tool: .[1], version: (if .[2] == "-" then null else .[2] end),
         bound: .[3], path: (if .[4] == "-" then null else .[4] end),
         required: (.[5] == "yes"), detail: .[6]})')
  unready_json=$(printf '%s' "$UNREADY" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  jq -n -c \
    --arg nm_home "$OBS_NM_HOME" --argjson nm_home_set "$OBS_NM_HOME_SET" \
    --arg path0 "$OBS_PATH0" --arg parent "$OBS_PARENT" \
    --arg state "$PROFILE_STATE" --arg detail "$PROFILE_DETAIL" \
    --argjson tools "$tools_json" --argjson unready "$unready_json" --argjson rc "$rc" \
    '{record: "fm-tool-profile/v1",
      profile: {nm_home: (if $nm_home_set == 1 then $nm_home else null end), path0: $path0,
                parent: $parent, state: $state, detail: $detail},
      tools: $tools, unready: $unready, ready: ($rc == 0)}'
else
  printf 'fm-tool-profile: NM_HOME=%s PATH[0]=%s parent=%s profile=%s%s\n' \
    "$([ "$OBS_NM_HOME_SET" -eq 1 ] && printf '%s' "$OBS_NM_HOME" || printf '<unset>')" \
    "$OBS_PATH0" "$OBS_PARENT" "$PROFILE_STATE" "${PROFILE_DETAIL:+ ($PROFILE_DETAIL)}"
  printf '%s' "$ROWS" | while IFS=$'\t' read -r state tool version bound path required detail; do
    printf '%-19s %-12s %-10s %-28s required=%-3s %s  %s\n' "$state" "$tool" "$version" "$bound" "$required" "$path" "$detail"
  done
fi
[ -z "$UNREADY" ] || printf '%s' "$UNREADY" >&2
exit "$rc"
