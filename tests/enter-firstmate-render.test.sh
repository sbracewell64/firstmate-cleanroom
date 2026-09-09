#!/usr/bin/env bash
# Behavior tests for the donor-guard in bin/fm-render-launcher.sh: the staging
# tool must REFUSE adopting a --code-root that equals the current live (donor)
# code root, resolving that donor robustly from $FM_HOME/config/code-root or a
# REAL literal FM_CODE_ROOT= line, and must FAIL SAFE (refuse) when neither yields
# a real path. Drives the real tool against staged scratch homes and asserts the
# observable refusal / pass-through, never grepping the tool's own source.
#
# It also covers the staging tool AS THE ACTUAL CALLER of the launcher's
# --print-console-menu qualification (runtime-pin-adoption-gap, launcher-test
# checkpoint), building on the direct --print-console-menu coverage in
# enter-firstmate-profile.test.sh rather than duplicating it:
#   - a non-default --console-profile stages and renders that profile as active;
#   - inherited FM_* environment pollution neither corrupts the staged artifacts
#     nor leaks into the qualification report;
#   - a MISSING required menu capability is an explicit qualification GAP (a FAIL
#     that exits nonzero), never a silent PASS.
#
# Usage: bash tests/enter-firstmate-render.test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RENDER=${FM_ENTRY_RENDER:-$HERE/../bin/fm-render-launcher.sh}
LAUNCHER=${FM_ENTRY_LAUNCHER:-$HERE/../bin/enter-firstmate.sh}
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
[ -f "$RENDER" ] || fail "render tool not found: $RENDER"
[ -f "$LAUNCHER" ] || fail "launcher source not found: $LAUNCHER"

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

# --- caller-level --print-console-menu qualification ---------------------------
# The remaining cases drive the real staging tool as the ACTUAL CALLER of the
# launcher's --print-console-menu qualification step, complementing the direct
# menu coverage in enter-firstmate-profile.test.sh.

# an adopted release skeleton the guard accepts moving TO (differs from every
# donor built above).
ADOPTED="$TMP/adopted-release"; mkdir -p "$ADOPTED/bin"

# (vi) a NON-DEFAULT --console-profile stages that profile and its menu
#      qualification renders it as the active profile. Run the staged source's
#      menu OFFLINE against the staged config, with the FM_* overrides cleared,
#      so config/console-profile alone selects the active profile.
home=$(mk_home altprofile shim "$ROOT_A")
run_render "$home" "$ADOPTED" --console-profile codex-astra
[ "$RC" -eq 0 ] || fail "(vi) alternate-profile staging must succeed (rc=$RC, out: $OUT)"
stg="$home/state/launcher-staging"
[ "$(tr -d '[:space:]' < "$stg/config/console-profile")" = codex-astra ] || fail "(vi) staging must record the non-default console profile"
grep -q '^- PASS print-console-menu' "$stg/qualification-report.md" || fail "(vi) the menu qualification must PASS for a staged alternate profile"
menu=$(unset FM_CONSOLE_PROFILE FM_HARNESS FM_CODE_ROOT FM_TOOLS_ROOT FM_RETIRED_HOME
       FM_HOME="$stg" FM_TOOLS_ROOT=/nonexistent bash "$LAUNCHER" --print-console-menu 2>&1) || fail "(vi) offline staged menu must render"
case "$menu" in *'active profile:    codex-astra'*) ;; *) fail "(vi) the staged alternate profile must render as active (got: $menu)" ;; esac
case "$menu" in *'codex-astra'*'<- active'*) ;; *) fail "(vi) the active row must carry the active marker (got: $menu)" ;; esac
pass "(vi) a non-default --console-profile stages and renders that profile as active"

# (vii) inherited FM_* pollution neither corrupts the staged artifacts nor leaks
#       into the report: the staged code root and profile come from the flags,
#       never from the ambient FM_CODE_ROOT / FM_CONSOLE_PROFILE the live console
#       exports, and no polluted path appears in the qualification report.
home=$(mk_home pollution shim "$ROOT_A")
RC=0
OUT=$(FM_CODE_ROOT=/polluted/donor FM_CONSOLE_PROFILE=opus-4-8 FM_HARNESS=bash \
      FM_RETIRED_HOME=/polluted/retired FM_TOOLS_ROOT=/polluted/tools \
      bash "$RENDER" --fm-home "$home" --code-root "$ADOPTED" \
      --console-profile codex-sol --staging "$home/state/launcher-staging" 2>&1) || RC=$?
[ "$RC" -eq 0 ] || fail "(vii) pollution must not break staging (rc=$RC, out: $OUT)"
stg="$home/state/launcher-staging"
[ "$(tr -d '[:space:]' < "$stg/config/code-root")" = "$ADOPTED" ] || fail "(vii) the staged code root must come from --code-root, not ambient FM_CODE_ROOT"
[ "$(tr -d '[:space:]' < "$stg/config/console-profile")" = codex-sol ] || fail "(vii) the staged profile must come from --console-profile, not ambient FM_CONSOLE_PROFILE"
grep -q '^- PASS print-console-menu' "$stg/qualification-report.md" || fail "(vii) the menu qualification must PASS despite ambient pollution"
grep -Eq '/polluted/(donor|retired|tools)' "$stg/qualification-report.md" && fail "(vii) no ambient polluted path may leak into the qualification report"
pass "(vii) inherited FM_* pollution neither corrupts the staged artifacts nor leaks into the report"

# (viii) a MISSING required menu capability is an explicit qualification GAP, not
#        a silent PASS. Drive a COPY of the real staging tool against a scratch
#        repo whose source launcher renders an INCOMPLETE menu (one profile
#        missing): the menu check must FAIL and the tool must exit nonzero, while
#        an otherwise-identical COMPLETE menu passes. Proves the caller surfaces a
#        missing capability rather than reporting a false clean.
mk_scratch_repo() {  # <dir> <complete|incomplete> ; echoes the render-tool path
  local d=$1 kind=$2 t
  mkdir -p "$d/bin" "$d/tests"
  cp "$RENDER" "$d/bin/fm-render-launcher.sh"
  for t in arm launch profile; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/enter-firstmate-$t.test.sh"
  done
  # shellcheck disable=SC2016 # these are literal shell lines written to a stub, not expansions
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'if [ "${1:-}" = --print-console-menu ]; then'
    printf '%s\n' '  echo "-- primary console profile menu (stub)"'
    printf '%s\n' '  echo "  fable-5.1"; echo "  opus-4-8"; echo "  codex-astra"'
    [ "$kind" = complete ] && printf '%s\n' '  echo "  codex-sol"'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
  } > "$d/bin/enter-firstmate.sh"
  chmod 0755 "$d/bin/enter-firstmate.sh"
  printf '%s' "$d/bin/fm-render-launcher.sh"
}
run_scratch() {  # <render-tool> <home> ; sets RC and OUT (a genuine fresh install)
  local tool=$1 h=$2
  RC=0
  OUT=$(bash "$tool" --fm-home "$h" --code-root "$ADOPTED" --allow-same-code-root \
        --staging "$h/state/launcher-staging" 2>&1) || RC=$?
}
good=$(mk_scratch_repo "$TMP/repo-complete" complete)
run_scratch "$good" "$TMP/repo-complete/home"
[ "$RC" -eq 0 ] || fail "(viii) a complete menu must qualify clean (rc=$RC, out: $OUT)"
grep -q '^- PASS print-console-menu' "$TMP/repo-complete/home/state/launcher-staging/qualification-report.md" || fail "(viii) a complete menu must record PASS"
bad=$(mk_scratch_repo "$TMP/repo-incomplete" incomplete)
run_scratch "$bad" "$TMP/repo-incomplete/home"
[ "$RC" -ne 0 ] || fail "(viii) an incomplete menu must exit nonzero, never a silent PASS (rc=$RC)"
rpt="$TMP/repo-incomplete/home/state/launcher-staging/qualification-report.md"
grep -q '^- FAIL print-console-menu' "$rpt" || fail "(viii) the missing menu capability must be recorded as a FAIL gap"
grep -q '^- PASS source: bash -n' "$rpt" || fail "(viii) unrelated checks must still be reported (only the missing capability fails)"
case "$OUT" in *'all automated checks passed'*) fail "(viii) the tool must not claim all checks passed when a capability is missing" ;; esac
pass "(viii) a missing required menu capability is an explicit qualification GAP, never a silent PASS"

echo "all donor-guard and caller-level qualification tests passed"
