#!/usr/bin/env bash
# Behavior tests for the four-profile primary console menu, the zero-dollar /
# subscription-only launch boundary, and the host-path resolution added to the
# versioned launcher source bin/enter-firstmate.sh (runtime-pin-adoption-gap,
# slice 1). Loads it with FM_ENTRY_LIB=1 (pure functions only, no home touched)
# and, for the refusal path, runs it in a subshell that dies before any Herdr,
# tool, or watcher action.
#
# Usage: bash tests/enter-firstmate-profile.test.sh
#        FM_ENTRY_LAUNCHER=/path/to/enter-firstmate.sh bash tests/enter-firstmate-profile.test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAUNCHER=${FM_ENTRY_LAUNCHER:-$HERE/../bin/enter-firstmate.sh}
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
[ -f "$LAUNCHER" ] || fail "launcher not found: $LAUNCHER"
# shellcheck disable=SC1090 # the launcher path is resolved at run time
FM_ENTRY_LIB=1 . "$LAUNCHER" || fail "FM_ENTRY_LIB=1 load failed"
for fn in console_profile_default console_profile_menu console_profile_harness console_profile_model \
          console_profile_model_ok console_profile_qualify console_profile_qualified_set \
          console_profile_gate console_argv_subscription_only console_harness_argv \
          read_scalar resolve_host_path; do
  command -v "$fn" >/dev/null || fail "$fn not defined by the library load"
done
pass "FM_ENTRY_LIB=1 defines the profile-menu, subscription, and resolution functions"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-entry-profile-test.XXXXXX") || fail mktemp
trap 'rm -rf "$TMP"' EXIT

# --- the four-profile menu ------------------------------------------------------
[ "$(console_profile_default)" = fable-5.1 ] || fail "the default profile is fable-5.1"
[ "$(console_profile_menu)" = 'fable-5.1 opus-4-8 codex-astra codex-sol' ] || fail "the menu is exactly the four profiles in order"
[ "$(console_profile_harness fable-5.1)" = claude ] || fail "fable-5.1 -> claude"
[ "$(console_profile_harness opus-4-8)" = claude ] || fail "opus-4-8 -> claude"
[ "$(console_profile_harness codex-astra)" = codex ] || fail "codex-astra -> codex"
[ "$(console_profile_harness codex-sol)" = codex ] || fail "codex-sol -> codex"
[ -z "$(console_profile_harness nope)" ] || fail "an unknown profile has no harness"
[ "$(console_profile_model fable-5.1)" = fable ] || fail "fable-5.1 selector is 'fable'"
[ "$(console_profile_model opus-4-8)" = claude-opus-4-8 ] || fail "opus-4-8 model is the pinned 4.8 id"
[ "$(console_profile_model codex-astra)" = gpt-6-astra ] || fail "codex-astra model is gpt-6-astra"
[ "$(console_profile_model codex-sol)" = gpt-5.6-sol ] || fail "codex-sol model is gpt-5.6-sol"
pass "menu: four profiles map to the exact harness + pinned model selector"

# --- Opus 4.8 only: Opus 5 is refused, never composed ---------------------------
console_profile_model_ok opus-4-8 claude-opus-4-8 || fail "the pinned 4.8 id is accepted"
console_profile_model_ok opus-4-8 claude-opus-5 && fail "opus-4-8 must refuse the Opus 5 id"
console_profile_model_ok opus-4-8 opus-5 && fail "opus-4-8 must refuse any Opus 5 spelling"
console_profile_model_ok fable-5.1 fable || fail "non-opus profiles are unconstrained by the opus guard"
# the model table itself can never emit an Opus 5 id for the opus profile
case "$(console_profile_model opus-4-8)" in *opus-5*) fail "the opus-4-8 model table must never resolve to Opus 5" ;; esac
pass "Opus 4.8 only: the Opus-5 id is refused and never in the model table"

# --- qualification core (pure): PENDING carries the exact gate, never a swap ----
[ "$(console_profile_qualify fable-5.1 1 1)" = QUALIFIED ] || fail "installed + allowed -> QUALIFIED"
case "$(console_profile_qualify codex-astra 1 0)" in "PENDING: model gpt-6-astra (codex) is not yet qualified"*) ;; *) fail "not-allowed -> PENDING naming the model and harness" ;; esac
case "$(console_profile_qualify codex-sol 0 1)" in "PENDING: harness codex is not installed"*) ;; *) fail "not-installed -> PENDING naming the harness" ;; esac
case "$(console_profile_qualify nope 1 1)" in "PENDING: nope is not a known profile"*) ;; *) fail "unknown profile -> PENDING, never QUALIFIED" ;; esac
# the not-installed gate is checked before the allowlist gate
case "$(console_profile_qualify codex-astra 0 0)" in "PENDING: harness codex is not installed"*) ;; *) fail "installed gate precedes the allowlist gate" ;; esac
pass "qualify: QUALIFIED only when installed AND allowed; every PENDING states its exact gate"

# --- the qualified set defaults to the default profile only ---------------------
( unset FM_HOME; FM_HOME=$TMP/home-empty; mkdir -p "$FM_HOME/config"
  [ "$(console_profile_qualified_set)" = fable-5.1 ] || exit 1 ) || fail "absent config qualifies only the default profile"
( FM_HOME=$TMP/home-two; mkdir -p "$FM_HOME/config"; printf 'fable-5.1 codex-sol\n' > "$FM_HOME/config/console-qualified-profiles"
  [ "$(console_profile_qualified_set)" = 'fable-5.1 codex-sol' ] || exit 1 ) || fail "config/console-qualified-profiles extends the qualified set"
pass "qualified set: default-only unless config/console-qualified-profiles widens it"

# --- console_profile_gate composes the two live facts ---------------------------
# claude is installed in CI images used for the launcher tests; guard on that.
if command -v claude >/dev/null 2>&1; then
  ( FM_HOME=$TMP/home-empty; [ "$(console_profile_gate fable-5.1)" = QUALIFIED ] || exit 1 ) || fail "default profile with an installed claude -> QUALIFIED"
  ( FM_HOME=$TMP/home-empty; case "$(console_profile_gate opus-4-8)" in PENDING:*) ;; *) exit 1 ;; esac ) || fail "opus-4-8 stays PENDING out of the box (not in the default qualified set)"
  pass "gate: default profile qualifies with claude installed; opus-4-8 stays PENDING"
else
  pass "skip: gate live-fact test (claude not installed here)"
fi

# --- $0 / subscription-only: no paid/gateway/budget selector may be composed ----
console_argv_subscription_only --dangerously-skip-permissions --model fable || fail "the qualified fable argv is clean"
console_argv_subscription_only --dangerously-bypass-approvals-and-sandbox --model gpt-6-astra || fail "the codex argv is clean"
for bad in --max-budget --budget --api-key --anthropic-api-key --openai-api-key --base-url --api-base --gateway --provider; do
  off=$(console_argv_subscription_only --model fable "$bad" x) && fail "a paid/gateway selector must be refused: $bad"
  [ "$off" = "$bad" ] || fail "the refusal must name the offending token (got '$off' for $bad)"
done
off=$(console_argv_subscription_only --max-budget=5 --model fable) && fail "an = form paid selector must be refused"
[ "$off" = '--max-budget=5' ] || fail "the = form is named verbatim (got '$off')"
pass "subscription-only: every paid/gateway/budget selector is refused and named; clean argvs pass"

# --- console_harness_argv model composition (the menu reaches the argv) ---------
a=$(console_harness_argv claude fable "" "" | tr '\n' ' ')
[ "$a" = '--dangerously-skip-permissions --model fable ' ] || fail "claude fable argv (got '$a')"
a=$(console_harness_argv claude claude-opus-4-8 /h/s.json 0123abcd-0123-4567-89ab-0123456789ab | tr '\n' ' ')
[ "$a" = '--dangerously-skip-permissions --model claude-opus-4-8 --settings /h/s.json --resume 0123abcd-0123-4567-89ab-0123456789ab ' ] || fail "claude opus argv with settings+resume (got '$a')"
a=$(console_harness_argv codex gpt-6-astra "" "" --sandbox | tr '\n' ' ')
[ "$a" = '--dangerously-bypass-approvals-and-sandbox --model gpt-6-astra --sandbox ' ] || fail "codex argv leads with its bypass posture + model (got '$a')"
# codex never gets claude-only settings/resume even if passed
a=$(console_harness_argv codex gpt-5.6-sol /h/s.json 0123abcd-0123-4567-89ab-0123456789ab | tr '\n' ' ')
[ "$a" = '--dangerously-bypass-approvals-and-sandbox --model gpt-5.6-sol ' ] || fail "codex ignores --settings/--resume (got '$a')"
[ "$(console_harness_argv claude fable "" "" | head -1)" = '--dangerously-skip-permissions' ] || fail "claude posture is still argv[1] under the menu"
[ "$(console_harness_argv codex gpt-6-astra "" "" | head -1)" = '--dangerously-bypass-approvals-and-sandbox' ] || fail "codex posture is argv[1]"
pass "console argv: the profile model reaches the composed argv; posture always leads"

# --- host-path resolution: env override, then config, else empty ----------------
[ "$(resolve_host_path /explicit/path code-root)" = /explicit/path ] || fail "an env value wins"
( FM_HOME=$TMP/home-cfg; mkdir -p "$FM_HOME/config"; printf '/from/config\n' > "$FM_HOME/config/code-root"
  [ "$(resolve_host_path '' code-root)" = /from/config ] || exit 1 ) || fail "with no env value the config scalar is read"
( FM_HOME=$TMP/home-empty; [ -z "$(resolve_host_path '' code-root)" ] || exit 1 ) || fail "absent env and config -> empty (the caller decides fatality)"
pass "host paths: env override, then \$FM_HOME/config scalar, else empty"

# --- a real run refuses when the required code root is unset --------------------
# Runs the launcher (not the lib) with an empty home so it dies at the code-root
# check, well before any Herdr/tool/watcher action.
# NOTE: sourcing the launcher above put this shell under its `set -e`, so guard
# the intentionally-failing run with `|| rc=$?` rather than a bare assignment.
rc=0
out=$(FM_HOME=$TMP/home-empty FM_CODE_ROOT='' FM_TOOLS_ROOT='' bash "$LAUNCHER" --doctor 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "an unset code root must refuse loudly, not launch"
case "$out" in *'code root is unset'*) ;; *) fail "the refusal must name the unset code root (got: $out)" ;; esac
pass "real run: an unset code root is refused loudly before any launch action"

echo "all four-profile menu, subscription-boundary, and host-path resolution tests passed"
