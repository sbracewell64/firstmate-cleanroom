#!/usr/bin/env bash
# Behavior tests for the pure console-launch and permission-policy decisions in
# the versioned launcher source bin/enter-firstmate.sh (stale resume; harness
# permission policy). Loads it with FM_ENTRY_LIB=1, which defines only the pure
# functions and runs no identity check, so this file touches no home, no Herdr
# session, no watcher, and starts no harness.
#
# The four-profile primary menu is covered by enter-firstmate-profile.test.sh;
# this file proves the single-profile console composition still holds (the
# regression proof for the pre-existing launch/console/resume path).
#
# Usage: bash tests/enter-firstmate-launch.test.sh
#        FM_ENTRY_LAUNCHER=/path/to/enter-firstmate.sh bash tests/enter-firstmate-launch.test.sh
#        FM_CODE_ROOT_PROBE=<checkout> adds the drift proof against the real
#        bin/fm-spawn.sh (skipped when the checkout is absent).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAUNCHER=${FM_ENTRY_LAUNCHER:-$HERE/../bin/enter-firstmate.sh}
CODE_ROOT=${FM_CODE_ROOT_PROBE:-$HERE/..}
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
[ -f "$LAUNCHER" ] || fail "launcher not found: $LAUNCHER"
# shellcheck disable=SC1090 # the launcher path is resolved at run time
FM_ENTRY_LIB=1 . "$LAUNCHER" || fail "FM_ENTRY_LIB=1 load failed"
for fn in permission_policy_state permission_policy_posture permission_policy_spawn_token console_harness_argv \
          console_resume_id_valid console_session_store_dir console_resume_candidate console_launch_outcome \
          console_pane_classify console_converge_action; do
  command -v "$fn" >/dev/null || fail "$fn not defined by the library load"
done
[ -z "${FM_HERDR_ANCESTRY:-}" ] || fail "library load must stop before the identity checks"
pass "FM_ENTRY_LIB=1 defines the launch and policy functions and runs nothing else"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-entry-launch-test.XXXXXX") || fail mktemp
trap 'rm -rf "$TMP"' EXIT

# --- permission policy table ----------------------------------------------------
[ "$(permission_policy_state claude)" = QUALIFIED ] || fail "claude must be QUALIFIED"
[ "$(permission_policy_posture claude)" = '--dangerously-skip-permissions' ] || fail "claude posture is the exact captain-authorized flag"
for h in codex opencode grok kimi cursor muse; do
  [ "$(permission_policy_state "$h")" = QUALIFIED ] || fail "$h must be QUALIFIED (upstream spawn template carries its equivalent)"
  [ -n "$(permission_policy_spawn_token "$h")" ] || fail "$h must name a spawn token to prove"
done
[ "$(permission_policy_state pi)" = CNO ] && [ "$(permission_policy_state pi-signed)" = CNO ] || fail "pi and pi-signed are CNO, never a guessed flag"
[ -z "$(permission_policy_spawn_token pi)" ] || fail "pi has no invented token"
case "$(permission_policy_posture pi)" in none:*) ;; *) fail "pi posture must say none" ;; esac
[ "$(permission_policy_state bash)" = NOT_APPLICABLE ] || fail "bash (evidence harness) is NOT_APPLICABLE"
[ "$(permission_policy_state made-up)" = CNO ] || fail "an unknown harness is CNO, never PASS"
for h in $(permission_policy_harnesses); do
  case "$(permission_policy_state "$h")" in QUALIFIED|NOT_APPLICABLE|CNO) ;; *) fail "$h state must be one of the three verdicts" ;; esac
done
pass "permission policy: claude exact flag, seven QUALIFIED equivalents, pi CNO, unknown CNO"

# --- drift proof against the real spawn compiler --------------------------------
if [ -f "$CODE_ROOT/bin/fm-spawn.sh" ]; then
  for h in claude codex opencode grok kimi cursor muse; do
    grep -qF -- "$(permission_policy_spawn_token "$h")" "$CODE_ROOT/bin/fm-spawn.sh" || fail "drift: $h token '$(permission_policy_spawn_token "$h")' is not in $CODE_ROOT/bin/fm-spawn.sh"
  done
  pass "every QUALIFIED worker posture is still present in $CODE_ROOT/bin/fm-spawn.sh (no drift)"
else
  pass "skip: drift proof (no code root at $CODE_ROOT)"
fi

# --- console argv (launch-byte watched reds), new <harness> <model> signature ---
# console_harness_argv <harness> <model|""> <settings|""> <resume|""> [passthrough...]
argv_lines() { console_harness_argv "$@" | tr '\n' ' '; }
a=$(argv_lines claude "" "" "")
[ "$a" = '--dangerously-skip-permissions ' ] || fail "fresh claude argv, no model/settings, is exactly the permission flag (got '$a')"
a=$(argv_lines claude "" /h/config/claude-settings.json "")
[ "$a" = '--dangerously-skip-permissions --settings /h/config/claude-settings.json ' ] || fail "settings follow the permission flag (got '$a')"
a=$(argv_lines claude "" /h/s.json 0123abcd-0123-4567-89ab-0123456789ab --verbose)
[ "$a" = '--dangerously-skip-permissions --settings /h/s.json --resume 0123abcd-0123-4567-89ab-0123456789ab --verbose ' ] || fail "resume and passthrough follow (got '$a')"
case "$(console_harness_argv claude "" "" "" x)" in *--dangerously-skip-permissions*) ;; *) fail "claude argv can never omit the permission flag" ;; esac
[ "$(console_harness_argv claude "" "" "" | head -1)" = '--dangerously-skip-permissions' ] || fail "the permission flag is argv[1] for claude"
a=$(argv_lines bash "" "" "" -c 'echo hi')
[ "$a" = "-c echo hi " ] || fail "a non-profile harness gets only the passthrough (got '$a')"
[ -z "$(argv_lines bash "" /h/s.json 0123abcd-0123-4567-89ab-0123456789ab)" ] || fail "model/settings/resume are never composed for bash"
pass "console argv: claude always leads with --dangerously-skip-permissions; bash gets passthrough only"

# --- resume id shape and Claude's native transcript store -----------------------
console_resume_id_valid 0123abcd-0123-4567-89ab-0123456789ab || fail "well-formed id accepted"
for bad in '' '0123ABCD-0123-4567-89ab-0123456789ab' '../etc/passwd' '0123abcd-0123-4567-89ab-0123456789ab;rm' "0123abcd-0123-4567-89ab-0123456789ab'" 'x' '0123abcd-0123-4567-89ab-0123456789a'; do
  console_resume_id_valid "$bad" && fail "malformed id must be rejected: '$bad'"
done
d=$(console_session_store_dir /home/u/.claude /mnt/e/FirstMate-Cleanroom/upstream/firstmate)
[ "$d" = '/home/u/.claude/projects/-mnt-e-FirstMate-Cleanroom-upstream-firstmate' ] || fail "store dir encoding (got $d)"
d=$(console_session_store_dir /h/.claude /home/shane/.firstmate-cleanroom/projects/x)
[ "$d" = '/h/.claude/projects/-home-shane--firstmate-cleanroom-projects-x' ] || fail "dots encode as dashes too (got $d)"
mkdir -p "$TMP/cfg/projects/-mnt-e-FirstMate-Cleanroom-upstream-firstmate"
id=0123abcd-0123-4567-89ab-0123456789ab
[ "$(console_resume_candidate "$TMP/cfg" /mnt/e/FirstMate-Cleanroom/upstream/firstmate "$id")" = no-transcript ] || fail "no transcript -> no-transcript"
: > "$TMP/cfg/projects/-mnt-e-FirstMate-Cleanroom-upstream-firstmate/$id.jsonl"
[ "$(console_resume_candidate "$TMP/cfg" /mnt/e/FirstMate-Cleanroom/upstream/firstmate "$id")" = no-transcript ] || fail "an empty transcript is not resumable"
echo '{"type":"summary"}' > "$TMP/cfg/projects/-mnt-e-FirstMate-Cleanroom-upstream-firstmate/$id.jsonl"
[ "$(console_resume_candidate "$TMP/cfg" /mnt/e/FirstMate-Cleanroom/upstream/firstmate "$id")" = valid ] || fail "a present transcript is valid"
[ "$(console_resume_candidate "$TMP/cfg" /mnt/e/FirstMate-Cleanroom/upstream/firstmate "../$id")" = invalid-id ] || fail "shape check precedes the store read"
[ "$(console_resume_candidate "$TMP/cfg" /other/cwd "$id")" = no-transcript ] || fail "a transcript of another project directory never resumes here"
pass "resume candidate: exact id shape, Claude's native per-project transcript store, no cross-project adoption"

# --- observed outcome: one fallback, never a loop -------------------------------
[ "$(console_launch_outcome 1 1 2 20)" = fallback-fresh ] || fail "stale resume (rc 1 within window) -> fallback-fresh"
[ "$(console_launch_outcome 1 1 19 20)" = fallback-fresh ] || fail "boundary: 19s < 20s window -> fallback"
[ "$(console_launch_outcome 1 1 20 20)" = exited ] || fail "at the window a non-zero exit is an ordinary exit, not stale"
[ "$(console_launch_outcome 1 0 2 20)" = exited ] || fail "a resume that exits 0 is a normal exit (captain quit), never a fallback"
[ "$(console_launch_outcome 1 1 4000 20)" = exited ] || fail "a long-lived resume that exits non-zero is a normal exit"
[ "$(console_launch_outcome 0 1 1 20)" = exited ] || fail "a failed FRESH launch never falls back again (no retry loop)"
[ "$(console_launch_outcome 0 0 1 20)" = exited ] || fail "fresh rc 0"
[ "$(console_launch_outcome '' '' '' '')" = exited ] || fail "missing inputs never fall back"
pass "launch outcome: exactly one stale-resume fallback, a failed fresh launch exits"

# --- pane classification (Desktop launch) ---------------------------------------
c() { console_pane_classify "$@"; }
[ "$(c claude 500 400 400 1 claude)" = canonical ] || fail "harness whose parent is the live --console shell -> canonical"
[ "$(c claude 400 300 400 1 claude)" = canonical ] || fail "harness that IS the recorded pid (exec shape) -> canonical"
[ "$(c bash 400 300 400 1 claude)" = starting ] || fail "the recorded --console shell itself in the foreground -> starting"
[ "$(c claude 500 400 400 0 claude)" = foreign-harness ] || fail "parent pid matches but the recorded console is dead -> foreign"
[ "$(c claude 700 600 400 1 claude)" = foreign-harness ] || fail "harness not parented by the console -> foreign"
[ "$(c claude 2650242 2279288 0 0 claude)" = foreign-harness ] || fail "no recorded console at all -> foreign"
[ "$(c bash 2279288 2278112 12345 0 claude)" = shell ] || fail "restored pane at bash with a dead recorded console -> shell"
[ "$(c zsh 10 9 0 0 claude)" = shell ] || fail "any recognized shell -> shell"
[ "$(c vim 10 9 0 0 claude)" = other ] || fail "an editor -> other"
[ "$(c /usr/bin/claude 500 400 400 1 claude)" = canonical ] || fail "path-qualified names compare by basename"
[ "$(c bash 10 9 0 0 bash)" = foreign-harness ] || fail "with FM_HARNESS=bash a bash foreground is the harness, never a stranded shell"
[ "$(c '' '' '' '' '' '')" = other ] || fail "empty inputs -> other"
pass "pane classification: canonical, starting, foreign-harness, shell, other"

# --- convergence action ---------------------------------------------------------
[ "$(console_converge_action canonical 1 empty x)" = reuse ] || fail canonical
[ "$(console_converge_action starting 1 unknown '')" = reuse ] || fail starting
[ "$(console_converge_action shell 1 unknown '')" = restart ] || fail "stranded shell after a server start -> restart"
[ "$(console_converge_action shell 0 unknown '')" = restart ] || fail "stranded shell on a running server -> restart too"
[ "$(console_converge_action foreign-harness 1 empty 0123abcd-0123-4567-89ab-0123456789ab)" = converge ] || fail "Herdr-restored harness, empty composer, id known -> converge"
[ "$(console_converge_action foreign-harness 0 empty 0123abcd-0123-4567-89ab-0123456789ab)" = leave ] || fail "server already running: a foreign harness may be a live captain session -> leave"
[ "$(console_converge_action foreign-harness 1 pending 0123abcd-0123-4567-89ab-0123456789ab)" = leave ] || fail "composer not provably empty -> never typed into"
[ "$(console_converge_action foreign-harness 1 empty '')" = leave ] || fail "no session id to carry over -> leave (nothing to converge onto)"
[ "$(console_converge_action other 1 empty x)" = leave ] || fail other
[ "$(console_converge_action absent 1 empty x)" = leave ] || fail absent
pass "convergence: restart a stranded shell, converge only a just-restored idle harness, otherwise leave"

# --- convergence plan: a server this launch started restores panes only on TUI attach ---
command -v console_converge_plan >/dev/null || fail "console_converge_plan not defined"
[ "$(console_converge_plan 1)" = deferred ] || fail "server started by this launch -> deferred to the post-attach owner"
[ "$(console_converge_plan 0)" = inline ] || fail "server already running -> inline"
[ "$(console_converge_plan '')" = inline ] || fail "missing input -> inline"
pass "convergence plan: deferred after a server start, inline otherwise"

# --- claim deliverability (the L7 delivery seam) --------------------------------
command -v cold_arm_claim_deliverable >/dev/null || fail "cold_arm_claim_deliverable not defined"
[ "$(cold_arm_claim_deliverable cold-start)" = deliverable ] || fail "a live cold-start arm-owner types its close into the console -> deliverable"
[ "$(cold_arm_claim_deliverable stop-hook)" = stale ] || fail "a Stop-hook auto-arm delivers only by exit-2 into its own harness -> stale for a cold-start console"
[ "$(cold_arm_claim_deliverable gone)" = stale ] || fail "a dead owner cannot deliver -> stale"
[ "$(cold_arm_claim_deliverable other)" = stale ] || fail "a live foreign owner is not a typed-delivery owner -> stale"
[ "$(cold_arm_claim_deliverable '')" = stale ] || fail "missing kind -> stale (fail safe: launcher takes over delivery)"
pass "claim deliverability: only a live cold-start arm-owner is a valid cold-start defer target"

echo "all console launch and permission policy tests passed"
