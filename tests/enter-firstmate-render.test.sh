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
# Every staging that passes the donor guard runs the tool's full qualification,
# which includes the whole launcher test family (enter-firstmate-{arm,launch,
# profile,pi-route}.test.sh, about two CI minutes) from the repo the tool lives in. That
# family is already a separate script of the same CI lane, so re-running it on
# every staging here measured ~14 minutes of pure repetition and timed the lane
# out. Exactly ONE staging below ((vi)) keeps the real repo and asserts those
# tests were run and passed; every other staging drives a byte-identical copy of
# the tool from a scratch repo holding the real launcher and stub launcher tests,
# the same repo-root seam case (viii) already uses, so each assertion is kept at
# a few seconds per staging.
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

# a scratch repo holding a byte-identical copy of the render tool, stub launcher
# tests that exit 0, and a launcher of the requested kind: `real` copies the real
# source (its menu and shellcheck qualification then run for real), while
# `menu:complete` / `menu:incomplete` write a stub whose --print-console-menu
# renders all six profiles or omits one. Echoes the copied tool's path; the tool
# resolves its repo root from its own location, so this is the seam that keeps a
# staging from re-running the whole real launcher family.
mk_repo() {  # <dir> <real|menu:complete|menu:incomplete>
  local d=$1 kind=$2 t
  mkdir -p "$d/bin" "$d/tests"
  cp "$RENDER" "$d/bin/fm-render-launcher.sh"
  for t in arm launch profile pi-route; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/enter-firstmate-$t.test.sh"
  done
  case "$kind" in
    real) cp "$LAUNCHER" "$d/bin/enter-firstmate.sh" ;;
    menu:complete|menu:incomplete)
      # shellcheck disable=SC2016 # these are literal shell lines written to a stub, not expansions
      {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'if [ "${1:-}" = --print-console-menu ]; then'
        printf '%s\n' '  echo "-- primary console profile menu (stub)"'
        printf '%s\n' '  echo "  fable-5.1"; echo "  opus-4-8"'
        printf '%s\n' '  echo "  codex-luna"; echo "  pi-sol"; echo "  pi-astra"'
        [ "$kind" = menu:complete ] && printf '%s\n' '  echo "  pi-luna-max"'
        printf '%s\n' '  exit 0'
        printf '%s\n' 'fi'
        printf '%s\n' 'exit 0'
      } > "$d/bin/enter-firstmate.sh"
      ;;
    *) fail "mk_repo: unknown kind $kind" ;;
  esac
  chmod 0755 "$d/bin/enter-firstmate.sh"
  printf '%s' "$d/bin/fm-render-launcher.sh"
}
FAST=$(mk_repo "$TMP/repo-fast" real)

# run a render tool; set globals OUT (combined output) and RC (exit code).
render_with() {  # <tool> <home> <code-root> [extra args...]
  local tool=$1 home=$2 code=$3; shift 3
  RC=0
  OUT=$(bash "$tool" --fm-home "$home" --code-root "$code" \
        --staging "$home/state/launcher-staging" "$@" 2>&1) || RC=$?
}
run_render() { render_with "$RENDER" "$@"; }   # the real tool from the real repo
run_fast_render() { render_with "$FAST" "$@"; } # the copied tool from the stub-test repo

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
run_fast_render "$home" "$ROOT_A" --allow-same-code-root
printf '%s' "$OUT" | grep -q 'proceeding only because --allow-same-code-root was given' || fail "(iv-b) bypass must warn-and-proceed, not refuse (got: $OUT)"
[ -f "$home/state/launcher-staging/config/code-root" ] || fail "(iv-b) bypass must proceed past the guard into staging"
pass "(iv-b) --allow-same-code-root bypasses the fail-safe for a genuine fresh install"

# (v) a genuine move to a DIFFERENT code root: config records ROOT_A, --code-root
#     adopts ROOT_B -> guard PASSES (no refusal) and staging proceeds past it.
home=$(mk_home genuine-move shim "$ROOT_A")
run_fast_render "$home" "$ROOT_B"
printf '%s' "$OUT" | grep -Eq "$REFUSE_RE" && fail "(v) a genuine different code root must not be refused (got: $OUT)"
[ -f "$home/state/launcher-staging/config/code-root" ] || fail "(v) a genuine move must proceed past the guard into staging"
[ "$(tr -d '[:space:]' < "$home/state/launcher-staging/config/code-root")" = "$ROOT_B" ] || fail "(v) staging must record the adopted (different) code root"
[ "$(tr -d '[:space:]' < "$home/state/launcher-staging/config/console-profile")" = fable-5.1 ] || fail "(v) default staging must retain the built-in fable-5.1 selection"
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
#      so config/console-profile alone selects the active profile. This is the
#      one staging that keeps the REAL repo, so it also proves the tool ran the
#      real launcher test family and recorded every member PASS.
home=$(mk_home altprofile shim "$ROOT_A")
run_render "$home" "$ADOPTED" --console-profile opus-4-8
[ "$RC" -eq 0 ] || fail "(vi) alternate-profile staging must succeed (rc=$RC, out: $OUT)"
stg="$home/state/launcher-staging"
[ "$(tr -d '[:space:]' < "$stg/config/console-profile")" = opus-4-8 ] || fail "(vi) staging must record the non-default console profile"
grep -q '^- PASS print-console-menu' "$stg/qualification-report.md" || fail "(vi) the menu qualification must PASS for a staged alternate profile"
for t in arm launch profile pi-route; do   # the ONE real-repo staging: the real launcher family ran and passed
  grep -q "^- PASS test: enter-firstmate-$t\$" "$stg/qualification-report.md" || fail "(vi) the real repo's enter-firstmate-$t test must be run and recorded PASS"
done
grep -q '^- FAIL ' "$stg/qualification-report.md" && fail "(vi) a clean real-repo staging must record no FAIL line"
menu=$(unset FM_CONSOLE_PROFILE FM_HARNESS FM_CODE_ROOT FM_TOOLS_ROOT FM_RETIRED_HOME
       FM_HOME="$stg" FM_TOOLS_ROOT=/nonexistent bash "$LAUNCHER" --print-console-menu 2>&1) || fail "(vi) offline staged menu must render"
case "$menu" in *'active profile:    opus-4-8'*) ;; *) fail "(vi) the staged alternate profile must render as active (got: $menu)" ;; esac
case "$menu" in *'opus-4-8'*'<- active'*) ;; *) fail "(vi) the active row must carry the active marker (got: $menu)" ;; esac
pass "(vi) a non-default --console-profile stages and renders that profile as active"

# The installed consumer executes the adopted code root's launcher, whose Pi
# checker lives beside that source. Exercise the rendered shim with an exact
# route grant; a missing checker would render "route check unavailable" instead.
home=$(mk_home pi-route-consumer shim "$ROOT_A")
printf '%s\n' 'pi-sol@pi@0.81.1@openai-codex/gpt-5.6-sol:xhigh@chatgpt-oauth@included-allowance-only' > "$home/config/console-qualified-profiles"
run_fast_render "$home" "$HERE/.."
[ "$RC" -eq 0 ] || fail "(vi-b) Pi consumer staging must succeed (rc=$RC, out: $OUT)"
stg="$home/state/launcher-staging"
mkdir -p "$TMP/pi-route-bin"
cat > "$TMP/pi-route-bin/pi" <<'PI'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '0.81.1\n'
PI
chmod 0755 "$TMP/pi-route-bin/pi"
route_menu=$(env -u FM_CONSOLE_PROFILE -u FM_HARNESS -u FM_ENTRY_LIB \
  OPENCODE_API_KEY=synthetic PATH="$TMP/pi-route-bin:$PATH" \
  bash "$stg/enter-firstmate.sh" --print-console-menu 2>&1) \
  || fail '(vi-b) staged Pi consumer menu must render'
case "$route_menu" in
  *'pi-sol'*'model=openai-codex/gpt-5.6-sol:xhigh'*'PENDING: API, provider or endpoint environment override is present: OPENCODE_API_KEY'*) ;;
  *) fail "(vi-b) staged consumer must reach the adopted code root's Pi checker (got: $route_menu)" ;;
esac
pass "(vi-b) the staged consumer reaches the exact Pi route checker in its adopted code root"

# The staged native config must apply the same typed-grant gate after copying
# the grant file, including a mixed record that previously re-enabled the route.
home=$(mk_home codex-route-consumer shim "$ROOT_A")
printf '%s\n' 'codex-luna@codex@0.81.1@openai/gpt-5.6-luna:max@chatgpt-oauth@included-allowance-only codex-luna' > "$home/config/console-qualified-profiles"
run_fast_render "$home" "$HERE/.." --console-profile codex-luna
[ "$RC" -eq 0 ] || fail "(vi-c) native consumer staging must succeed (rc=$RC, out: $OUT)"
stg="$home/state/launcher-staging"
mkdir -p "$TMP/codex-route-bin"
cat > "$TMP/codex-route-bin/codex" <<'CODEX'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf 'codex-cli 0.81.1\n'
CODEX
chmod 0755 "$TMP/codex-route-bin/codex"
native_menu=$(env -u FM_CONSOLE_PROFILE -u FM_HARNESS -u FM_ENTRY_LIB \
  FM_HOME="$stg" PATH="$TMP/codex-route-bin:$PATH" bash "$LAUNCHER" --print-console-menu 2>&1) \
  || fail '(vi-c) staged native config menu must render'
case "$native_menu" in
  *'codex-luna'*'model=gpt-5.6-luna'*'PENDING: exact native Codex grant '*) ;;
  *) fail "(vi-c) mixed staged native grant must refuse (got: $native_menu)" ;;
esac
printf '%s\n' 'codex-luna@codex@0.81.1@openai/gpt-5.6-luna:max@chatgpt-oauth@included-allowance-only' > "$stg/config/console-qualified-profiles"
native_menu=$(env -u FM_CONSOLE_PROFILE -u FM_HARNESS -u FM_ENTRY_LIB \
  FM_HOME="$stg" PATH="$TMP/codex-route-bin:$PATH" bash "$LAUNCHER" --print-console-menu 2>&1) \
  || fail '(vi-c) staged native config exact grant menu must render'
case "$native_menu" in
  *'codex-luna'*'model=gpt-5.6-luna'*'QUALIFIED'*) ;;
  *) fail "(vi-c) one exact staged native grant must qualify (got: $native_menu)" ;;
esac
pass "(vi-c) staged native config rejects mixed grants and qualifies one exact grant"

# (vii) inherited FM_* pollution neither corrupts the staged artifacts nor leaks
#       into the report: the staged code root and profile come from the flags,
#       never from the ambient FM_CODE_ROOT / FM_CONSOLE_PROFILE the live console
#       exports, and no polluted path appears in the qualification report.
home=$(mk_home pollution shim "$ROOT_A")
RC=0
OUT=$(FM_CODE_ROOT=/polluted/donor FM_CONSOLE_PROFILE=opus-4-8 FM_HARNESS=bash \
      FM_RETIRED_HOME=/polluted/retired FM_TOOLS_ROOT=/polluted/tools \
      bash "$FAST" --fm-home "$home" --code-root "$ADOPTED" \
      --console-profile fable-5.1 --staging "$home/state/launcher-staging" 2>&1) || RC=$?
[ "$RC" -eq 0 ] || fail "(vii) pollution must not break staging (rc=$RC, out: $OUT)"
stg="$home/state/launcher-staging"
[ "$(tr -d '[:space:]' < "$stg/config/code-root")" = "$ADOPTED" ] || fail "(vii) the staged code root must come from --code-root, not ambient FM_CODE_ROOT"
[ "$(tr -d '[:space:]' < "$stg/config/console-profile")" = fable-5.1 ] || fail "(vii) the staged profile must come from --console-profile, not ambient FM_CONSOLE_PROFILE"
grep -q '^- PASS print-console-menu' "$stg/qualification-report.md" || fail "(vii) the menu qualification must PASS despite ambient pollution"
grep -Eq '/polluted/(donor|retired|tools)' "$stg/qualification-report.md" && fail "(vii) no ambient polluted path may leak into the qualification report"
pass "(vii) inherited FM_* pollution neither corrupts the staged artifacts nor leaks into the report"

# (viii) a MISSING required menu capability is an explicit qualification GAP, not
#        a silent PASS. Drive a COPY of the real staging tool against a scratch
#        repo whose source launcher renders an INCOMPLETE menu (one profile
#        missing): the menu check must FAIL and the tool must exit nonzero, while
#        an otherwise-identical COMPLETE menu passes. Proves the caller surfaces a
#        missing capability rather than reporting a false clean.
run_scratch() {  # <render-tool> <home> ; sets RC and OUT (a genuine fresh install)
  local tool=$1 h=$2
  RC=0
  OUT=$(bash "$tool" --fm-home "$h" --code-root "$ADOPTED" --allow-same-code-root \
        --staging "$h/state/launcher-staging" 2>&1) || RC=$?
}
good=$(mk_repo "$TMP/repo-complete" menu:complete)
run_scratch "$good" "$TMP/repo-complete/home"
[ "$RC" -eq 0 ] || fail "(viii) a complete menu must qualify clean (rc=$RC, out: $OUT)"
grep -q '^- PASS print-console-menu' "$TMP/repo-complete/home/state/launcher-staging/qualification-report.md" || fail "(viii) a complete menu must record PASS"
bad=$(mk_repo "$TMP/repo-incomplete" menu:incomplete)
run_scratch "$bad" "$TMP/repo-incomplete/home"
[ "$RC" -ne 0 ] || fail "(viii) an incomplete menu must exit nonzero, never a silent PASS (rc=$RC)"
rpt="$TMP/repo-incomplete/home/state/launcher-staging/qualification-report.md"
grep -q '^- FAIL print-console-menu' "$rpt" || fail "(viii) the missing menu capability must be recorded as a FAIL gap"
grep -q '^- PASS source: bash -n' "$rpt" || fail "(viii) unrelated checks must still be reported (only the missing capability fails)"
case "$OUT" in *'all automated checks passed'*) fail "(viii) the tool must not claim all checks passed when a capability is missing" ;; esac
pass "(viii) a missing required menu capability is an explicit qualification GAP, never a silent PASS"

# --- rollback + cutover adoption (relaunch checkpoint, gate 2) ------------------
# The final cases qualify the EXIT + RELAUNCH + ROLLBACK contract the render tool
# underpins: a rollback snapshot that fully reverts an aborted cutover, and a
# documented cutover that adopts the new release rather than the donor it replaces.

# (ix) the rollback snapshot records the exact prior launcher + every config scalar
#      and a restore from it reproduces them byte-for-byte, so an aborted cutover
#      reverts completely (checkpoint gate 2: rollback restores the exact prior state).
home=$(mk_home rollback shim "$ROOT_A")
printf '/prior/tools\n' > "$home/config/tools-root"   # a second captain-local scalar to capture
pre_launcher=$(sha256sum "$home/enter-firstmate.sh" | cut -d' ' -f1)
pre_coderoot=$(sha256sum "$home/config/code-root" | cut -d' ' -f1)
pre_tools=$(sha256sum "$home/config/tools-root" | cut -d' ' -f1)
run_fast_render "$home" "$ROOT_B"
[ "$RC" -eq 0 ] || fail "(ix) a genuine move must stage and snapshot (rc=$RC, out: $OUT)"
stg="$home/state/launcher-staging"
rb=$(find "$stg/rollback" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$rb" ] || fail "(ix) the render must write a rollback snapshot dir"
grep -q "$pre_launcher" "$rb/MANIFEST.txt" || fail "(ix) snapshot manifest must record the prior launcher sha"
grep -q "$pre_coderoot" "$rb/MANIFEST.txt" || fail "(ix) snapshot manifest must record the prior code-root sha"
grep -q "$pre_tools" "$rb/MANIFEST.txt" || fail "(ix) snapshot manifest must record the prior tools-root sha"
# simulate an aborted cutover: overwrite the live launcher and mutate config, then restore.
cp "$stg/enter-firstmate.sh" "$home/enter-firstmate.sh"
printf 'MUTATED\n' > "$home/config/code-root"
printf 'MUTATED\n' >> "$home/config/tools-root"
cp -p "$rb/enter-firstmate.sh.live" "$home/enter-firstmate.sh"
cp -p "$rb/config/"* "$home/config/"
[ "$(sha256sum "$home/enter-firstmate.sh" | cut -d' ' -f1)" = "$pre_launcher" ] || fail "(ix) restore must reproduce the prior launcher bytes"
[ "$(sha256sum "$home/config/code-root" | cut -d' ' -f1)" = "$pre_coderoot" ] || fail "(ix) restore must reproduce the prior code-root bytes"
[ "$(sha256sum "$home/config/tools-root" | cut -d' ' -f1)" = "$pre_tools" ] || fail "(ix) restore must reproduce the prior tools-root bytes"
pass "(ix) the rollback snapshot restores the exact prior launcher and config bytes"

# (x) the documented cutover adopts the new release even on a re-adoption where a
#     donor config/code-root already exists: running the report's OWN emitted cutover
#     config commands against such a home must leave config/code-root at the ADOPTED
#     root, never the pre-existing donor. A plain `cp -n` alone (no-clobber) would
#     silently keep the donor and the adopted launcher would resolve FM_CODE_ROOT
#     back to it (checkpoint gate 2: a fresh relaunch adopts the new release).
home=$(mk_home cutover-adopt shim "$ROOT_A")   # config/code-root pre-exists = ROOT_A (donor)
run_fast_render "$home" "$ADOPTED"
[ "$RC" -eq 0 ] || fail "(x) a genuine move must stage (rc=$RC, out: $OUT)"
rpt="$home/state/launcher-staging/qualification-report.md"
live="$TMP/home-cutover-live"; mkdir -p "$live/config"
printf '%s\n' "$ROOT_A" > "$live/config/code-root"   # exactly the donor scalar present at cutover
while IFS= read -r line; do
  cmd=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')
  case "$cmd" in
    "cp "*config*)
      cmd=${cmd//$home\/config/$live\/config}       # redirect the destination to the fresh live home
      bash -c "$cmd" 2>/dev/null || fail "(x) emitted cutover command failed: $cmd"
      ;;
  esac
done < "$rpt"
got=$(tr -d '[:space:]' < "$live/config/code-root")
[ "$got" = "$ADOPTED" ] || fail "(x) the documented cutover must adopt the new code root, got '$got' (donor was $ROOT_A)"
pass "(x) the documented cutover adopts the new code root over a pre-existing donor"

echo "all donor-guard and caller-level qualification tests passed"

# Full staging preserves configured isolation inputs, even without repeated flags.
home=$(mk_home config-complete shim "$ROOT_A")
printf 'herdr\n' > "$home/config/backend"
printf 'firstmate-cleanroom\n' > "$home/config/herdr-session"
printf '%s\n' "$TMP/tools" > "$home/config/tools-root"
mkdir -p "$TMP/tools/bin"
run_fast_render "$home" "$ROOT_B"
for key in backend herdr-session tools-root; do
  cmp -s "$home/config/$key" "$home/state/launcher-staging/config/$key" || fail "staging lost configured $key"
done
pass "configured isolation scalars survive staging without repeated flags"

# Incomplete staging must not be mistaken for activation qualification.
home=$(mk_home missing-config shim "$ROOT_A")
run_render "$home" "$ROOT_B" --require-complete-config
[ "$RC" -ne 0 ] || fail "activation qualification must refuse missing isolation config"
case "$OUT" in *'incomplete staged configuration'*) ;; *) fail "missing configuration needs an exact activation gap: $OUT" ;; esac
pass "incomplete staged configuration refuses activation qualification"

# The generated consumer must reach the same terminal failure-display owner.
terminal_home=$(mk_home terminal-display shim "$ROOT_A")
terminal_release="$TMP/terminal-release"
mkdir -p "$terminal_release/bin"
cp "$LAUNCHER" "$terminal_release/bin/enter-firstmate.sh"
chmod +x "$terminal_release/bin/enter-firstmate.sh"
run_fast_render "$terminal_home" "$terminal_release"
[ "$RC" -eq 0 ] || fail "terminal consumer staging failed: $OUT"
python3 "$HERE/test_launcher_terminal.py" \
  "$terminal_home/state/launcher-staging/enter-firstmate.sh" 'tools root is unset' \
  || fail "generated consumer failure visibility/status"
pass "generated consumer preserves terminal diagnostics and failing status"

python3 "$HERE/test_renderer_snapshot.py" "$RENDER" || fail "independent renderer snapshots"
