#!/usr/bin/env bash
# Behavior tests for the six-profile primary console menu, the zero-dollar /
# subscription-only launch boundary, and the host-path resolution added to the
# versioned launcher source bin/enter-firstmate.sh (runtime-pin-adoption-gap,
# slice 1). Loads it with FM_ENTRY_LIB=1 (pure functions only, no home touched)
# and, for the refusal path, runs it in a subshell that dies before any Herdr,
# tool, or watcher action.
#
# Usage: bash tests/enter-firstmate-profile.test.sh
#        FM_ENTRY_LAUNCHER=/path/to/enter-firstmate.sh bash tests/enter-firstmate-profile.test.sh
# The function override and PATH assignments below intentionally live in isolated
# subshells; ShellCheck cannot follow their calls through command substitution.
# shellcheck disable=SC2030,SC2031,SC2329
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
          console_profile_builtin_qualified_set \
          console_profile_gate console_profile_resolve console_argv_subscription_only console_harness_argv \
          read_scalar resolve_host_path; do
  command -v "$fn" >/dev/null || fail "$fn not defined by the library load"
done
pass "FM_ENTRY_LIB=1 defines the profile-menu, subscription, and resolution functions"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-entry-profile-test.XXXXXX") || fail mktemp
trap 'rm -rf "$TMP"' EXIT

# --- the six-profile menu -------------------------------------------------------
[ "$(console_profile_default)" = fable-5.1 ] || fail "the default profile is fable-5.1"
[ "$(console_profile_menu)" = 'fable-5.1 opus-4-8 codex-luna pi-sol pi-astra pi-luna-max' ] || fail "the menu is exactly the six profiles in order"
[ "$(console_profile_harness fable-5.1)" = claude ] || fail "fable-5.1 -> claude"
[ "$(console_profile_harness opus-4-8)" = claude ] || fail "opus-4-8 -> claude"
[ "$(console_profile_harness codex-luna)" = codex ] || fail "codex-luna -> codex"
[ "$(console_profile_harness pi-sol)" = pi ] || fail "pi-sol -> pi"
[ "$(console_profile_harness pi-astra)" = pi ] || fail "pi-astra -> pi"
[ "$(console_profile_harness pi-luna-max)" = pi ] || fail "pi-luna-max -> pi"
[ -z "$(console_profile_harness codex-astra)" ] || fail "retired codex-astra has no harness"
[ -z "$(console_profile_harness codex-sol)" ] || fail "retired codex-sol has no harness"
[ -z "$(console_profile_harness nope)" ] || fail "an unknown profile has no harness"
[ "$(console_profile_model fable-5.1)" = fable ] || fail "fable-5.1 selector is 'fable'"
[ "$(console_profile_model opus-4-8)" = claude-opus-4-8 ] || fail "opus-4-8 model is the pinned 4.8 id"
[ "$(console_profile_model codex-luna)" = gpt-5.6-luna ] || fail "codex-luna model is gpt-5.6-luna"
[ "$(console_profile_model pi-sol)" = opencode/gpt-5.6-sol ] || fail "pi-sol model is opencode/gpt-5.6-sol"
[ "$(console_profile_model pi-astra)" = opencode/gpt-6-astra ] || fail "pi-astra retains its provider-qualified selector"
[ "$(console_profile_model pi-luna-max)" = opencode/gpt-5.6-luna:max ] || fail "pi-luna-max retains its provider-qualified selector"
[ -z "$(console_profile_model codex-astra)" ] || fail "retired codex-astra has no selector"
[ -z "$(console_profile_model codex-sol)" ] || fail "retired codex-sol has no selector"
pass "menu: six profiles map to the exact harness + pinned model selector"

# --- account-valid selector gate -----------------------------------------------
console_profile_model_ok fable-5.1 fable || fail "fable-5.1 selector is accepted"
console_profile_model_ok opus-4-8 claude-opus-4-8 || fail "opus-4-8 selector is accepted"
console_profile_model_ok codex-luna gpt-5.6-luna || fail "codex-luna selector is accepted"
console_profile_model_ok pi-sol opencode/gpt-5.6-sol || fail "Pi's measured Sol selector is accepted"
console_profile_model_ok pi-astra opencode/gpt-6-astra || fail "Pi Astra retains its selector"
console_profile_model_ok pi-luna-max opencode/gpt-5.6-luna:max || fail "Pi Luna Max retains its selector"
console_profile_model_ok pi-sol gpt-5.6-sol && fail "Pi Sol must use the measured provider-qualified selector"
console_profile_model_ok codex-luna gpt-6-astra && fail "the rejected astra selector must not qualify"
console_profile_model_ok codex-luna gpt-5.6-sol && fail "the rejected sol selector must not qualify"
[ "$(console_profile_qualify codex-luna 1 1)" = QUALIFIED ] || fail "codex-luna qualifies only with its accepted selector"
case "$(console_profile_qualify codex-astra 1 1)" in
  "PENDING: codex-astra is not a known profile"*) ;;
  *) fail "retired astra profile cannot be qualified" ;;
esac
pass "selector validity: rejected account selectors cannot be marked qualified"

# --- Opus 4.8 only: Opus 5 is refused, never composed ---------------------------
console_profile_model_ok opus-4-8 claude-opus-4-8 || fail "the pinned 4.8 id is accepted"
console_profile_model_ok opus-4-8 claude-opus-5 && fail "opus-4-8 must refuse the Opus 5 id"
console_profile_model_ok opus-4-8 opus-5 && fail "opus-4-8 must refuse any Opus 5 spelling"
console_profile_model_ok fable-5.1 fable || fail "non-opus profiles are unconstrained by the opus guard"
# the model table itself can never emit an Opus 5 id for the opus profile
case "$(console_profile_model opus-4-8)" in *opus-5*) fail "the opus-4-8 model table must never resolve to Opus 5" ;; esac
pass "Opus 4.8 only: the Opus-5 id is refused and never in the model table"

# --- qualification core (pure): PENDING carries the exact gate, never a swap ----
[ "$(console_profile_qualify codex-luna 1 1)" = QUALIFIED ] || fail "installed + allowed -> QUALIFIED"
case "$(console_profile_qualify codex-luna 1 0)" in "PENDING: model gpt-5.6-luna (codex) is not yet qualified"*) ;; *) fail "not-allowed -> PENDING naming the model and harness" ;; esac
case "$(console_profile_qualify codex-luna 0 1)" in "PENDING: harness codex is not installed"*) ;; *) fail "not-installed -> PENDING naming the harness" ;; esac
case "$(console_profile_qualify nope 1 1)" in "PENDING: nope is not a known profile"*) ;; *) fail "unknown profile -> PENDING, never QUALIFIED" ;; esac
# the not-installed gate is checked before the allowlist gate
case "$(console_profile_qualify codex-luna 0 0)" in "PENDING: harness codex is not installed"*) ;; *) fail "installed gate precedes the allowlist gate" ;; esac
pass "qualify: QUALIFIED only when installed AND allowed; every PENDING states its exact gate"

# --- the built-in qualified set does not follow the default profile -------------
# Which profile is selected by default and which profiles are qualified are
# separate facts: the built-in set is plan-generic (fable-5.1), while codex-luna
# rests on gpt-5.6-luna evidence measured on one ChatGPT account, so a home must
# grant it in its own config rather than inherit it from any menu position.
[ "$(console_profile_builtin_qualified_set)" = fable-5.1 ] || fail "the built-in qualified set is fable-5.1"
for _p in opus-4-8 codex-luna pi-sol pi-astra pi-luna-max; do
  case " $(console_profile_builtin_qualified_set) " in *" $_p "*) fail "$_p must not be qualified out of the box" ;; esac
done
# independence is the contract, not the coincidence that both read fable-5.1
# today: with a different default in force the built-in set must not move
( console_profile_default() { printf 'opus-4-8'; }
  [ "$(console_profile_builtin_qualified_set)" = fable-5.1 ] || exit 1
  FM_HOME=$TMP/home-empty; mkdir -p "$FM_HOME/config"
  [ "$(console_profile_qualified_set)" = fable-5.1 ] || exit 1 ) || fail "the qualified set must not follow whichever profile is the default"
( unset FM_HOME; FM_HOME=$TMP/home-empty; mkdir -p "$FM_HOME/config"
  [ "$(console_profile_qualified_set)" = "$(console_profile_builtin_qualified_set)" ] || exit 1 ) || fail "absent config falls back to the built-in qualified set"
( FM_HOME=$TMP/home-two; mkdir -p "$FM_HOME/config"; printf 'codex-luna fable-5.1\n' > "$FM_HOME/config/console-qualified-profiles"
  [ "$(console_profile_qualified_set)" = 'codex-luna fable-5.1' ] || exit 1 ) || fail "config/console-qualified-profiles extends the qualified set"
pass "qualified set: the built-in fallback is default-independent; config widens it"

# --- the canonical precedence: env, then config, then the built-in default ------
# console_profile_resolve is the single owner both the menu preview and the
# launch path resolve through, so each layer is proven once here. The config
# layer is proven with a profile that is NOT the built-in default.
home_prec=$TMP/home-precedence; mkdir -p "$home_prec/config"
printf 'opus-4-8\n' > "$home_prec/config/console-profile"
# each explicit override resolves to ITSELF while config names another profile,
# so no case can pass by accidentally agreeing with the config or default layer
for _explicit in fable-5.1 opus-4-8 codex-luna pi-sol pi-astra pi-luna-max; do
  for _other in fable-5.1 opus-4-8 codex-luna pi-sol pi-astra pi-luna-max; do
    [ "$_other" = "$_explicit" ] && continue
    printf '%s\n' "$_other" > "$home_prec/config/console-profile"
    ( FM_HOME=$home_prec; export FM_CONSOLE_PROFILE=$_explicit
      [ "$(console_profile_resolve)" = "$_explicit" ] || exit 1 ) || fail "an explicit $_explicit override must win over config $_other"
  done
done
printf 'opus-4-8\n' > "$home_prec/config/console-profile"
( FM_HOME=$home_prec; unset FM_CONSOLE_PROFILE
  [ "$(console_profile_resolve)" = opus-4-8 ] || exit 1 ) || fail "with no env value config/console-profile selects the profile"
( FM_HOME=$TMP/home-empty; unset FM_CONSOLE_PROFILE
  [ "$(console_profile_resolve)" = "$(console_profile_default)" ] || exit 1 ) || fail "with neither env nor config the built-in default is selected"
pass "precedence: FM_CONSOLE_PROFILE, then config/console-profile, then the built-in default"

# --- console_profile_gate composes the two live facts ---------------------------
# The installed-fact the gate reads is only "is this harness name on PATH", so
# all three profile harnesses are stubbed here and PATH is prepended: the
# verdicts below are deterministic even when CI lacks these harnesses.
mkdir -p "$TMP/bin" "$TMP/emptybin"
for _h in claude codex pi; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$_h"; chmod +x "$TMP/bin/$_h"; done
( PATH=$TMP/bin:$PATH; FM_HOME=$TMP/home-empty; [ "$(console_profile_gate fable-5.1)" = QUALIFIED ] || exit 1 ) || fail "fable-5.1 still launches on a home with no qualification config"
( PATH=$TMP/bin:$PATH; FM_HOME=$TMP/home-empty; case "$(console_profile_gate opus-4-8)" in PENDING:*) ;; *) exit 1 ;; esac ) || fail "opus-4-8 stays PENDING out of the box (not in the built-in qualified set)"
pass "gate: the built-in set keeps fable-5.1 launchable and opus-4-8 PENDING"

# codex-luna rests on account-specific evidence: it is PENDING on a home that
# has not granted it, and QUALIFIED once that home's config does.
( PATH=$TMP/bin:$PATH; FM_HOME=$TMP/home-empty
  case "$(console_profile_gate codex-luna)" in "PENDING: model gpt-5.6-luna (codex) is not yet qualified"*) ;; *) exit 1 ;; esac ) || fail "an ungranted home must leave the Codex profile PENDING, never auto-qualified"
home_luna=$TMP/home-luna; mkdir -p "$home_luna/config"; printf 'codex-luna\n' > "$home_luna/config/console-qualified-profiles"
( PATH=$TMP/bin:$PATH; FM_HOME=$home_luna; [ "$(console_profile_gate codex-luna)" = QUALIFIED ] || exit 1 ) || fail "a home granting codex-luna with codex installed -> QUALIFIED"
pass "gate: codex-luna qualifies only from the home's own grant"
( PATH=$TMP/bin:$PATH; FM_HOME=$TMP/home-empty
  case "$(console_profile_gate pi-sol)" in "PENDING: model opencode/gpt-5.6-sol (pi) is not yet qualified"*) ;; *) exit 1 ;; esac ) || fail "pi-sol stays PENDING without a home grant"
home_pi_gate=$TMP/home-pi-gate; mkdir -p "$home_pi_gate/config"; printf 'pi-sol\n' > "$home_pi_gate/config/console-qualified-profiles"
( PATH=$TMP/bin:$PATH; FM_HOME=$home_pi_gate; [ "$(console_profile_gate pi-sol)" = QUALIFIED ] || exit 1 ) || fail "the pi-sol home grant qualifies the installed harness"
pass "gate: pi-sol qualifies only from the home's own grant"
# with the harness off PATH the same default profile reports the install gate
# shellcheck disable=SC2123 # emptying PATH is the point: the harness must be unfindable
( PATH=$TMP/emptybin; FM_HOME=$TMP/home-empty
  case "$(console_profile_gate codex-luna)" in "PENDING: harness codex is not installed"*) ;; *) exit 1 ;; esac ) || fail "an absent codex harness -> PENDING naming the harness"
pass "gate: an absent harness is reported as the exact install gate, never QUALIFIED"

# --- $0 / subscription-only: no paid/gateway/budget selector may be composed ----
console_argv_subscription_only --dangerously-skip-permissions --model fable || fail "the qualified fable argv is clean"
console_argv_subscription_only --dangerously-bypass-approvals-and-sandbox --model gpt-5.6-luna || fail "the codex argv is clean"
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
a=$(console_harness_argv codex gpt-5.6-luna "" "" --sandbox | tr '\n' ' ')
[ "$a" = '--dangerously-bypass-approvals-and-sandbox --model gpt-5.6-luna --sandbox ' ] || fail "codex argv leads with its bypass posture + model (got '$a')"
# codex never gets claude-only settings/resume even if passed
a=$(console_harness_argv codex gpt-5.6-luna /h/s.json 0123abcd-0123-4567-89ab-0123456789ab | tr '\n' ' ')
[ "$a" = '--dangerously-bypass-approvals-and-sandbox --model gpt-5.6-luna ' ] || fail "codex ignores --settings/--resume (got '$a')"
a=$(console_harness_argv pi opencode/gpt-5.6-sol "" "" | tr '\n' ' ')
[ "$a" = '--model opencode/gpt-5.6-sol ' ] || fail "pi-sol composes the measured model without an invented permission flag (got '$a')"
[ "$(console_harness_argv claude fable "" "" | head -1)" = '--dangerously-skip-permissions' ] || fail "claude posture is still argv[1] under the menu"
[ "$(console_harness_argv codex gpt-5.6-luna "" "" | head -1)" = '--dangerously-bypass-approvals-and-sandbox' ] || fail "codex posture is argv[1]"
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

# --- --print-console-menu: default resolution before every hard gate -----------
# The staging qualifier drives this mode, which must render the six-profile menu
# and exit 0 with NO usable tools root and without launching anything (it runs
# before the tools-surface and no-mistakes gates that refuse a real launch).
rc=0
out=$(env -u FM_CONSOLE_PROFILE -u FM_HARNESS -u FM_CODE_ROOT -u FM_RETIRED_HOME \
      FM_HOME="$TMP/home-empty" FM_TOOLS_ROOT=/nonexistent bash "$LAUNCHER" --print-console-menu 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "--print-console-menu must exit 0 with a /nonexistent tools root (rc=$rc, out: $out)"
case "$out" in *'primary console profile menu'*) ;; *) fail "--print-console-menu must render the menu heading (got: $out)" ;; esac
for _prof in fable-5.1 opus-4-8 codex-luna pi-sol pi-astra pi-luna-max; do
  case "$out" in *"$_prof"*) ;; *) fail "--print-console-menu must list profile $_prof (got: $out)" ;; esac
done
case "$out" in *'active profile:    fable-5.1'*) ;; *) fail "no profile supplied must resolve to fable-5.1 (got: $out)" ;; esac
case "$out" in *'default profile:   fable-5.1'*) ;; *) fail "--print-console-menu must show fable-5.1 as the default (got: $out)" ;; esac
# opus-4-8 is not in the default qualified set, so it stays PENDING, never swapped
case "$out" in *'opus-4-8'*'PENDING'*) ;; *) fail "an unqualified profile must render PENDING, never silently substituted (got: $out)" ;; esac
# it renders ONLY the menu: no full doctor report, no launch/exec side effects
case "$out" in *'effective identity'*) fail "--print-console-menu must render only the menu, not the full doctor report" ;; esac
pass "print-console-menu: no profile supplied resolves to fable-5.1 and renders the six-profile menu"

# This home's accepted console selection is pi-sol. A bare, side-effect-free
# invocation must resolve it from config and show the selector Pi will receive.
home_pi=$TMP/home-pi; mkdir -p "$home_pi/config"
printf 'pi-sol\n' > "$home_pi/config/console-profile"
printf 'pi-sol\n' > "$home_pi/config/console-qualified-profiles"
rc=0
out=$(env -u FM_CONSOLE_PROFILE -u FM_HARNESS -u FM_CODE_ROOT \
      FM_HOME="$home_pi" FM_TOOLS_ROOT=/nonexistent bash "$LAUNCHER" --print-console-menu 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "a bare pi-sol preview must exit 0 (rc=$rc, out: $out)"
case "$out" in *'active profile:    pi-sol'*) ;; *) fail "the home must select pi-sol with no env override (got: $out)" ;; esac
case "$out" in *'pi-sol'*'harness=pi'*'model=opencode/gpt-5.6-sol'*) ;; *) fail "pi-sol must compose the accepted Pi selector (got: $out)" ;; esac
pass "print-console-menu: the configured pi-sol profile resolves without an environment override"

# --- --print-console-menu: a non-default config profile renders as active -------
# Builds on the default-profile case above: a home whose config/console-profile
# names a profile OTHER than the built-in default must render THAT profile as
# active, with its row carrying the active marker, and still list all six
# (never a silent swap). codex-luna differs from the built-in default, so this
# fails if the config layer of the precedence chain is ever skipped.
home_alt=$TMP/home-altprofile; mkdir -p "$home_alt/config"
printf 'codex-luna\n' > "$home_alt/config/console-profile"
rc=0
out=$(FM_HOME=$home_alt FM_CONSOLE_PROFILE='' FM_TOOLS_ROOT=/nonexistent bash "$LAUNCHER" --print-console-menu 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "an alternate config profile must still render and exit 0 (rc=$rc, out: $out)"
case "$out" in *'active profile:    codex-luna'*) ;; *) fail "config/console-profile must select the active profile (got: $out)" ;; esac
case "$out" in *'codex-luna'*'<- active'*) ;; *) fail "the active row must carry the active marker (got: $out)" ;; esac
case "$out" in *'default profile:   fable-5.1'*) ;; *) fail "the built-in default is still reported while config selects another (got: $out)" ;; esac
for _prof in fable-5.1 opus-4-8 codex-luna pi-sol pi-astra pi-luna-max; do
  case "$out" in *"$_prof"*) ;; *) fail "an alternate profile menu must still list $_prof (got: $out)" ;; esac
done
pass "print-console-menu: config/console-profile selects a non-default profile without dropping profiles"

# Explicit FM_CONSOLE_PROFILE overrides still resolve to the named profile.
for _explicit in fable-5.1 opus-4-8 codex-luna pi-sol pi-astra pi-luna-max; do
  rc=0
  out=$(env -u FM_HARNESS -u FM_CODE_ROOT -u FM_RETIRED_HOME \
        FM_HOME="$home_alt" FM_CONSOLE_PROFILE="$_explicit" FM_TOOLS_ROOT=/nonexistent \
        bash "$LAUNCHER" --print-console-menu 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "explicit $_explicit profile must render (rc=$rc, out: $out)"
  case "$out" in *"active profile:    $_explicit"*) ;; *) fail "explicit $_explicit profile must win over config (got: $out)" ;; esac
done
pass "profile precedence: each explicit profile overrides config and resolves to itself"

# --- --print-console-menu: inherited FM_* pollution neither corrupts nor leaks --
# The clean-room console inherits an ambient FM_* environment from the live home.
# Host-path pollution (FM_CODE_ROOT / FM_TOOLS_ROOT / FM_RETIRED_HOME) must not
# corrupt the rendered menu nor leak those paths into the output; the menu exits
# before the host-path gates, so it renders from config alone.
rc=0
out=$(FM_HOME=$home_alt FM_CONSOLE_PROFILE='' \
      FM_CODE_ROOT=/polluted/donor FM_TOOLS_ROOT=/polluted/tools FM_RETIRED_HOME=/polluted/retired \
      bash "$LAUNCHER" --print-console-menu 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "host-path pollution must not break the menu (rc=$rc, out: $out)"
case "$out" in *'active profile:    codex-luna'*) ;; *) fail "pollution must not change the config-selected active profile (got: $out)" ;; esac
case "$out" in *'/polluted/'*) fail "no inherited host path may leak into the menu output (got: $out)" ;; esac
pass "print-console-menu: inherited host-path pollution neither corrupts the render nor leaks into output"
# FM_CONSOLE_PROFILE is a DOCUMENTED override, not pollution: an ambient value
# selects the active profile over config, still rendering every profile.
rc=0
out=$(FM_HOME=$home_alt FM_CONSOLE_PROFILE=opus-4-8 FM_TOOLS_ROOT=/nonexistent bash "$LAUNCHER" --print-console-menu 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "an FM_CONSOLE_PROFILE override must still render (rc=$rc)"
case "$out" in *'active profile:    opus-4-8'*) ;; *) fail "FM_CONSOLE_PROFILE must override config/console-profile (got: $out)" ;; esac
case "$out" in *'codex-luna'*) ;; *) fail "the override must still render the full menu (got: $out)" ;; esac
pass "print-console-menu: FM_CONSOLE_PROFILE is honored as a documented override, still rendering the full menu"

# --- --print-console-menu: side-effect-free, and other invocations stay gated ---
# The preview must touch nothing in the home (no launch/exec/service/state
# effect) and, crucially, its early exit must not weaken the mandatory host-path
# gates on OTHER invocations: the same empty environment that the preview renders
# cleanly must still refuse a real launch at the code-root gate.
home_se=$TMP/home-sidefx; mkdir -p "$home_se/config"
find "$home_se" | LC_ALL=C sort > "$TMP/se-before.txt"
rc=0
out=$(FM_HOME=$home_se FM_CODE_ROOT='' FM_TOOLS_ROOT=/nonexistent bash "$LAUNCHER" --print-console-menu 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "the preview must exit 0 with no usable code/tools root (rc=$rc, out: $out)"
find "$home_se" | LC_ALL=C sort > "$TMP/se-after.txt"
diff "$TMP/se-before.txt" "$TMP/se-after.txt" >/dev/null || fail "the preview must create no files in the home (side effects detected)"
# the same empty environment, run as a real launch, must still be refused
rc=0
out=$(FM_HOME=$home_se FM_CODE_ROOT='' FM_TOOLS_ROOT=/nonexistent bash "$LAUNCHER" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "a real launch with an unset code root must still refuse (the preview must not open a gate hole)"
case "$out" in *'code root is unset'*) ;; *) fail "the sibling launch must refuse at the code-root gate (got: $out)" ;; esac
pass "print-console-menu: the preview is side-effect-free and leaves the mandatory gates intact for a real launch"

echo "all six-profile menu, subscription-boundary, and host-path resolution tests passed"
