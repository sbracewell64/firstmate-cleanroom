#!/usr/bin/env bash
# Behavior tests for the donor-guard in bin/fm-render-launcher.sh: the staging
# tool must REFUSE adopting a --code-root that equals the current live (donor)
# code root, resolving that donor robustly from $FM_HOME/config/code-root or a
# REAL literal FM_CODE_ROOT= line, and must FAIL SAFE (refuse) when neither yields
# a real path. Drives the real tool against staged scratch homes and asserts the
# observable refusal / pass-through, never grepping the tool's own source.
#
# Usage: bash tests/enter-firstmate-render.test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RENDER=${FM_ENTRY_RENDER:-$HERE/../bin/fm-render-launcher.sh}
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
[ -f "$RENDER" ] || fail "render tool not found: $RENDER"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-entry-render-test.XXXXXX") || fail mktemp
trap 'rm -rf "$TMP"' EXIT

ROOT_A="$TMP/release-a"; mkdir -p "$ROOT_A/bin"
ROOT_B="$TMP/release-b"; mkdir -p "$ROOT_B/bin"

# a fresh runtime home with a launcher of the requested flavour and, optionally, a
# config/code-root scalar. Echoes the home path.
mk_home() {  # <name> <launcher-flavour: none|shim|source|donor:PATH> [config-root]
  local name=$1 flavour=$2 cfg=${3:-}
  local home="$TMP/home-$name"; mkdir -p "$home/config"
  case "$flavour" in
    none) : ;;  # no live launcher at all
    shim)   # a rendered consumer shim: NO FM_CODE_ROOT= line
      cat > "$home/enter-firstmate.sh" <<'SHIM'
#!/usr/bin/env bash
export FM_HOME="/home/shane/.firstmate-cleanroom"
exec "/some/release/bin/enter-firstmate.sh" "$@"
SHIM
      ;;
    source) # the versioned source: FM_CODE_ROOT is a command substitution, never a path
      cat > "$home/enter-firstmate.sh" <<'SRC'
#!/usr/bin/env bash
FM_CODE_ROOT=$(resolve_host_path "${FM_CODE_ROOT:-}" code-root)
SRC
      ;;
    donor:*) # a pre-migration donor: a REAL literal FM_CODE_ROOT=<abs path>
      printf '#!/usr/bin/env bash\nFM_CODE_ROOT=%s\n' "${flavour#donor:}" > "$home/enter-firstmate.sh"
      ;;
    *) fail "mk_home: unknown flavour $flavour" ;;
  esac
  [ -z "$cfg" ] || printf '%s\n' "$cfg" > "$home/config/code-root"
  printf '%s' "$home"
}

# run the render tool; set globals OUT (combined output) and RC (exit code).
run_render() {  # <home> <code-root> [extra args...]
  local home=$1 code=$2; shift 2
  RC=0
  OUT=$(bash "$RENDER" --fm-home "$home" --code-root "$code" \
        --staging "$home/state/launcher-staging" "$@" 2>&1) || RC=$?
}

REFUSE_RE='(equals the current live \(donor\) code root|could not resolve a real current live)'

# (i) rendered shim live launcher (no FM_CODE_ROOT= line) but config/code-root
#     records ROOT_A and --code-root re-adopts ROOT_A -> guard FIRES via config.
home=$(mk_home shim-readopt shim "$ROOT_A")
run_render "$home" "$ROOT_A"
[ "$RC" -ne 0 ] || fail "(i) shim+config re-adopt: guard must refuse (rc=$RC)"
printf '%s' "$OUT" | grep -Eq 'equals the current live \(donor\) code root' || fail "(i) refusal must name the equal donor root (got: $OUT)"
[ ! -f "$home/state/launcher-staging/config/code-root" ] || fail "(i) refusal must happen before staging writes config"
pass "(i) shim live launcher + config/code-root re-adoption fires the donor guard"

# (ii) versioned source live launcher (FM_CODE_ROOT=\$(...)) + config/code-root
#      records ROOT_A and --code-root re-adopts ROOT_A -> guard FIRES via config.
home=$(mk_home source-readopt source "$ROOT_A")
run_render "$home" "$ROOT_A"
[ "$RC" -ne 0 ] || fail "(ii) source+config re-adopt: guard must refuse (rc=$RC)"
printf '%s' "$OUT" | grep -Eq 'equals the current live \(donor\) code root' || fail "(ii) refusal must name the equal donor root (got: $OUT)"
pass "(ii) versioned-source live launcher + config/code-root re-adoption fires the donor guard"

# (iii) old donor live launcher with a REAL literal FM_CODE_ROOT=<path>, no config,
#       --code-root equals it -> guard FIRES via the literal line (first cutover).
home=$(mk_home donor-firstcut "donor:$ROOT_A")
run_render "$home" "$ROOT_A"
[ "$RC" -ne 0 ] || fail "(iii) first-cutover donor re-adopt: guard must refuse (rc=$RC)"
printf '%s' "$OUT" | grep -Eq 'equals the current live \(donor\) code root' || fail "(iii) refusal must name the equal donor root (got: $OUT)"
pass "(iii) first cutover: a real literal FM_CODE_ROOT= donor fires the donor guard"

# (iv) neither a real config root nor a real literal path (the versioned source's
#      \$(...) is not a path, no config) -> FAIL SAFE: refuse, never silently pass.
home=$(mk_home failsafe source)
run_render "$home" "$ROOT_A"
[ "$RC" -ne 0 ] || fail "(iv) no resolvable donor: guard must FAIL SAFE and refuse (rc=$RC)"
printf '%s' "$OUT" | grep -Eq 'could not resolve a real current live' || fail "(iv) fail-safe refusal must state it could not resolve a donor (got: $OUT)"
[ ! -f "$home/state/launcher-staging/config/code-root" ] || fail "(iv) fail-safe must refuse before staging writes config"
pass "(iv) no resolvable donor root fails safe (refuses, never silently proceeds)"

# (iv-b) the sanctioned bypass: --allow-same-code-root turns the fail-safe refusal
#        into a warning so a genuine fresh install (nothing to move off) proceeds.
home=$(mk_home failsafe-bypass source)
run_render "$home" "$ROOT_A" --allow-same-code-root
printf '%s' "$OUT" | grep -q 'proceeding only because --allow-same-code-root was given' || fail "(iv-b) bypass must warn-and-proceed, not refuse (got: $OUT)"
[ -f "$home/state/launcher-staging/config/code-root" ] || fail "(iv-b) bypass must proceed past the guard into staging"
pass "(iv-b) --allow-same-code-root bypasses the fail-safe for a genuine fresh install"

# (v) a genuine move to a DIFFERENT code root: config records ROOT_A, --code-root
#     adopts ROOT_B -> guard PASSES (no refusal) and staging proceeds past it.
home=$(mk_home genuine-move shim "$ROOT_A")
run_render "$home" "$ROOT_B"
printf '%s' "$OUT" | grep -Eq "$REFUSE_RE" && fail "(v) a genuine different code root must not be refused (got: $OUT)"
[ -f "$home/state/launcher-staging/config/code-root" ] || fail "(v) a genuine move must proceed past the guard into staging"
[ "$(tr -d '[:space:]' < "$home/state/launcher-staging/config/code-root")" = "$ROOT_B" ] || fail "(v) staging must record the adopted (different) code root"
pass "(v) a genuine move to a different code root passes the guard and stages"

echo "all donor-guard tests passed"
