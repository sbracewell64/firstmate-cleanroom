#!/usr/bin/env bash
# fm-render-launcher.sh - stage and qualify the captain launcher/console from its
# canonical source (bin/enter-firstmate.sh), WITHOUT performing any cutover.
#
# The tracked bin/enter-firstmate.sh is the host-agnostic SOURCE. The host-local
# $FM_HOME/enter-firstmate.sh is an INSTALL/ACTIVATION CONSUMER: a thin shim that
# sets FM_HOME and execs the adopted release's source, which resolves every other
# host path from $FM_HOME/config (code-root, tools-root, ...). This script:
#   1. captures a pre-cutover ROLLBACK snapshot of the current host launcher, its
#      config, and any Windows .lnk bytes named with --lnk (never edited/launched);
#   2. writes the staging config scalars and the consumer shim under a staging
#      directory (never the live path);
#   3. QUALIFIES the staged artifacts (syntax, shellcheck, the launcher tests) and
#      writes a qualification report enumerating the live cutover matrix.
# It performs NO cutover and starts NO primary: moving staging into the live home,
# and repointing the Windows shortcut's --cd at the adopted release, are separate
# captain-authorized steps this script only describes.
#
# SAFETY: the adopted --code-root must DIFFER from the current live (donor) code
# root; adoption that leaves the donor code root in place is refused, because the
# Windows shortcut's --cd points at the donor and the adopted release must win.
#
# Usage:
#   fm-render-launcher.sh --code-root <adopted-release> [options]
# Options:
#   --fm-home <path>          runtime home (default: $FM_HOME, else the live clean-room home)
#   --code-root <path>        REQUIRED. Adopted clean-room release (config/code-root + shim exec target)
#   --tools-root <path>       config/tools-root                 (recorded if given)
#   --control-resolver <path> config/control-resolver           (recorded if given)
#   --retired-home <path>     config/retired-home               (recorded if given)
#   --exchange-owner <path>   config/exchange-owner             (recorded if given)
#   --console-profile <name>  config/console-profile            (default: fable-5.1)
#   --staging <dir>           output dir (default: <fm-home>/state/launcher-staging)
#   --lnk <file>              a Windows .lnk to snapshot for rollback (repeatable; bytes only)
#   --require-complete-config refuse activation staging with missing isolation inputs
#   --allow-same-code-root    bypass the donor-guard (evidence/testing only)
set -euo pipefail

die() { printf 'fm-render-launcher: %s\n' "$*" >&2; exit 1; }
note() { printf 'fm-render-launcher: %s\n' "$*" >&2; }

SELF=$(readlink -f "${BASH_SOURCE[0]}")
REPO_ROOT=$(cd "$(dirname "$SELF")/.." && pwd)
SOURCE_LAUNCHER="$REPO_ROOT/bin/enter-firstmate.sh"

FM_HOME_ARG=${FM_HOME:-}
CODE_ROOT=''
TOOLS_ROOT=''
CONTROL_RESOLVER=''
RETIRED_HOME=''
EXCHANGE_OWNER=''
CONSOLE_PROFILE=fable-5.1
STAGING=''
ALLOW_SAME=0
REQUIRE_COMPLETE=0
LNKS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --fm-home) FM_HOME_ARG=${2:?--fm-home needs a path}; shift 2 ;;
    --code-root) CODE_ROOT=${2:?--code-root needs a path}; shift 2 ;;
    --tools-root) TOOLS_ROOT=${2:?}; shift 2 ;;
    --control-resolver) CONTROL_RESOLVER=${2:?}; shift 2 ;;
    --retired-home) RETIRED_HOME=${2:?}; shift 2 ;;
    --exchange-owner) EXCHANGE_OWNER=${2:?}; shift 2 ;;
    --console-profile) CONSOLE_PROFILE=${2:?}; shift 2 ;;
    --staging) STAGING=${2:?}; shift 2 ;;
    --lnk) LNKS+=("${2:?--lnk needs a file}"); shift 2 ;;
    --require-complete-config) REQUIRE_COMPLETE=1; shift ;;
    --allow-same-code-root) ALLOW_SAME=1; shift ;;
    -h|--help) sed -n '1,40p' "$SELF"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -f "$SOURCE_LAUNCHER" ] || die "canonical source not found: $SOURCE_LAUNCHER"
[ -n "$FM_HOME_ARG" ] || FM_HOME_ARG=/home/shane/.firstmate-cleanroom
[ -n "$CODE_ROOT" ] || die "--code-root is required (the adopted clean-room release; never the donor --cd cwd)"
[ -d "$CODE_ROOT/bin" ] || note "warning: --code-root '$CODE_ROOT' has no bin/ yet (staging anyway; it must exist before cutover)"
[ -n "$STAGING" ] || STAGING="$FM_HOME_ARG/state/launcher-staging"

LIVE_LAUNCHER="$FM_HOME_ARG/enter-firstmate.sh"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ROLLBACK="$STAGING/rollback/$STAMP"
STAGE_CONFIG="$STAGING/config"
STAGE_CONSUMER="$STAGING/enter-firstmate.sh"
REPORT="$STAGING/qualification-report.md"

# --- donor guard: the adopted code root must differ from the current live one ---
# Resolve the CURRENT LIVE (donor) code root robustly, since the live launcher is
# not always the pre-migration donor: prefer the authoritative $FM_HOME/config/
# code-root scalar (read the whole-file-strip way the source does), else a literal
# FM_CODE_ROOT=<path> line in the live launcher but ONLY when it is a real resolved
# absolute path (the versioned source has FM_CODE_ROOT=$(resolve_host_path ...) and
# the rendered shim has no FM_CODE_ROOT= line, neither of which is a real root).
is_real_code_root() {  # <value> -> 0 when a real resolved absolute path
  # shellcheck disable=SC2016 # the literal $( match rejects a command substitution
  case "$1" in
    *'$('*) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}
DONOR_CODE_ROOT=''
DONOR_SOURCE=''
if [ -f "$FM_HOME_ARG/config/code-root" ]; then
  _cfg_root=$(tr -d '[:space:]' < "$FM_HOME_ARG/config/code-root")
  if is_real_code_root "$_cfg_root"; then
    DONOR_CODE_ROOT="$_cfg_root"; DONOR_SOURCE="$FM_HOME_ARG/config/code-root"
  fi
fi
if [ -z "$DONOR_CODE_ROOT" ] && [ -f "$LIVE_LAUNCHER" ]; then
  _lit_root=$(sed -nE 's/^FM_CODE_ROOT=(.+)$/\1/p' "$LIVE_LAUNCHER" | head -1)
  if is_real_code_root "$_lit_root"; then
    DONOR_CODE_ROOT="$_lit_root"; DONOR_SOURCE="$LIVE_LAUNCHER (literal FM_CODE_ROOT=)"
  fi
fi
if [ -n "$DONOR_CODE_ROOT" ]; then
  if [ "$CODE_ROOT" = "$DONOR_CODE_ROOT" ]; then
    if [ "$ALLOW_SAME" = 1 ]; then
      note "WARNING: adopted --code-root equals the current live (donor) code root ($CODE_ROOT, from $DONOR_SOURCE); proceeding only because --allow-same-code-root was given"
    else
      die "adopted --code-root equals the current live (donor) code root ($CODE_ROOT, from $DONOR_SOURCE); adoption must move the code root to the adopted release. Refusing (pass --allow-same-code-root only for evidence/testing)."
    fi
  fi
elif [ "$ALLOW_SAME" = 1 ]; then
  note "WARNING: could not resolve a real current live (donor) code root from $FM_HOME_ARG/config/code-root or $LIVE_LAUNCHER; proceeding only because --allow-same-code-root was given"
else
  die "could not resolve a real current live (donor) code root from $FM_HOME_ARG/config/code-root or $LIVE_LAUNCHER, so adoption cannot be proven to move the code root off the donor. Refusing (pass --allow-same-code-root only for a genuine fresh install with nothing to move off of)."
fi

python3 - "$STAGING" "$FM_HOME_ARG" <<'CHECK_PATHS'
import os, sys
from pathlib import Path
stage, home = (Path(os.path.abspath(p)) for p in sys.argv[1:])
for path in (stage, *stage.parents):
    if path.is_symlink():
        sys.exit('fm-render-launcher: linked staging destination refused')
live = home.resolve()
config = (home/'config').resolve()
if stage == live or stage in live.parents or stage == config or config in stage.parents or stage in config.parents:
    sys.exit('fm-render-launcher: staging overlaps live configuration')
if stage.exists():
    for root, dirs, files in os.walk(stage):
        if any((Path(root)/name).is_symlink() for name in dirs + files):
            sys.exit('fm-render-launcher: linked staging destination refused')
CHECK_PATHS
mkdir -p "$STAGING/rollback"
ROLLBACK=$(mktemp -d "$STAGING/rollback/$STAMP.XXXXXX")
rm -f "$REPORT"
fresh_config=$(mktemp -d "$STAGING/.config.XXXXXX")
trap 'rm -rf "$fresh_config"' EXIT

# --- 1. rollback snapshot (pre-cutover; bytes preserved, nothing edited) --------
snap_manifest="$ROLLBACK/MANIFEST.txt"
: > "$snap_manifest"
record() { printf '%s  %s\n' "$1" "$2" >> "$snap_manifest"; }
if [ -f "$LIVE_LAUNCHER" ]; then
  cp -p "$LIVE_LAUNCHER" "$ROLLBACK/enter-firstmate.sh.live"
  record "$(sha256sum "$LIVE_LAUNCHER" | cut -d' ' -f1)" "enter-firstmate.sh.live (from $LIVE_LAUNCHER)"
else
  note "no current live launcher at $LIVE_LAUNCHER; rollback snapshot omits it"
fi
if [ -d "$FM_HOME_ARG/config" ]; then
  mkdir -p "$ROLLBACK/config"
  # copy scalar config only (files, not the whole tree), preserving bytes
  find "$FM_HOME_ARG/config" -maxdepth 1 -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
    cp -p "$f" "$ROLLBACK/config/"
    record "$(sha256sum "$f" | cut -d' ' -f1)" "config/$(basename "$f")"
  done
fi
for lnk in "${LNKS[@]:-}"; do
  [ -n "$lnk" ] || continue
  if [ -f "$lnk" ]; then
    mkdir -p "$ROLLBACK/lnk"
    cp -p "$lnk" "$ROLLBACK/lnk/"
    record "$(sha256sum "$lnk" | cut -d' ' -f1)" "lnk/$(basename "$lnk") (bytes only; never edited or launched)"
  else
    note "warning: --lnk '$lnk' not found; recording it as capture-pending"
    record "MISSING" "lnk/$(basename "$lnk") (capture pending; provide a reachable path)"
  fi
done

# --- 2. staged config scalars + the consumer shim (never the live path) ---------
# Carry the home's existing configuration into the staged home. Explicit
# renderer selections below replace their corresponding scalar values.
if [ -d "$FM_HOME_ARG/config" ]; then
  cp -RLp "$FM_HOME_ARG/config/." "$fresh_config/"
fi
printf '%s\n' "$CODE_ROOT" > "$fresh_config/code-root"
[ -z "$TOOLS_ROOT" ]        || printf '%s\n' "$TOOLS_ROOT"        > "$fresh_config/tools-root"
[ -z "$CONTROL_RESOLVER" ]  || printf '%s\n' "$CONTROL_RESOLVER"  > "$fresh_config/control-resolver"
[ -z "$RETIRED_HOME" ]      || printf '%s\n' "$RETIRED_HOME"      > "$fresh_config/retired-home"
[ -z "$EXCHANGE_OWNER" ]    || printf '%s\n' "$EXCHANGE_OWNER"    > "$fresh_config/exchange-owner"
printf '%s\n' "$CONSOLE_PROFILE" > "$fresh_config/console-profile"

rm -rf "$STAGE_CONFIG"
mv "$fresh_config" "$STAGE_CONFIG"

if [ "$REQUIRE_COMPLETE" = 1 ]; then
  for key in code-root tools-root backend herdr-session; do
    [ -s "$STAGE_CONFIG/$key" ] || die "incomplete staged configuration: $key is required"
  done
  [ "$(cat "$STAGE_CONFIG/backend")" = herdr ] || die "incomplete staged configuration: backend must be herdr"
  session=$(cat "$STAGE_CONFIG/herdr-session")
  case "$session" in default|''|*[!A-Za-z0-9._-]*) die "incomplete staged configuration: a named non-default Herdr session is required" ;; esac
  [ -d "$(cat "$STAGE_CONFIG/tools-root")/bin" ] || die "incomplete staged configuration: tools surface is missing"
  [ -x "$CODE_ROOT/bin/enter-firstmate.sh" ] || die "incomplete staged configuration: adopted launcher is missing"
fi

cat > "$STAGE_CONSUMER" <<SHIM
#!/usr/bin/env bash
# GENERATED activation consumer for the clean-room captain launcher/console.
# DO NOT EDIT: render it from the source with bin/fm-render-launcher.sh.
# Source of truth: $CODE_ROOT/bin/enter-firstmate.sh
# Rendered: $STAMP
# This shim sets the operational home and execs the adopted release's launcher,
# which resolves every host path from \$FM_HOME/config. The named Herdr session
# is still read from \$FM_HOME/config/herdr-session by that source (unchanged).
export FM_HOME="$FM_HOME_ARG"
exec "$CODE_ROOT/bin/enter-firstmate.sh" "\$@"
SHIM
chmod 0755 "$STAGE_CONSUMER"

# --- 3. qualification ------------------------------------------------------------
q_pass=(); q_fail=()
qual() {  # <label> <cmd...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then q_pass+=("$label"); else q_fail+=("$label"); fi
}
qual "source: bash -n"                 bash -n "$SOURCE_LAUNCHER"
qual "consumer shim: bash -n"          bash -n "$STAGE_CONSUMER"
if command -v shellcheck >/dev/null 2>&1; then
  qual "source: shellcheck"            shellcheck "$SOURCE_LAUNCHER"
  qual "consumer shim: shellcheck"     shellcheck "$STAGE_CONSUMER"
fi
for t in arm launch profile; do
  qual "test: enter-firstmate-$t"      bash "$REPO_ROOT/tests/enter-firstmate-$t.test.sh"
done
# The staged source must resolve the staged config and compose the profile menu.
# --print-console-menu renders ONLY the menu and exits 0 before every mandatory
# environment gate, so it needs no usable tools root and touches no live home: run
# it against a scratch home holding the staged config and assert the heading plus
# all four profiles appear, proving the composed menu renders offline.
scratch=$(mktemp -d)
cp -a "$STAGE_CONFIG/." "$scratch/config/" 2>/dev/null || { mkdir -p "$scratch/config"; cp -a "$STAGE_CONFIG/." "$scratch/config/"; }
menu_out=$(FM_HOME="$scratch" FM_TOOLS_ROOT="${TOOLS_ROOT:-/nonexistent}" bash "$SOURCE_LAUNCHER" --print-console-menu 2>&1) && menu_rc=0 || menu_rc=$?
menu_ok=0
if [ "$menu_rc" = 0 ] && printf '%s' "$menu_out" | grep -q 'primary console profile menu'; then
  menu_ok=1
  for _prof in fable-5.1 opus-4-8 codex-astra codex-sol; do
    printf '%s' "$menu_out" | grep -q "$_prof" || menu_ok=0
  done
fi
if [ "$menu_ok" = 1 ]; then
  q_pass+=("print-console-menu: renders the four-profile menu")
else
  q_fail+=("print-console-menu: renders the four-profile menu")
fi
rm -rf "$scratch"

# --- 4. report -------------------------------------------------------------------
{
  echo "# Captain launcher staging + qualification"
  echo
  echo "- Rendered (UTC): $STAMP"
  echo "- Canonical source: bin/enter-firstmate.sh (@ $REPO_ROOT)"
  echo "- Runtime home: $FM_HOME_ARG"
  echo "- Adopted code root (config/code-root): $CODE_ROOT"
  echo "- Current live (donor) code root: ${DONOR_CODE_ROOT:-<none read>}"
  echo "- Console profile (config/console-profile): $CONSOLE_PROFILE"
  echo "- Staging dir: $STAGING"
  echo "- Rollback snapshot: $ROLLBACK (see MANIFEST.txt)"
  echo
  echo "## Automated qualification (this run)"
  for p in "${q_pass[@]:-}"; do [ -n "$p" ] && echo "- PASS $p"; done
  for f in "${q_fail[@]:-}"; do [ -n "$f" ] && echo "- FAIL $f"; done
  echo
  echo "Staging completeness required: $REQUIRE_COMPLETE (menu checks alone do not qualify activation)."
  echo
  echo "## Live cutover matrix (captain-run; NOT performed here)"
  echo "Each item is verified live at cutover, not by this staging run:"
  echo "- Windows .lnk -> wsl.exe -> Ubuntu -> cwd -> launcher (repoint --cd off the donor to the adopted release)"
  echo "- firstmate-cleanroom Herdr session/socket continuity"
  echo "- Claude primary composition (fable-5.1 default)"
  echo "- Codex primary composition (codex-astra / codex-sol)"
  echo "- Selected profile native auth / provider / model / permission AFTER composition"
  echo "- Zero-dollar / subscription boundary (no API/gateway fallback, no overage, no budget flag)"
  echo "- Attach/resume vs fresh-relaunch"
  echo "- Post-launch cwd / SHA / instruction+skill+hook / inbox / lease evidence"
  echo
  echo "## Cutover (separate, captain-authorized; this script does none of it)"
  echo "1. Ensure the adopted release exists at: $CODE_ROOT"
  echo "2. Copy staged config into the live home, then force the code root so the adopted"
  echo "   release wins over the donor even on a re-adoption where config/code-root already exists"
  echo "   (cp -n alone preserves any captain-local scalar but SKIPS the pre-existing donor code root):"
  echo "     cp -n $STAGE_CONFIG/* $FM_HOME_ARG/config/"
  echo "     cp $STAGE_CONFIG/code-root $FM_HOME_ARG/config/code-root"
  echo "3. Replace the live launcher with the consumer shim: cp $STAGE_CONSUMER $LIVE_LAUNCHER"
  echo "4. Repoint the Windows shortcut(s) --cd from the donor to the adopted release."
  echo "5. Rollback if needed: restore files from $ROLLBACK (bytes preserved)."
} > "$REPORT"

note "staged under $STAGING"
note "rollback snapshot: $ROLLBACK"
note "qualification report: $REPORT"
nfail=${#q_fail[@]}
if [ "$nfail" -gt 0 ]; then
  note "QUALIFICATION FAILURES: ${q_fail[*]}"
  exit 1
fi
note "qualification: all automated checks passed (live cutover matrix remains captain-run)"
