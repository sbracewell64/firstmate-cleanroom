#!/usr/bin/env bash
# Captain entry point for the clean-room FirstMate environment.
#
# CANONICAL MAINTAINED SOURCE (runtime-pin-adoption-gap, slice 1). This tracked
# file is the single maintained SOURCE for the captain launcher/console. It is
# host-AGNOSTIC: the home-specific absolute paths are resolved through the
# FM_HOME/config contract (see the resolution block below), never hardcoded, so
# one file serves any clean-room home. The concrete host-local
# $FM_HOME/enter-firstmate.sh is an INSTALL/ACTIVATION CONSUMER rendered from
# this source at a captain-authorized cutover by bin/fm-render-launcher.sh, which
# also captures the pre-cutover rollback snapshot. This source performs no
# cutover itself.
#
# Starts a primary FirstMate session whose CODE comes from the pinned, read-only
# upstream checkout and whose OPERATIONAL HOME is this runtime root, per the
# FM_HOME contract in <code-root>/docs/configuration.md ("FM_HOME").
#
# PRIMARY CONSOLE PROFILE MENU (runtime-pin-adoption-gap, slice 1). The console's
# harness+model comes from a four-profile menu (console_profile_* below):
# fable-5.1 (default), opus-4-8 (Opus 4.8 only), codex-astra, codex-sol. Select
# with FM_CONSOLE_PROFILE or config/console-profile. An unqualified profile is
# PENDING with its exact gate and is never silently substituted; the console is
# $0/subscription-only at the composed launch. Worker and pipeline model profiles
# are separate owners (the code root's fm-spawn.sh, config/crew-dispatch.json)
# and are never switched here.
#
# The operational home moved to ext4 (WSL native) on 2026-09-02: drvfs carries
# no file modes, and the upstream watcher registrar requires an exact 0700 on a
# private check script. The code root, the tools and the evidence tree stay on
# E:; only the private mutable runtime lives here.
#
# HERDR ISOLATION (2026-09-02, commission part F). The other FirstMate
# installation on this machine (/home/shane/kun-agent-workspace) is LIVE and its
# workers occupy Herdr's "default" session. The upstream adapter resolves EVERY
# primary home's workspace label to the constant "firstmate"
# (<code-root>/bin/backends/herdr.sh, fm_backend_herdr_workspace_label) with no
# per-home discriminator, so two primaries sharing one Herdr session would see,
# adopt and scan each other's workspace. The isolation seam is the one the
# upstream mechanism ALREADY reads -- the named Herdr session (HERDR_SESSION;
# fm_backend_herdr_session) -- because a named session is a separate Herdr
# server with its own socket and its own workspace list, so the constant label
# cannot collide. No upstream file is patched. The durable value lives in
# config/herdr-session and THIS script is its only reader.
#
# CAPTAIN CONSOLE INSIDE HERDR (2026-09-02, control issue #3 comment 2, launcher
# UX ruling). Invoked outside Herdr (the Desktop shortcut), this script now:
#   1. validates every identity below and REFUSES rather than degrading;
#   2. drops any FOREIGN Herdr ancestry (a pane of another session) so the
#      launch can never adopt the legacy session;
#   3. starts the dedicated named Herdr session's server if it is not running;
#   4. finds this home's ONE console workspace (label "firstmate") in that
#      session, or creates it and types `enter-firstmate.sh --console` into its
#      root pane (no worker is spawned to build the UI);
#   5. attaches the Herdr TUI to that session in the current console window.
# Invoked with --console (only ever by step 4, inside the clean-room session's
# own pane) it re-validates and execs the harness in place. Closing the TUI
# window leaves the server and the console running; the next click re-attaches.
#
# NO-MISTAKES ISOLATION (2026-09-02, control issue #3 no_mistakes ruling). The
# clean-room never attaches to the shared legacy no-mistakes daemon/root
# (~/.no-mistakes, served by a v1.40.3 daemon for the live fleet). Upstream
# no-mistakes documents NM_HOME as the supported relocation selector
# (tools/no-mistakes/docs/.../reference/environment.md: "everything else moves
# under this root", including socket, PID, lock, database and worktrees, with a
# per-root managed-service suffix). This launcher exports
# NM_HOME=<FM_HOME>/no-mistakes for the console and therefore every worker,
# asserts the resolved client is the clean-room pinned binary at/above the
# upstream floor, and ensures that root's own daemon is running. It REFUSES to
# start a console whose NM_HOME would resolve to the shared root.
#
# TOOLS. The clean-room tools surface (<tools>/bin) is PATH[0], asserted; the
# effective tool policy (ABSENT / PRESENT_BELOW_FLOOR / QUALIFIED, floors
# projected from the pinned upstream) is rendered by <tools>/tool-policy.sh and
# printed by the doctor. The repair path is always the clean-room-scoped
# tools/pin-axi-tools.sh, never a host-global install.
#
# ENVIRONMENT PROPAGATION ASSERTION (2026-09-06, NMF-1, no-mistakes friction
# audit finding NMF-ENV). Every worker, and every no-mistakes gate agent the
# clean-room daemon spawns, inherits its NM_HOME and PATH from the Herdr SERVER
# of the named session, not from the shell that clicked the launcher: the
# server is started once (ensure_session) and outlives every console. A server
# started before the exports above, or from a shell whose ~/.profile had
# re-prepended ~/.local/bin, silently drives every worker with the legacy
# v1.40.3 client and tasks-axi 0.2.3 while the console itself looks correct.
# So (1) ensure_session REFUSES to start a server unless NM_HOME is exported
# and the clean-room tools are PATH[0] at that moment (the ordering is enforced,
# not positional); (2) after the session is up, assert_session_env reads the
# live server's own environment (/proc/<pid>/environ) and refuses the launch on
# a mismatch, naming the captain-gated restart; (3) --doctor prints the
# server's NM_HOME and PATH[0] and the tool profile observed from a direct
# shell and from a login shell (the negative control), using the upstream
# owner bin/fm-tool-profile.sh when the pinned code root carries it and a
# minimal inline observation (--tool-profile-inline, internal) otherwise;
# (4) the console launch prints every ENVIRONMENT_UNREADY line loudly before
# starting and never weakens the gate that will refuse on it. Nothing here
# restarts the server: a stale server is reported with the exact consequence,
# and the restart stays with the captain.
#
# COLD-START SUPERVISION ARM (2026-09-03, control issue #8 REVISE). Architecture
# law: a fresh FirstMate session with registered supervision sources must be
# supervised BEFORE the first model turn, and cognition is never the startup
# trigger for infrastructure. The watcher's between-turn owner (the Claude Stop
# asyncRewake hook, <code-root>/bin/fm-claude-stop-autoarm.sh) runs inside the
# console's own process group: it dies with the console, and after a relaunch
# nothing re-arms it until a human sends a message (observed: the hook's arm
# output showed `watcher: started ... (beacon fresh)` followed by `Terminated
# sleep "$POLL"`). This launcher therefore arms supervision itself, in
# --console mode, AFTER FM_HOME/config/session identity are resolved and BEFORE
# the harness is exec'd, by launching ONE detached owner process
# (`enter-firstmate.sh --arm-owner`, internal) that:
#   1. re-derives the same gates the Stop hook applies (bin/fm-supervision-lib.sh
#      need, state/.afk, session lock liveness from bin/fm-session-lock-lib.sh);
#   2. claims the next auto-arm generation in the SAME epoch ledger the Stop hook
#      uses (state/.claude-autoarm-epoch via fm_autoarm_claim_next), so the first
#      Stop after the first turn defers to it instead of arming a duplicate;
#   3. runs the canonical arm bin/fm-watch-arm.sh in its FOREGROUND (never `&`),
#      which starts the watcher singleton or attaches to a live one and prints
#      exactly one `watcher: started|attached|FAILED` line;
#   4. when the cycle closes with an actionable reason, delivers that reason to
#      the console pane as a typed `watcher`-kind operational input
#      (bin/fm-operational-input.sh, the same envelope the away daemon and the
#      OpenCode wake plugin use) through the backend's composer-guarded submit
#      core, then commits `rewake` in the ledger so the next Stop takes the next
#      generation. Nothing turns a queued wake into a model turn otherwise.
# The owner runs under setsid with stdio detached (state/cold-start-arm.log), so
# it outlives this shell's exec into the harness and the console's exit; the
# next launch then attaches to its watcher instead of starting a second one.
# The launcher waits for the arm line plus a verified fresh beacon
# (fm_watcher_healthy) before exec, bounded by FM_ENTRY_ARM_TIMEOUT (default
# 40s). Supervision required but unverifiable: the console starts VISIBLY
# DEGRADED with a loud banner (the session-start digest's guard alarm and the
# first Stop's auto-arm are the existing recovery), except an unwritable
# state/ which is refused outright because no lock, beacon, or ledger could be
# recorded. --doctor reports the whole posture and still starts nothing.
#
# CONSOLE LAUNCH CONTRACT AND STALE RESUME (2026-09-03, control issue #8
# REVISE 2, after live relaunch 1 FAILED at 21:16Z). Herdr persists each pane's
# Claude session id (source herdr:claude, reported by its own Claude SessionStart
# hook) and, when its server restarts, its native resume-on-restore types
# `claude --resume <id>` into the restored pane BEFORE this launcher can act
# (global config.toml `[session] resume_agents_on_restore`, default true).
# Observed: the persisted id was stale, Claude exited with `No conversation
# found`, the console pane sat at a bare shell, and this launcher still reported
# the recorded pane as `existing`, because "the pane exists" was its entire
# liveness predicate. The repair keeps ONE owner (this file), adds no session
# store and no second resume registry:
#   * --console owns resume. The candidate id is Herdr's own pane record, or an
#     explicit --resume passed by the convergence path below. It is resumed only
#     when Claude's native session store holds that transcript, and the harness
#     runs as this shell's FOREGROUND CHILD so `--resume` success is OBSERVED:
#     a resume that exits non-zero within FM_ENTRY_RESUME_WINDOW seconds falls
#     back exactly once to a fresh session with the identical canonical argv
#     (same harness, style settings, permission policy, environment, and the
#     supervision arm already verified above it). A failing fresh launch exits
#     loudly; --console never returns to an interactive shell as a nominal
#     successful startup.
#   * The Desktop launch classifies the recorded console pane by its OBSERVED
#     foreground (herdr pane process-info, plus the upstream idle-shell proof)
#     against the console record's console_pid: canonical (the harness whose
#     parent is the --console shell) -> reuse; a bare idle shell -> the console
#     contract is typed into that pane again (bounded, once per two minutes);
#     a harness this launcher did not start -> when THIS launch started the
#     server (Herdr's restore is then the only possible author) it is exited
#     with the harness's own exit command through the upstream verified submit
#     core and relaunched canonically with the SAME session id, otherwise it is
#     left untouched and reported loudly (never typed into).
# Every launch decision is one line in state/console-launch.log, fields in the
# console record, and a block in the doctor's "captain console" section.
# Live relaunch 3 (22:51Z) showed a THIRD seam, in delivery rather than launch:
# an auto-arm generation owned by a Stop-hook auto-arm (bin/fm-claude-stop-autoarm.sh)
# from the PRE-relaunch harness incarnation survived the server stop and stayed
# healthy. cold_arm_ensure saw an open, healthy claim and chose defer-open-claim,
# trusting that owner to deliver its close "to this console". But a Stop-hook
# auto-arm delivers ONLY by exit-2 rewake into ITS OWN harness, which the relaunch
# had already killed; the captured wake was queued and never typed into the new
# console (L7 FAIL, control #8). The rule: at cold-start (this incarnation has
# taken zero turns) only a LIVE cold-start arm-owner - which delivers by typing a
# watcher-kind operational input into the composer - can deliver here. A Stop-hook
# or dead/foreign owner is stale-for-this-console; the launcher supersedes that
# generation (cold_arm_supersede_stale) and arms its own typed-delivery owner,
# which attaches to the still-healthy watcher rather than starting a second one.
# Live relaunch 2 (21:50Z) showed the timing that the inline classification
# cannot see: a headless Herdr server evaluates its restore at start but SPAWNS
# the restored console pane's terminal only when a TUI client attaches (server
# log: `client connected` then `pane.spawn.start` 13 s after startup), and this
# launcher attaches LAST (`exec herdr --session`). The inline convergence saw an
# unreadable pane for its whole settle window and left it; the native resume
# then ran unopposed. So when THIS launch started the server, the convergence
# is delegated to ONE detached owner (`--converge-owner`, the arm owner's
# setsid idiom) that waits for the pane to materialize after the attach, lets
# the restore settle, and applies exactly the same classification and actions.
#
# HARNESS PERMISSION POLICY (2026-09-03, control issue #7 ruling 3, explicit
# captain authorization; applied in the recovery session after the live proof).
# The primary console launches Claude with --dangerously-skip-permissions on
# every start, resume, and fallback. The policy owner is the permission_policy_*
# block below (this launcher), consumed by the --console argv composer, asserted
# on the composed argv before launch (launch-byte watched red), and rendered by
# the doctor. Worker and secondmate harnesses keep the upstream spawn compiler's
# own equivalents (<code-root>/bin/fm-spawn.sh launch templates); this file only
# READS that file to prove each expected token is still present (drift watched
# red) and never duplicates a flag into a spawn. The policy removes interactive
# approval prompts only: FirstMate authority, merge and landing rules, gates,
# validators, and credential handling are untouched, and machine-global harness
# settings are never written.
#
# Usage:  enter-firstmate.sh [harness arguments...]     start/attach the console inside Herdr
#         enter-firstmate.sh --doctor                    print every effective identity, start nothing
#         enter-firstmate.sh --console [harness args]    (internal) run the harness in the current clean-room pane
#         FM_ENTRY_DRY_RUN=1 enter-firstmate.sh          same as --doctor
#         FM_ENTRY_NO_ATTACH=1 enter-firstmate.sh        (evidence) start/ensure the console, do not attach the TUI
#         enter-firstmate.sh --arm-owner <backend> <target> <handoff-file>
#                                                        (internal) detached cold-start arm owner, started by --console
#         FM_ENTRY_ARM_TIMEOUT=<s>                       bound for the pre-exec watcher verification (default 40)
#         FM_ENTRY_DELIVER_WAIT=<s>                      bound the arm owner waits for a ready composer (default 900)
#         enter-firstmate.sh --console --resume <id>   (internal) same, resuming Claude session <id> when its transcript exists
#         FM_ENTRY_RESUME_WINDOW=<s>                     a resume that exits non-zero within this bound is stale (default 20)
#         FM_ENTRY_RESTORE_SETTLE=<s>                    bound waited for Herdr's restore to settle after this launch started the server (default 12)
#         FM_ENTRY_EXIT_WAIT=<s>                         bound for a restored non-canonical harness to exit before the canonical relaunch (default 90)
#         enter-firstmate.sh --converge-owner <ws> <pane>  (internal) detached post-attach convergence owner, started by a launch that started the server
#         FM_ENTRY_ATTACH_WAIT=<s>                       bound the convergence owner waits for the restored pane to materialize (default 120)
#         FM_ENTRY_COMPOSER_WAIT=<s>                     bound the convergence waits for a just-restored harness's composer to read empty (default 60)
#         FM_ENTRY_LIB=1 . enter-firstmate.sh            load only the pure decision functions (tests)
#         FM_CONSOLE_PROFILE=<name>                      select the primary console profile (default fable-5.1)
#         FM_HARNESS=<harness>                           explicit harness override (e.g. bash evidence runs); bypasses the profile menu
#   Host paths (env override, else $FM_HOME/config/<name>): FM_CODE_ROOT/config code-root,
#   FM_TOOLS_ROOT/config tools-root, FM_CONTROL_RESOLVER/config control-resolver,
#   FM_RETIRED_HOME/config retired-home, FM_EXCHANGE_OWNER/config exchange-owner.
#   Console profile config: config/console-profile (active), config/console-qualified-profiles (the $0-qualified set).
set -eu

# --- Host-specific paths: resolved through the FM_HOME/config contract ---------
# This is the tracked, host-AGNOSTIC launcher SOURCE. The home-specific absolute
# paths are NOT hardcoded here; each is taken from its environment override,
# then from a scalar under $FM_HOME/config, so one file serves any clean-room
# home and the concrete host activation consumer is rendered from it at cutover
# (bin/fm-render-launcher.sh). FM_HOME is the environment's, or the directory
# this launcher sits in (the consumer is installed at $FM_HOME/enter-firstmate.sh).
# FM_CODE_ROOT is resolved this way ON PURPOSE and NEVER from the current
# directory: the Windows shortcut's --cd points at the DONOR code root, and the
# adopted clean-room release must win over that inherited cwd (the console pane's
# own cwd is set from FM_CODE_ROOT via `herdr workspace create --cwd`, below).
# Required paths that resolve to neither env nor config are refused loudly, but
# only on a real launch: the refusal lives past the FM_ENTRY_LIB return so the
# pure-function tests can load this file with nothing configured.
FM_SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
FM_HOME=${FM_HOME:-$(dirname "$FM_SELF")}

# Scalar config, read with the upstream whole-file-strip convention.
read_scalar() {  # <config-name>
  local f="$FM_HOME/config/$1"
  [ -f "$f" ] || return 1
  tr -d '[:space:]' < "$f"
}
# A host path: environment override, then a config scalar; empty when neither is
# set (the caller decides whether that is fatal).
resolve_host_path() {  # <env-value> <config-name>
  if [ -n "$1" ]; then printf '%s' "$1"; else read_scalar "$2" || true; fi
}

FM_CODE_ROOT=$(resolve_host_path "${FM_CODE_ROOT:-}" code-root)
FM_TOOLS_ROOT=$(resolve_host_path "${FM_TOOLS_ROOT:-}" tools-root)
FM_TOOLS=${FM_TOOLS_ROOT:+$FM_TOOLS_ROOT/bin}
FM_CONTROL_RESOLVER=$(resolve_host_path "${FM_CONTROL_RESOLVER:-}" control-resolver)
FM_RETIRED_HOME=$(resolve_host_path "${FM_RETIRED_HOME:-}" retired-home)
# An explicit FM_HARNESS (e.g. FM_HARNESS=bash evidence runs) is honored as-is
# with no model selector; otherwise the active console profile drives it below.
FM_HARNESS_ENV=${FM_HARNESS:-}
FM_HARNESS=${FM_HARNESS:-claude}
FM_CONSOLE_MODEL=''
FM_CONSOLE_LABEL=firstmate        # the upstream adapter's constant primary label; isolated by the session, not the label
NM_SHARED_ROOT=$HOME/.no-mistakes

MODE=console-launch
DOCTOR=${FM_ENTRY_DRY_RUN:-}
case "${1:-}" in
  --doctor) DOCTOR=1; shift ;;
  --console) MODE=console-run; shift ;;
  --arm-owner) MODE=arm-owner; shift ;;
  --converge-owner) MODE=converge-owner; shift ;;
  --tool-profile-inline) MODE=tool-profile-inline; DOCTOR=; shift ;;
  --print-console-menu) MODE=print-console-menu; DOCTOR=; shift ;;
esac
[ -z "$DOCTOR" ] || MODE=doctor

die() { printf 'enter-firstmate: %s\n' "$*" >&2; exit 1; }

# Keep Desktop and pane failures visible until the operator acknowledges them.
# Only the entry shell holds the terminal; command substitutions, background
# owners, noninteractive callers and successful exits retain ordinary semantics.
entry_failure_hold() {
  local rc=$1
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$$:$BASH_SUBSHELL" = "$ENTRY_SHELL" ] && [ -t 0 ] && [ -t 2 ]; then
    printf '\nFirstMate launch failed (status %s). Press Enter to close... ' "$rc" >&2
    read -r _ || true
  fi
  exit "$rc"
}
if [ -z "${FM_ENTRY_LIB:-}" ]; then
  case "$MODE" in
    console-launch|console-run)
      ENTRY_SHELL=$$:$BASH_SUBSHELL
      trap 'entry_failure_hold "$?"' EXIT ;;
  esac
fi

# --- tool profile, inline fallback (internal; owner is upstream bin/fm-tool-profile.sh) ---
# Runs in the ASKING shell and reports that shell's own NM_HOME and PATH as
# found at entry, before this file re-exports them below, so a login shell
# that re-prepended ~/.local/bin is reported as exactly that. Covers the two
# facts the audit found missing (actionlint at the lint pin, a node that
# executes a .ts file) until the pinned code root carries the owner script.
if [ "$MODE" = tool-profile-inline ]; then
  rc=0
  printf 'fm-tool-profile(inline): NM_HOME=%s PATH[0]=%s\n' "${NM_HOME:-<unset>}" "${PATH%%:*}"
  [ "${NM_HOME:-}" = "$FM_HOME/no-mistakes" ] || { echo "ENVIRONMENT_UNREADY: profile PROFILE_MISMATCH (NM_HOME is ${NM_HOME:-<unset>}, expected $FM_HOME/no-mistakes); owner: this launcher's exports"; rc=1; }
  [ "${PATH%%:*}" = "$FM_TOOLS" ] || { echo "ENVIRONMENT_UNREADY: profile PROFILE_MISMATCH (PATH[0] is ${PATH%%:*}, expected $FM_TOOLS); owner: this launcher's exports, re-selected after any login-shell initialization"; rc=1; }
  want=$(sed -nE 's/^REQUIRED_ACTIONLINT=([0-9.]+)$/\1/p' "$FM_CODE_ROOT/bin/fm-lint-workflows.sh" 2>/dev/null | head -1)
  have=$(actionlint -version 2>/dev/null </dev/null | head -1 || true)
  if [ -z "$have" ]; then echo "ENVIRONMENT_UNREADY: actionlint ABSENT; owner: $FM_CODE_ROOT/bin/fm-install-actionlint.sh $FM_TOOLS (installs actionlint ${want:-?} into the clean-room tools surface)"; rc=1
  elif [ -n "$want" ] && [ "$have" != "$want" ]; then echo "ENVIRONMENT_UNREADY: actionlint PINNED_MISMATCH (found $have, pinned $want); owner: $FM_CODE_ROOT/bin/fm-install-actionlint.sh $FM_TOOLS"; rc=1
  else echo "QUALIFIED actionlint $have $(command -v actionlint)"; fi
  tsdir=$(mktemp -d) && printf 'const a: number = 41;\nconsole.log("ts-ok", a + 1);\n' > "$tsdir/probe.ts"
  if [ "$(cd "$tsdir" && node ./probe.ts 2>/dev/null </dev/null)" = "ts-ok 42" ]; then echo "QUALIFIED node-ts $(node --version) $(command -v node)"
  else echo "ENVIRONMENT_UNREADY: node-ts CAPABILITY_MISSING ($(command -v node || echo no-node) $(node --version 2>/dev/null) process.features.typescript=$(node -p 'String(process.features.typescript)' 2>/dev/null)); owner: pin an official Node release (23.6 or newer executes .ts unflagged) into the clean-room tools surface ahead of the distro node (tools/pin-axi-tools.sh, never a host-global install)"; rc=1; fi
  rm -rf "$tsdir"
  exit "$rc"
fi

# --- Cold-start supervision arm: pure decisions -------------------------------
# Tested by enter-firstmate-arm.test.sh (FM_ENTRY_LIB=1 loads only this block).
# Every input is a plain token, so the decision itself reads no state.
#
# cold_arm_decide <needed> <afk> <writable> <foreign_live_lock> <claim_open>
#   needed            true|false  fm_supervision_needed on this home's state dir
#   afk               0|1         state/.afk present: the away daemon owns supervision
#   writable          0|1         state/ accepts a new file (lock, beacon, ledger, log)
#   foreign_live_lock 0|1         state/.lock names a LIVE verified harness pid, i.e.
#                                 another session of this home is running and its own
#                                 between-turn arm owns the watcher
#   claim_open        0|1         fm_autoarm_claim_open: a live owner already holds the
#                                 current auto-arm generation and delivers its close
# Prints exactly one verb: skip-not-needed | skip-afk | refuse-state-unwritable |
# defer-live-session | defer-open-claim | arm. "arm" also covers a healthy watcher
# with no live generation owner: bin/fm-watch-arm.sh attaches rather than starting
# a second watcher, and the owner then delivers that cycle's close.
cold_arm_decide() {
  local needed=${1:-false} afk=${2:-0} writable=${3:-0} foreign=${4:-0} claim_open=${5:-0}
  [ "$needed" = true ] || { echo skip-not-needed; return 0; }
  [ "$afk" = 0 ] || { echo skip-afk; return 0; }
  [ "$writable" = 1 ] || { echo refuse-state-unwritable; return 0; }
  [ "$foreign" = 0 ] || { echo defer-live-session; return 0; }
  [ "$claim_open" = 0 ] || { echo defer-open-claim; return 0; }
  echo arm
}

# cold_arm_arm_line <file>: classify the owner's handoff file by the LAST
# `watcher:` line bin/fm-watch-arm.sh printed: started | attached | failed | none.
cold_arm_arm_line() {
  local line
  line=$(grep -E '^watcher: (started|attached|FAILED)' "$1" 2>/dev/null | tail -1 || true)
  case "$line" in
    'watcher: started'*) echo started ;;
    'watcher: attached'*) echo attached ;;
    'watcher: FAILED'*) echo failed ;;
    *) echo none ;;
  esac
}

# cold_arm_reasons <file>: the actionable reason lines a closed cycle printed -
# the exact class bin/fm-claude-stop-autoarm.sh translates - at most 8.
cold_arm_reasons() {
  grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$1" 2>/dev/null | head -8 || true
}

# cold_arm_wake_body <reason-lines>: the single-line body of the `watcher`-kind
# operational input. Newlines collapse to " | " exactly as the away daemon
# collapses its digests, so one Enter submits it. Text mirrors the Stop hook's
# rewake banner and says who owns continuity from here on.
cold_arm_wake_body() {
  local reasons=$1
  reasons=${reasons//$'\n'/ | }
  printf '%s %s %s' \
    'firstmate watcher wake - one supervision event needs a handling turn now.' \
    "$reasons" \
    "Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. This wake was captured by the console launcher's cold-start supervision arm before your first turn; from your first turn on the Stop hook owns watcher continuity - do NOT run bin/fm-watch-arm.sh after an ordinary wake."
}

# --- Harness permission policy (control issue #7 ruling 3): pure table ----------
# Tested by enter-firstmate-launch.test.sh (FM_ENTRY_LIB=1 loads this block).
# The clean-room's ONE permission-policy owner. claude's primary posture is
# owned here and composed into the console argv; each worker harness's posture
# names the upstream spawn compiler's own launch-template token so the doctor
# can prove it is still present in <code-root>/bin/fm-spawn.sh.
permission_policy_state() {  # <harness> -> QUALIFIED | NOT_APPLICABLE | CNO
  case "${1:-}" in
    claude|codex|opencode|grok|kimi|cursor|muse) echo QUALIFIED ;;
    pi|pi-signed) echo CNO ;;
    bash) echo NOT_APPLICABLE ;;
    *) echo CNO ;;
  esac
}
permission_policy_posture() {  # <harness> -> the flag/config that removes interactive approval, or a reason
  case "${1:-}" in
    claude) echo '--dangerously-skip-permissions' ;;
    codex) echo '--dangerously-bypass-approvals-and-sandbox' ;;
    opencode) echo 'OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow"}}' ;;
    grok) echo '--always-approve' ;;
    kimi) echo '--auto' ;;
    cursor) echo '--trust --yolo' ;;
    muse) echo '--yolo' ;;
    pi|pi-signed) echo 'none: the upstream spawn template passes no permission flag and a separate pi approval gate is not documented; not invented' ;;
    bash) echo 'none: evidence harness without an approval gate' ;;
    *) echo 'none: not a verified harness' ;;
  esac
}
permission_policy_owner() {  # <harness>
  case "${1:-}" in
    claude) echo 'this launcher (primary console argv) + fm-spawn (workers)' ;;
    codex|opencode|grok|kimi|cursor|muse) echo 'fm-spawn (workers and secondmates)' ;;
    *) echo none ;;
  esac
}
permission_policy_spawn_token() {  # <harness> -> exact bytes expected in bin/fm-spawn.sh's launch template ('' = none)
  case "${1:-}" in
    claude) echo 'claude --dangerously-skip-permissions' ;;
    codex) echo '--dangerously-bypass-approvals-and-sandbox' ;;
    opencode) echo '{"permission":{"*":"allow"}}' ;;
    grok) echo 'grok --always-approve' ;;
    kimi) echo '__KIMIBIN__ __MODELFLAG__--auto' ;;
    cursor) echo '__CURSORBIN__ --trust --yolo' ;;
    muse) echo '__MUSEBIN__ --yolo' ;;
    *) echo '' ;;
  esac
}
permission_policy_harnesses() { echo 'claude codex opencode pi pi-signed grok kimi cursor muse'; }

# --- Primary console profile menu (runtime-pin-adoption-gap, slice 1) ----------
# Tested by enter-firstmate-profile.test.sh (FM_ENTRY_LIB=1 loads this block).
# The primary console's four-profile menu selects ONLY the primary console's
# harness + model + permission posture. Worker and pipeline model profiles are
# SEPARATE owners (the code root's bin/fm-spawn.sh and config/crew-dispatch.json)
# and are never switched from here. Invariants held at every profile:
#   * fable-5.1 is the default and the only profile qualified out of the box.
#   * An unqualified profile is PENDING with its exact gate and is NEVER
#     silently substituted for another; console_run refuses rather than launch.
#   * $0 / subscription-only is enforced at the composed-launch boundary
#     (console_argv_subscription_only): no API/gateway/provider override, no paid
#     overage, and no invented budget flag is ever composed or accepted.
console_profile_default() { printf 'fable-5.1'; }
console_profile_menu()    { printf 'fable-5.1 opus-4-8 codex-astra codex-sol'; }
console_profile_harness() {  # <profile> -> claude | codex | ''
  case "${1:-}" in
    fable-5.1|opus-4-8)    printf claude ;;
    codex-astra|codex-sol) printf codex ;;
    *) printf '' ;;
  esac
}
# The exact model selector composed onto the harness. Pinned per profile and not
# overridable, so the Opus-4.8 profile can never resolve to Opus 5.
console_profile_model() {  # <profile> -> selector | ''
  case "${1:-}" in
    fable-5.1)   printf fable ;;
    opus-4-8)    printf claude-opus-4-8 ;;
    codex-astra) printf gpt-6-astra ;;
    codex-sol)   printf gpt-5.6-sol ;;
    *) printf '' ;;
  esac
}
# Defensive invariant for the Opus-4.8-only profile: refuse if its selector ever
# reads as anything but the pinned 4.8 id (an Opus 5 id is rejected outright).
console_profile_model_ok() {  # <profile> <model> -> 0 ok / 1 refuse
  case "${1:-}" in
    opus-4-8) case "${2:-}" in claude-opus-4-8) return 0 ;; *) return 1 ;; esac ;;
  esac
  return 0
}
# console_profile_qualify <profile> <harness-installed 0|1> <model-allowed 0|1>
# -> QUALIFIED | PENDING: <exact gate>.  Pure: the caller gathers the two facts.
console_profile_qualify() {
  local p=${1:-} installed=${2:-0} allowed=${3:-0} h m
  h=$(console_profile_harness "$p")
  m=$(console_profile_model "$p")
  [ -n "$h" ] || { printf 'PENDING: %s is not a known profile' "$p"; return 0; }
  console_profile_model_ok "$p" "$m" || { printf 'PENDING: %s resolved model %s is not the pinned Opus 4.8 id; refusing' "$p" "$m"; return 0; }
  [ "$installed" = 1 ] || { printf 'PENDING: harness %s is not installed' "$h"; return 0; }
  [ "$allowed" = 1 ]   || { printf 'PENDING: model %s (%s) is not yet qualified on the zero-dollar subscription plan; adoption pending' "$m" "$h"; return 0; }
  printf 'QUALIFIED'
}
# The set of profiles this home has qualified for the zero-dollar subscription
# plan. Absent config leaves only the default profile qualified; the others stay
# PENDING until a later adoption slice qualifies them live. Reads config, so its
# result depends on $FM_HOME.
console_profile_qualified_set() {  # a space/newline-separated LIST (not a scalar)
  local f="$FM_HOME/config/console-qualified-profiles" s=''
  if [ -f "$f" ]; then
    s=$(tr '[:space:]' ' ' < "$f" | tr -s ' ')
    s=${s# }; s=${s% }
  fi
  [ -n "$s" ] || s=$(console_profile_default)
  printf '%s' "$s"
}
# The live gate for one profile: gathers the two facts console_profile_qualify
# needs (is the harness installed, is the profile in the qualified set) and
# returns its verdict. Not pure: reads the PATH and config.
console_profile_gate() {  # <profile> -> QUALIFIED | PENDING: <gate>
  local p=$1 h installed=0 allowed=0
  h=$(console_profile_harness "$p")
  [ -n "$h" ] && command -v "$h" >/dev/null 2>&1 && installed=1
  case " $(console_profile_qualified_set) " in *" $p "*) allowed=1 ;; esac
  console_profile_qualify "$p" "$installed" "$allowed"
}
# Sole owner of the four-profile primary console menu layout: heading, the active
# and default markers, the qualified set, the $0/subscription note, and every
# profile's harness, pinned model, permission posture and gate verdict. Called by
# both --doctor and --print-console-menu so the two never drift. Reads only
# FM_CONSOLE_PROFILE/FM_HARNESS_ENV and the pure profile/permission functions;
# starts nothing and needs no tools or code root.
console_profile_menu_render() {
  local _p _h _m _g
  echo "-- primary console profile menu (runtime-pin-adoption-gap; owner: this launcher's console_profile_* block)"
  echo "  active profile:    $FM_CONSOLE_PROFILE$( [ -n "$FM_HARNESS_ENV" ] && printf ' (overridden by FM_HARNESS=%s; menu bypassed)' "$FM_HARNESS_ENV")"
  echo "  default profile:   $(console_profile_default)   qualified here: $(console_profile_qualified_set)"
  echo "  \$0/subscription:   enforced at the composed launch (no API/gateway/provider override, no overage, no budget flag)"
  for _p in $(console_profile_menu); do
    _h=$(console_profile_harness "$_p"); _m=$(console_profile_model "$_p"); _g=$(console_profile_gate "$_p")
    printf '  %-12s harness=%-6s model=%-16s posture=%-40s %s%s\n' "$_p" "$_h" "$_m" "$(permission_policy_posture "$_h")" "$_g" "$( [ "$_p" = "$FM_CONSOLE_PROFILE" ] && printf '  <- active')"
  done
  echo "  note:              worker/pipeline model profiles are separate owners (code root bin/fm-spawn.sh, config/crew-dispatch.json); this menu never switches workers"
}
# The composed primary-console argv must never carry a paid, gateway, provider,
# or budget selector: $0/subscription-only means the harness's own subscription
# login, never an API key, base-url override, or an invented overage budget.
console_argv_subscription_only() {  # <argv...> -> 0 clean / 1 refuse (prints token)
  local a
  for a in "$@"; do
    case "$a" in
      --max-budget|--max-budget=*|--budget|--budget=*|\
      --api-key|--api-key=*|--anthropic-api-key*|--openai-api-key*|\
      --base-url|--base-url=*|--api-base|--api-base=*|--gateway|--gateway=*|--provider|--provider=*)
        printf '%s' "$a"; return 1 ;;
    esac
  done
  return 0
}
# doctor helper (extracted from an inline $(case ... esac) that stock macOS Bash
# 3.2 cannot parse inside a command substitution): is the clean-room tools
# surface first on PATH?
doctor_tools_first() {  # <path> <fm-tools> -> "yes (<fm-tools>)" | "NO - REFUSE"
  case "$1" in
    "$2":*) echo "yes ($2)" ;;
    *) echo "NO - REFUSE" ;;
  esac
}
# Same reason: these keep a `case` out of a $(...) command substitution so stock
# macOS Bash 3.2 can parse the doctor block. Read the resolved globals directly.
doctor_fm_home_leak() {  # -> YES-REFUSE | none | none (no retired home configured)
  [ -n "$FM_RETIRED_HOME" ] || { echo 'none (no retired home configured)'; return; }
  case "$FM_HOME/" in "$FM_RETIRED_HOME"/*) echo YES-REFUSE ;; *) echo none ;; esac
}
doctor_path_leak() {  # -> "YES - <dir> is on PATH" | none | none (no retired home configured)
  [ -n "$FM_RETIRED_HOME" ] || { echo 'none (no retired home configured)'; return; }
  case ":$PATH:" in *":$FM_RETIRED_HOME/bin:"*) echo "YES - $FM_RETIRED_HOME/bin is on PATH" ;; *) echo none ;; esac
}

# --- Console launch contract (control issue #8 REVISE 2): pure decisions --------
# console_harness_argv <harness> <model|""> <settings-file|""> <resume-id|""> [passthrough...]
# prints the console argv one element per line. A profile harness (claude, codex)
# leads with its captain-authorized permission posture, then the pinned profile
# model selector, then (claude only) the private style settings and the validated
# resume target, then the captain's own arguments. bash (the evidence harness)
# and any non-profile harness get only the passthrough.
console_harness_argv() {
  local harness=$1 model=$2 settings=$3 resume=$4
  shift 4
  case "$harness" in
    claude)
      permission_policy_posture claude
      [ -z "$model" ]    || printf '%s\n%s\n' --model "$model"
      [ -z "$settings" ] || printf '%s\n%s\n' --settings "$settings"
      [ -z "$resume" ]   || printf '%s\n%s\n' --resume "$resume"
      ;;
    codex)
      permission_policy_posture codex
      [ -z "$model" ]    || printf '%s\n%s\n' --model "$model"
      ;;
  esac
  [ $# -eq 0 ] || printf '%s\n' "$@"
}
# console_resume_id_valid <id>: the only shape ever passed to --resume.
console_resume_id_valid() {
  case "${1:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
  esac
  return 1
}
# console_session_store_dir <claude-config-dir> <cwd>: Claude Code's native
# per-project transcript directory (every '/' and '.' of the cwd becomes '-';
# observed: /mnt/e/FirstMate-Cleanroom/upstream/firstmate ->
# ~/.claude/projects/-mnt-e-FirstMate-Cleanroom-upstream-firstmate).
console_session_store_dir() {
  local enc
  enc=$(printf '%s' "$2" | sed 's#[/.]#-#g')
  printf '%s/projects/%s' "$1" "$enc"
}
# console_resume_candidate <claude-config-dir> <cwd> <id> -> valid | invalid-id | no-transcript
console_resume_candidate() {
  local f
  console_resume_id_valid "$3" || { echo invalid-id; return 0; }
  f="$(console_session_store_dir "$1" "$2")/$3.jsonl"
  if [ -s "$f" ]; then echo valid; else echo no-transcript; fi
}
# console_launch_outcome <resume-attempted 0|1> <rc> <elapsed-s> <window-s>
# -> fallback-fresh (exactly the stale-resume shape) | exited (everything else,
# including a failed fresh launch: there is no second fallback, ever).
console_launch_outcome() {
  local attempted=${1:-0} rc=${2:-0} elapsed=${3:-0} window=${4:-20}
  if [ "$attempted" = 1 ] && [ "$rc" != 0 ] && [ "$elapsed" -lt "$window" ]; then echo fallback-fresh; else echo exited; fi
}
# console_pane_classify <fg-name> <fg-pid> <fg-ppid> <console-pid> <console-pid-alive 0|1> <harness-name>
# -> canonical | starting | foreign-harness | shell | other
#   canonical       the harness runs as the recorded --console shell's child (or is that pid)
#   starting        the recorded --console shell itself is in the foreground (arming, probing)
#   foreign-harness the harness runs but this launcher did not start it (Herdr restore, a hand-typed harness)
#   shell           a recognized shell is in the foreground (a stranded pane); the caller still requires the upstream idle proof
#   other           anything else: never typed into
console_pane_classify() {
  local name=${1:-} pid=${2:-0} ppid=${3:-0} cpid=${4:-0} alive=${5:-0} harness=${6:-claude}
  name=${name##*/}
  if [ "$alive" = 1 ] && [ "$cpid" != 0 ] && [ "$pid" = "$cpid" ]; then
    if [ "$name" = "$harness" ]; then echo canonical; else echo starting; fi
    return 0
  fi
  if [ "$name" = "$harness" ]; then
    if [ "$alive" = 1 ] && [ "$cpid" != 0 ] && [ "$ppid" = "$cpid" ]; then echo canonical; else echo foreign-harness; fi
    return 0
  fi
  case "$name" in sh|bash|zsh|dash|ksh|fish) echo shell ;; *) echo other ;; esac
}
# console_converge_plan <session-started-now 0|1> -> inline | deferred
# A server this launch started restores the console pane's terminal only when
# the TUI attaches, after the launch path's last step, so its convergence runs
# in the detached post-attach owner; a running server has a readable pane now.
console_converge_plan() { if [ "${1:-0}" = 1 ]; then echo deferred; else echo inline; fi; }
# console_converge_action <class> <session-started-now 0|1> <composer> <resume-id>
# -> reuse | restart | converge | leave
console_converge_action() {
  local cls=${1:-other} started=${2:-0} composer=${3:-unknown} sid=${4:-}
  case "$cls" in
    canonical|starting) echo reuse ;;
    shell) echo restart ;;
    foreign-harness) if [ "$started" = 1 ] && [ "$composer" = empty ] && [ -n "$sid" ]; then echo converge; else echo leave; fi ;;
    *) echo leave ;;
  esac
}

# cold_arm_claim_deliverable <owner-kind>: can the open auto-arm claim deliver a
# captured wake to a freshly (re)launched, turn-idle console? Only a LIVE
# cold-start arm-owner types its close into the composer (deliverable). A live
# Stop-hook auto-arm delivers only by exit-2 rewake into its own harness, which a
# cold-start relaunch has replaced; a dead/foreign/unknown owner cannot deliver
# either. <owner-kind> is the probe's ledger_owner_kind token:
#   cold-start  a live process whose argv contains --arm-owner (this launcher's owner)
#   stop-hook   a live bin/fm-claude-stop-autoarm.sh (exit-2 rewake owner)
#   other       a live process that is neither
#   gone        the owner pid is not alive
cold_arm_claim_deliverable() {
  case "${1:-}" in
    cold-start) echo deliverable ;;
    *) echo stale ;;
  esac
}

# cold_arm_supersede_stale <gen> <owner-pid>: flip an open (outcome=arming) claim
# that this launcher has proven stale-for-this-console to outcome=superseded,
# under the SAME micro-mutex and epoch format bin/fm-wake-lib.sh uses, and ONLY
# while the ledger still names exactly <gen>/<owner-pid> arming. That makes
# fm_autoarm_claim_open false so the launcher's own owner can claim gen+1; the
# orphan owner's fm_autoarm_still_owner then returns false and it stands down at
# its next close instead of an exit-2 rewake to a dead harness. Prints
# superseded | not-open | contended.
cold_arm_supersede_stale() {  # <gen> <owner-pid>
  FM_HOME="$FM_HOME" bash -c '
    set +e
    root=$1 gen=$2 owner=$3
    . "$root/bin/fm-wake-lib.sh" >/dev/null 2>&1 || { echo contended; exit 1; }
    state="$FM_HOME/state"; lock="$state/.claude-autoarm.lock"; epoch="$state/.claude-autoarm-epoch"
    fm_lock_try_acquire "$lock" || { echo contended; exit 1; }
    if fm_autoarm_ledger_read "$state"       && [ "$FM_AUTOARM_GEN" = "$gen" ] && [ "$FM_AUTOARM_OWNER" = "$owner" ] && [ "$FM_AUTOARM_OUTCOME" = arming ]; then
      tmp="$epoch.supersede.$$"
      if { printf "epoch=%s owner_pid=%s outcome=superseded updated_at=%s\n" "$gen" "$owner" "$(date +%s)";            [ -z "$FM_AUTOARM_IDENTITY" ] || printf "%s\n" "$FM_AUTOARM_IDENTITY"; } > "$tmp" 2>/dev/null          && mv -f "$tmp" "$epoch" 2>/dev/null; then out=superseded; else rm -f "$tmp" 2>/dev/null; out=contended; fi
    else
      out=not-open
    fi
    fm_lock_release "$lock"
    echo "$out"
  ' _ "$FM_CODE_ROOT" "$1" "$2"
}

# Library load for the test file beside this launcher: only the pure functions
# above exist, nothing below runs.
# shellcheck disable=SC2317 # `return` serves a sourced load; `exit` covers a direct run.
if [ -n "${FM_ENTRY_LIB:-}" ]; then return 0 2>/dev/null || exit 0; fi

# --- Internal: render the profile menu and exit -------------------------------
# Renders ONLY the four-profile console menu and exits, before every mandatory
# environment gate (code/tools root, backend, herdr session, tools surface,
# no-mistakes). It resolves the active profile exactly as the launch path does,
# then defers to the single menu owner. It starts, execs and installs nothing and
# needs no usable tools root, so staging can qualify the composed menu offline.
if [ "$MODE" = print-console-menu ]; then
  FM_CONSOLE_PROFILE=${FM_CONSOLE_PROFILE:-$(read_scalar console-profile || true)}
  [ -n "$FM_CONSOLE_PROFILE" ] || FM_CONSOLE_PROFILE=$(console_profile_default)
  console_profile_menu_render
  exit 0
fi

# --- Home and code root -----------------------------------------------------
# Required host paths are enforced here, past the FM_ENTRY_LIB return, so the
# pure-function tests can source this file with nothing configured.
[ -n "$FM_CODE_ROOT" ]  || die "code root is unset: pass FM_CODE_ROOT or write $FM_HOME/config/code-root (the ADOPTED clean-room release, never the Windows shortcut's donor --cd cwd)"
[ -n "$FM_TOOLS_ROOT" ] || die "tools root is unset: pass FM_TOOLS_ROOT or write $FM_HOME/config/tools-root"
[ -d "$FM_CODE_ROOT/bin" ] || die "code root missing: $FM_CODE_ROOT"
[ -d "$FM_HOME" ]          || die "runtime home missing: $FM_HOME"
[ -z "$FM_RETIRED_HOME" ] || case "$FM_HOME/" in "$FM_RETIRED_HOME"/*) die "refusing to run against the other live FirstMate home: $FM_HOME" ;; esac
[ -z "$FM_RETIRED_HOME" ] || case "$FM_CODE_ROOT/" in "$FM_RETIRED_HOME"/*) die "refusing the other live FirstMate installation's code root: $FM_CODE_ROOT" ;; esac
export FM_HOME

FM_BACKEND_CONFIGURED=$(read_scalar backend || true)
[ -n "$FM_BACKEND_CONFIGURED" ] || die "config/backend is missing or empty; this environment must pin a backend rather than fall through to runtime auto-detection"
[ "$FM_BACKEND_CONFIGURED" = herdr ] || die "config/backend is '$FM_BACKEND_CONFIGURED'; the clean-room isolation contract is the named Herdr session, so only 'herdr' is launchable from here"

FM_HERDR_SESSION=$(read_scalar herdr-session || true)
[ -n "$FM_HERDR_SESSION" ] || die "config/herdr-session is missing or empty; refusing to start, because an unset session would place this environment's workers in Herdr's shared 'default' session alongside the other live FirstMate home"
[ "$FM_HERDR_SESSION" != default ] || die "config/herdr-session is 'default'; that is the other live FirstMate home's session"
case "$FM_HERDR_SESSION" in
  [A-Za-z0-9]*) ;;
  *) die "config/herdr-session is not a usable Herdr session name: $FM_HERDR_SESSION" ;;
esac
case "$FM_HERDR_SESSION" in
  *[!A-Za-z0-9._-]*) die "config/herdr-session contains characters Herdr does not accept in a session name: $FM_HERDR_SESSION" ;;
esac

# --- Tool PATH --------------------------------------------------------------
# ORDER IS LOAD-BEARING and asserted below. The private bin dir is added FIRST
# (a non-login WSL shell, which is what the Desktop shortcut opens, does not
# carry it), and the clean-room tools dir is prepended LAST so it is
# unconditionally PATH[0]. Measured 2026-09-02 through wsl.exe: the inverted
# order resolved `no-mistakes` to the host-wide v1.40.3 instead of the
# clean-room's pinned v1.61.0.
[ ! -d "$HOME/.local/bin" ] || export PATH="$HOME/.local/bin:$PATH"
[ -d "$FM_TOOLS" ] || die "clean-room tools surface missing: $FM_TOOLS"
export PATH="$FM_TOOLS:$PATH"
case "$PATH" in
  "$FM_TOOLS":*) ;;
  *) die "clean-room tools are not first on PATH (PATH starts '${PATH%%:*}'); refusing rather than running the host-wide tools" ;;
esac

# --- Primary console profile resolution (runtime) ------------------------------
# The four-profile menu (console_profile_* above) drives the primary console's
# harness + model. A non-native FM_HARNESS override (evidence runs) skips it. The
# selected profile is refused, never silently swapped, when it is not QUALIFIED;
# --doctor shows every profile's gate and starts nothing.
FM_CONSOLE_PROFILE=${FM_CONSOLE_PROFILE:-$(read_scalar console-profile || true)}
[ -n "$FM_CONSOLE_PROFILE" ] || FM_CONSOLE_PROFILE=$(console_profile_default)
# A Herdr pane inherits the selected native harness from the outer launcher.
# Re-resolve its model and gate here; that inherited value is not an evidence override.
if [ -z "$FM_HARNESS_ENV" ] || [ "$FM_HARNESS_ENV" = codex ] || [ "$FM_HARNESS_ENV" = claude ]; then
  h=$(console_profile_harness "$FM_CONSOLE_PROFILE")
  [ -n "$h" ] || die "config/console-profile names an unknown profile '$FM_CONSOLE_PROFILE'; known profiles: $(console_profile_menu)"
  [ -z "$FM_HARNESS_ENV" ] || [ "$FM_HARNESS_ENV" = "$h" ] || die "native harness $FM_HARNESS_ENV conflicts with selected profile $FM_CONSOLE_PROFILE; select the matching profile explicitly"
  FM_HARNESS=$h
  FM_CONSOLE_MODEL=$(console_profile_model "$FM_CONSOLE_PROFILE")
  # Refuse a non-qualified profile rather than starting a console under it or
  # silently substituting the default; --doctor is exempt so it can report gates.
  case "$MODE" in
    console-launch|console-run|arm-owner|converge-owner)
      gate=$(console_profile_gate "$FM_CONSOLE_PROFILE")
      case "$gate" in
        QUALIFIED) ;;
        *) die "primary console profile '$FM_CONSOLE_PROFILE' is $gate. Refusing to start (a profile is never silently replaced with another). The default profile is $(console_profile_default); qualify this profile or select a qualified one via FM_CONSOLE_PROFILE or config/console-profile, and read --doctor for the full menu." ;;
      esac ;;
  esac
fi

export FM_CONSOLE_PROFILE

# --- Console record and launch log (this home's own console identity) -------------
CONSOLE_RECORD=$FM_HOME/state/captain-console.json
CONSOLE_LOG=$FM_HOME/state/console-launch.log
CONSOLE_RESUME_WINDOW=${FM_ENTRY_RESUME_WINDOW:-20}
CONSOLE_RESTORE_SETTLE=${FM_ENTRY_RESTORE_SETTLE:-12}
CONSOLE_EXIT_WAIT=${FM_ENTRY_EXIT_WAIT:-90}
CONSOLE_ATTACH_WAIT=${FM_ENTRY_ATTACH_WAIT:-120}
CONSOLE_COMPOSER_WAIT=${FM_ENTRY_COMPOSER_WAIT:-60}
case "$CONSOLE_RESUME_WINDOW" in ''|*[!0-9]*) CONSOLE_RESUME_WINDOW=20 ;; esac
case "$CONSOLE_RESTORE_SETTLE" in ''|*[!0-9]*) CONSOLE_RESTORE_SETTLE=12 ;; esac
case "$CONSOLE_EXIT_WAIT" in ''|*[!0-9]*) CONSOLE_EXIT_WAIT=90 ;; esac
case "$CONSOLE_ATTACH_WAIT" in ''|*[!0-9]*) CONSOLE_ATTACH_WAIT=120 ;; esac
case "$CONSOLE_COMPOSER_WAIT" in ''|*[!0-9]*) CONSOLE_COMPOSER_WAIT=60 ;; esac
console_log() { printf '%s pid=%s %s\n' "$(date -u +%FT%TZ)" "$$" "$*" 2>/dev/null >> "$CONSOLE_LOG" || true; }
console_record_field() { jq -r --arg k "$1" '.[$k] // empty' "$CONSOLE_RECORD" 2>/dev/null || true; }
# console_record_update <json-object>: merge launch fields into the record, only
# when it names the pane this --console runs in (a hand-run --console in some
# other pane never becomes the captain's console by writing here).
console_record_update() {
  local tmp
  [ -f "$CONSOLE_RECORD" ] || return 1
  [ "$(console_record_field pane_id)" = "${HERDR_PANE_ID:-}" ] || return 1
  [ "$(console_record_field session)" = "$FM_HERDR_SESSION" ] || return 1
  tmp=$(mktemp "$FM_HOME/state/.captain-console.XXXXXX") || return 1
  if jq --argjson add "$1" '. + $add' "$CONSOLE_RECORD" > "$tmp" 2>/dev/null; then mv "$tmp" "$CONSOLE_RECORD"; else rm -f "$tmp"; return 1; fi
}

# --- Herdr ancestry -----------------------------------------------------------
# Herdr injects HERDR_ENV/HERDR_PANE_ID/HERDR_SOCKET_PATH/HERDR_TAB_ID/
# HERDR_WORKSPACE_ID into every process it manages a pane for, and the upstream
# adapter reads them as the launcher's PARENT workspace
# (fm_backend_herdr_launcher_identity). Started from the Desktop shortcut there
# are none. Started from INSIDE a pane of the other live installation's session
# they name a workspace on ANOTHER Herdr server: that ancestry is DROPPED here
# so the launch proceeds as an outside launch into the clean-room session
# instead of adopting the legacy one (watched-red: launcher-from-foreign-pane).
# An ancestry already inside the configured clean-room session is kept, which is
# exactly the --console case, where the harness must see its own pane so workers
# appear beside the captain.
FM_HERDR_ANCESTRY=kept
if [ -n "${HERDR_PANE_ID:-}" ] && [ "${HERDR_SESSION:-}" != "$FM_HERDR_SESSION" ]; then
  FM_HERDR_ANCESTRY="dropped (pane ${HERDR_PANE_ID} of session '${HERDR_SESSION:-<unnamed>}')"
  unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
elif [ -z "${HERDR_PANE_ID:-}" ]; then
  FM_HERDR_ANCESTRY="none (started outside Herdr)"
fi
export HERDR_SESSION="$FM_HERDR_SESSION"
if [ "$MODE" = console-run ]; then
  [ -n "${HERDR_PANE_ID:-}" ] || die "--console must run inside a pane of the clean-room Herdr session '$FM_HERDR_SESSION'; it was started with no Herdr ancestry"
  [ "$FM_HERDR_ANCESTRY" = kept ] || die "--console refuses a foreign Herdr ancestry: $FM_HERDR_ANCESTRY"
  # Claim the console record FIRST, before the identity probes below take their
  # seconds, so the Desktop launch classifies this pane as `starting` (never as
  # a stranded shell) from the moment the contract is running here.
  if console_record_update "$(jq -n --arg pid "$$" --arg t "$(date -u +%FT%TZ)" --arg profile "$FM_CONSOLE_PROFILE" --arg model "$FM_CONSOLE_MODEL" '{profile:$profile, model:$model, console_pid:($pid|tonumber), launch_stage:"starting", started_at:$t, launch_mode:"", resume_id:"", exit_rc:null}')"; then
    console_log "console: starting in pane $HERDR_PANE_ID (record claimed)"
  else
    console_log "console: starting in pane $HERDR_PANE_ID but the console record names another pane or is absent; launch fields not recorded"
  fi
fi

# --- no-mistakes isolation -----------------------------------------------------
export NM_HOME="$FM_HOME/no-mistakes"
nm_root_canonical() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }
[ "$(nm_root_canonical "$NM_HOME")" != "$(nm_root_canonical "$NM_SHARED_ROOT")" ] \
  || die "NM_HOME resolves to the shared legacy no-mistakes root ($NM_SHARED_ROOT); refusing to start a console that would drive the live fleet's daemon"
mkdir -p "$NM_HOME" && chmod 700 "$NM_HOME" 2>/dev/null || true
NM_BIN=$(command -v no-mistakes 2>/dev/null || true)
case "$NM_BIN" in
  "$FM_TOOLS"/*) ;;
  *) die "no-mistakes resolves to '${NM_BIN:-<none>}', not the clean-room pinned client under $FM_TOOLS; refusing" ;;
esac
nm_client_state() {  # prints QUALIFIED|PRESENT_BELOW_FLOOR|ABSENT for no-mistakes, from the projected policy
  "$FM_TOOLS_ROOT/tool-policy.sh" --code-root "$FM_CODE_ROOT" --json 2>/dev/null \
    | jq -r '.tools[] | select(.tool=="no-mistakes") | .state' 2>/dev/null || echo COULD-NOT-OBSERVE
}
NM_STATE=$(nm_client_state)
[ "$NM_STATE" = QUALIFIED ] || die "no-mistakes client is $NM_STATE against the upstream floor; refusing (repair: $FM_TOOLS_ROOT/pin-axi-tools.sh or re-pin tools/bin/no-mistakes)"
nm_daemon_running() { no-mistakes daemon status 2>/dev/null | grep -q 'daemon running'; }
nm_daemon_pid() { jq -r '.pid // empty' "$NM_HOME/daemon.pid" 2>/dev/null || true; }
nm_shared_pid() { jq -r '.pid // empty' "$NM_SHARED_ROOT/daemon.pid" 2>/dev/null || true; }

# --- tool profile observation (owner: upstream bin/fm-tool-profile.sh) ---------------
# Runs the observation FROM the shell it is asked about, so a login shell reports
# its own PATH. Prints the owner's rows and ENVIRONMENT_UNREADY lines (stdout and
# stderr merged); exit 0 only when every required tool is QUALIFIED from there.
TOOL_PROFILE_OWNER="$FM_CODE_ROOT/bin/fm-tool-profile.sh"
TOOL_PROFILE_SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
tool_profile_observe() {  # <direct|login>
  local shell=${1:-direct} probe
  if [ -x "$TOOL_PROFILE_OWNER" ]; then
    probe="'$TOOL_PROFILE_OWNER' --expect-nm-home '$NM_HOME' --expect-path0 '$FM_TOOLS' --require shellcheck,actionlint,tasks-axi,no-mistakes,node-ts"
  else
    probe="'$TOOL_PROFILE_SELF' --tool-profile-inline"
  fi
  case "$shell" in
    login) FM_ENTRY_DRY_RUN='' bash -lc "$probe" 2>&1 ;;
    *) FM_ENTRY_DRY_RUN='' bash -c "$probe" 2>&1 ;;
  esac
}

cd "$FM_CODE_ROOT"

# --- Herdr session helpers -------------------------------------------------------
hs() { herdr "$@" --session "$FM_HERDR_SESSION"; }   # every CLI call names the session explicitly (HERDR_SESSION alone is not reliably honored)
session_running() { herdr status --json --session "$FM_HERDR_SESSION" 2>/dev/null | jq -e '.server.running == true' >/dev/null 2>&1; }
session_socket() { hs session list --json 2>/dev/null | jq -r --arg s "$FM_HERDR_SESSION" '[.sessions[]? | select(.name==$s) | .socket_path][0] // empty' 2>/dev/null; }
console_workspaces() {  # workspace ids carrying the console label, one per line
  hs workspace list 2>/dev/null | jq -r --arg l "$FM_CONSOLE_LABEL" '.result.workspaces[]? | select(.label==$l) | .workspace_id' 2>/dev/null
}
SESSION_STARTED_NOW=0   # 1 when THIS launch started the server: Herdr's restore is then in flight
session_env_field() {  # <pid> <VAR> -> the server process's own value of VAR (Linux /proc), or nothing
  tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -1
}
session_server_pid() {  # pid of the running server for THIS session, identified by its own environment
  local pid
  for pid in $(pgrep -f "herdr server --session $FM_HERDR_SESSION" 2>/dev/null); do
    [ "$(session_env_field "$pid" HERDR_SESSION)" = "$FM_HERDR_SESSION" ] || continue
    printf '%s\n' "$pid"; return 0
  done
  return 1
}
assert_session_env() {  # the live server must carry the clean-room NM_HOME and tools-first PATH
  local pid srv_nm srv_path0
  pid=$(session_server_pid) || die "could not identify the running server owner for session $FM_HERDR_SESSION; its environment is unverified; coordinator must restore the named session ownership before launch"
  srv_nm=$(session_env_field "$pid" NM_HOME)
  srv_path0=$(session_env_field "$pid" PATH); srv_path0=${srv_path0%%:*}
  [ "$srv_nm" = "$NM_HOME" ] && [ "$srv_path0" = "$FM_TOOLS" ] && return 0
  die "the running Herdr server for session $FM_HERDR_SESSION (pid $pid) carries NM_HOME='${srv_nm:-<unset>}' PATH[0]='${srv_path0:-<unset>}', not NM_HOME='$NM_HOME' PATH[0]='$FM_TOOLS'; every worker and gate agent it spawns inherits that, so refusing to start a console on it. The server was started from a different environment; the fix is a server restart, which restarts the captain console and is CAPTAIN-GATED - coordinate the timing with the captain, then relaunch"
}
ensure_session() {
  # Structural precondition: the server inherits THIS process's environment for
  # its whole life, so it may only be started once the clean-room identity is in
  # place. Ordering elsewhere in this file is not relied on.
  [ -n "${NM_HOME:-}" ] || die "ensure_session called before NM_HOME was exported; a server started now would hand every worker the shared legacy no-mistakes root"
  case "$PATH" in "$FM_TOOLS":*) ;; *) die "ensure_session called before the clean-room tools were PATH[0] (PATH starts '${PATH%%:*}'); a server started now would hand every worker the host-wide tools" ;; esac
  session_running && return 0
  local log="$FM_HOME/state/herdr-server.log"
  mkdir -p "$FM_HOME/state"
  ( setsid herdr server --session "$FM_HERDR_SESSION" >>"$log" 2>&1 < /dev/null & )
  SESSION_STARTED_NOW=1
  for _ in $(seq 1 30); do
    session_running && return 0
    sleep 0.5
  done
  die "the clean-room Herdr session '$FM_HERDR_SESSION' did not come up within 15s (see $log)"
}
console_absence_proven() {
  local inventory count
  inventory=$(hs workspace list 2>/dev/null) || return 2
  printf '%s' "$inventory" | jq -e '.result.workspaces | type == "array" and all(.[]; (.workspace_id | type == "string" and length > 0))' >/dev/null 2>&1 || return 2
  count=$(printf '%s' "$inventory" | jq --arg label "$FM_CONSOLE_LABEL" '[.result.workspaces[] | select(.label==$label)] | length') || return 2
  [ "$count" = 0 ] || return 2
  return 1
}
# Return 1 only for proven absence; 2 for unreadable/conflicting ownership.
console_record_pane() {
  local ws pane rec_harness inventory count pane_count
  if [ ! -e "$CONSOLE_RECORD" ]; then console_absence_proven; return $?; fi
  if ! jq -e 'type == "object" and (.workspace_id | type == "string" and length > 0)
      and (.pane_id | type == "string" and length > 0)
      and (.session | type == "string" and length > 0)
      and (.harness | type == "string" and length > 0)' "$CONSOLE_RECORD" >/dev/null 2>&1; then
    printf 'enter-firstmate: console ownership record is unreadable or malformed\n' >&2
    return 2
  fi
  ws=$(jq -r '.workspace_id' "$CONSOLE_RECORD"); pane=$(jq -r '.pane_id' "$CONSOLE_RECORD")
  [ "$(jq -r '.session' "$CONSOLE_RECORD")" = "$FM_HERDR_SESSION" ] || return 2
  inventory=$(hs pane list 2>/dev/null) || return 2
  printf '%s' "$inventory" | jq -e '.result.panes | type == "array" and all(.[]; (.pane_id | type == "string" and length > 0) and (.workspace_id | type == "string" and length > 0))' >/dev/null 2>&1 || return 2
  count=$(printf '%s' "$inventory" | jq --arg p "$pane" --arg w "$ws" '[.result.panes[] | select(.pane_id==$p and .workspace_id==$w)] | length') || return 2
  pane_count=$(printf '%s' "$inventory" | jq --arg p "$pane" '[.result.panes[] | select(.pane_id==$p)] | length') || return 2
  [ "$pane_count" = "$count" ] || return 2
  [ "$count" != 0 ] || { console_absence_proven; return $?; }
  [ "$count" = 1 ] || return 2
  rec_harness=$(jq -r '.harness' "$CONSOLE_RECORD")
  if [ "$rec_harness" != "$FM_HARNESS" ]; then
    printf 'enter-firstmate: live console uses %s; supported handover required before selecting %s\n' "$rec_harness" "$FM_HARNESS" >&2
    return 2
  fi
  if [ "$(console_record_field profile)" != "$FM_CONSOLE_PROFILE" ] || [ "$(console_record_field model)" != "$FM_CONSOLE_MODEL" ]; then
    printf 'enter-firstmate: live console profile/model is unknown or differs from selected %s/%s; supported handover required\n' "$FM_CONSOLE_PROFILE" "$FM_CONSOLE_MODEL" >&2
    return 2
  fi
  printf '%s %s\n' "$ws" "$pane"
}
ensure_console_workspace() (  # prints "<workspace-id> <pane-id> created|existing"
  local rec out ws pane others record_rc
  mkdir -p "$FM_HOME/state" || return 2
  command -v flock >/dev/null 2>&1 || { printf 'enter-firstmate: flock required for console ownership\n' >&2; return 2; }
  exec 9>"$FM_HOME/state/console-launch.lock" || return 2
  flock -w 10 9 || { printf 'enter-firstmate: another launcher owns console creation\n' >&2; return 2; }
  trap 'flock -u 9' EXIT
  # The console is identified by THIS HOME'S OWN RECORD, never by the label alone:
  # the upstream adapter also creates a "firstmate"-labeled workspace for a
  # worker spawned from outside Herdr, and a label cannot tell the two apart.
  if rec=$(console_record_pane); then
    case "$(console_converge_plan "$SESSION_STARTED_NOW")" in
      deferred) printf '%s deferred\n' "$rec" ;;   # the launch path starts the post-attach owner
      *) console_converge "${rec% *}" "${rec#* }" || return $? ;;
    esac
    return 0
  else
    record_rc=$?
    [ "$record_rc" = 1 ] || { printf 'enter-firstmate: console ownership unavailable or conflicting; refusing another primary\n' >&2; return "$record_rc"; }
  fi
  # Retain a stale record as handover evidence before replacing its identity.
  if [ -f "$CONSOLE_RECORD" ]; then
    mkdir -p "$FM_HOME/state/console-history" || return 2
    cp -p "$CONSOLE_RECORD" "$FM_HOME/state/console-history/$(date -u +%Y%m%dT%H%M%S)-$$.json" || return 2
  fi
  out=$(hs workspace create --cwd "$FM_CODE_ROOT" --label "$FM_CONSOLE_LABEL" --focus \
        --env "FM_HOME=$FM_HOME" --env "NM_HOME=$NM_HOME" --env "HERDR_SESSION=$FM_HERDR_SESSION" --env "FM_HARNESS=$FM_HARNESS" --env "FM_CONSOLE_PROFILE=$FM_CONSOLE_PROFILE" 2>&1) \
    || die "herdr workspace create failed: $out"
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$ws" ] && [ -n "$pane" ] || die "herdr workspace create returned no workspace/pane id: $out"
  mkdir -p "$FM_HOME/state"
  jq -n --arg s "$FM_HERDR_SESSION" --arg sock "$(session_socket)" --arg w "$ws" --arg p "$pane" --arg t "$(date -u +%FT%TZ)" --arg h "$FM_HARNESS" --arg profile "$FM_CONSOLE_PROFILE" --arg model "$FM_CONSOLE_MODEL" \
    '{record:"fm-cleanroom-captain-console/v1", session:$s, socket:$sock, workspace_id:$w, pane_id:$p, label:"firstmate", harness:$h, profile:$profile, model:$model, created_at:$t, transport:"herdr-session"}' > "$CONSOLE_RECORD"
  # The console is the harness itself, started by this same script in its own
  # pane; no worker is spawned to build the UI (workers remain a separate
  # FirstMate action). `pane run` types the command into the pane's shell.
  hs pane run "$pane" "exec '$FM_HOME/enter-firstmate.sh' --console" >/dev/null 2>&1 \
    || die "could not start the console in pane $pane"
  others=$(console_workspaces | grep -vx "$ws" | tr '\n' ' ' || true)
  [ -z "$others" ] || printf 'enter-firstmate: note: other workspace(s) also carry the label %s (%s); spawns from OUTSIDE this session are ambiguous until they close, spawns from the console are not\n' "$FM_CONSOLE_LABEL" "$others" >&2
  printf '%s %s created\n' "$ws" "$pane"
)


# --- Cold-start supervision arm (control issue #8; see the header) --------------
COLD_ARM_LOG=$FM_HOME/state/cold-start-arm.log
COLD_ARM_SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
COLD_ARM_TIMEOUT=${FM_ENTRY_ARM_TIMEOUT:-40}
COLD_ARM_DELIVER_WAIT=${FM_ENTRY_DELIVER_WAIT:-900}
case "$COLD_ARM_TIMEOUT" in ''|*[!0-9]*|0) COLD_ARM_TIMEOUT=40 ;; esac
case "$COLD_ARM_DELIVER_WAIT" in ''|*[!0-9]*) COLD_ARM_DELIVER_WAIT=900 ;; esac
cold_arm_log() { printf '%s pid=%s %s\n' "$(date -u +%FT%TZ)" "$$" "$*" 2>/dev/null >> "$COLD_ARM_LOG" || true; }

# cold_arm_probe: ONE read-only snapshot of every fact the decision, the owner,
# and the doctor need, as key=value tokens on one line. It runs in its own bash
# because the upstream libraries are not `set -e` clean; it starts nothing and
# consumes only the existing predicates: fm_supervision_status (need),
# fm_watcher_healthy (live identity-matched watcher + fresh beacon),
# fm_harness_pid_alive (session-lock owner liveness), fm_autoarm_claim_open and
# fm_autoarm_ledger_read (the Stop hook's epoch ledger).
cold_arm_probe() {
  FM_HOME="$FM_HOME" bash -c '
    set +e
    root=$1
    . "$root/bin/fm-wake-lib.sh" >/dev/null 2>&1 || exit 1
    . "$root/bin/fm-supervision-lib.sh" >/dev/null 2>&1 || exit 1
    . "$root/bin/fm-session-lock-lib.sh" >/dev/null 2>&1 || exit 1
    state="$FM_HOME/state"
    fm_supervision_status "$state"
    relay=no; [ -f "$state/x-watch.check.sh" ] && relay=yes
    writable=0
    if p=$(mktemp "$state/.cold-start-arm-probe.XXXXXX" 2>/dev/null); then rm -f "$p"; writable=1; fi
    afk=0; [ -e "$state/.afk" ] && afk=1
    lock_pid=$(tr -d "[:space:]" 2>/dev/null < "$state/.lock"); lock_state=free; foreign=0
    case "$lock_pid" in
      "") ;;
      *[!0-9]*) lock_state=malformed ;;
      *) if fm_harness_pid_alive "$lock_pid"; then lock_state=live; foreign=1; else lock_state=stale; fi ;;
    esac
    healthy=0; watcher_pid=
    if fm_watcher_healthy "$state" "$root/bin/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME"; then healthy=1; watcher_pid=$FM_WATCHER_HEALTHY_PID; fi
    watch_lock_pid=$(tr -d "[:space:]" 2>/dev/null < "$state/.watch.lock/pid")
    watch_lock_alive=0; fm_pid_alive "$watch_lock_pid" && watch_lock_alive=1
    watch_lock_held=1; fm_watcher_lock_unheld "$state" && watch_lock_held=0
    beacon=never; [ -e "$state/.last-watcher-beat" ] && beacon=$(fm_path_age "$state/.last-watcher-beat")
    claim_open=0; fm_autoarm_claim_open "$state" && claim_open=1
    gen=; owner=; outcome=
    if fm_autoarm_ledger_read "$state"; then gen=$FM_AUTOARM_GEN; owner=$FM_AUTOARM_OWNER; outcome=$FM_AUTOARM_OUTCOME; fi
    owner_alive=0; fm_pid_alive "$owner" && owner_alive=1
    owner_kind=gone
    if [ "$owner_alive" = 1 ]; then
      if grep -qa "fm-claude-stop-autoarm" "/proc/$owner/cmdline" 2>/dev/null; then owner_kind=stop-hook
      elif grep -qa "arm-owner" "/proc/$owner/cmdline" 2>/dev/null; then owner_kind=cold-start
      else owner_kind=other; fi
    fi
    ledger_age=never; [ -e "$state/.claude-autoarm-epoch" ] && ledger_age=$(fm_path_age "$state/.claude-autoarm-epoch")
    printf "needed=%s in_flight=%s sources=%s relay=%s afk=%s writable=%s lock_pid=%s lock_state=%s foreign_live_lock=%s healthy=%s watcher_pid=%s watch_lock_pid=%s watch_lock_alive=%s beacon=%s watch_lock_held=%s claim_open=%s ledger_gen=%s ledger_owner=%s ledger_owner_alive=%s ledger_outcome=%s ledger_age=%s ledger_owner_kind=%s\n" \
      "$FM_SUP_NEEDED" "$FM_SUP_IN_FLIGHT" "$FM_SUP_SOURCES" "$relay" "$afk" "$writable" \
      "${lock_pid:-none}" "$lock_state" "$foreign" "$healthy" "${watcher_pid:-none}" \
      "${watch_lock_pid:-none}" "$watch_lock_alive" "$beacon" "$watch_lock_held" "$claim_open" \
      "${gen:-none}" "${owner:-none}" "$owner_alive" "${outcome:-none}" "$ledger_age" "$owner_kind"
  ' _ "$FM_CODE_ROOT"
}
cold_arm_field() {  # <probe-line> <key>
  local tok
  for tok in $1; do case "$tok" in "$2="*) printf '%s' "${tok#*=}"; return 0 ;; esac; done
  printf ''
}
cold_arm_decision_from_probe() {  # <probe-line>
  cold_arm_decide "$(cold_arm_field "$1" needed)" "$(cold_arm_field "$1" afk)" \
    "$(cold_arm_field "$1" writable)" "$(cold_arm_field "$1" foreign_live_lock)" \
    "$(cold_arm_field "$1" claim_open)"
}
cold_arm_need_desc() {  # <probe-line>
  printf 'in-flight %s, event sources %s, relay poll %s' \
    "$(cold_arm_field "$1" in_flight)" "$(cold_arm_field "$1" sources)" "$(cold_arm_field "$1" relay)"
}
cold_arm_degraded_banner() {  # <why>
  cat >&2 <<BANNER
enter-firstmate: SUPERVISION NOT ARMED - this home needs the watcher and the cold-start arm could not verify one: $1
enter-firstmate:   The console starts anyway, VISIBLY DEGRADED, because it is the only place the captain can repair from:
enter-firstmate:   the session-start digest's watcher-liveness alarm will name the lapse, and the first turn's Stop hook
enter-firstmate:   (bin/fm-claude-stop-autoarm.sh) retries the arm. Until then no supervision event can reach this console.
enter-firstmate:   Evidence: $COLD_ARM_LOG  Posture: $FM_HOME/enter-firstmate.sh --doctor
BANNER
}

# cold_arm_ensure <backend> <target>: --console's synchronous step. Decide from
# the probe, start the detached owner only for "arm", wait for its
# `watcher: started|attached` line, re-verify the watcher, and report. Returns
# only when the console may exec the harness; refuses only an unwritable state.
cold_arm_ensure() {
  local backend=$1 target=$2 probe decision handoff deadline armline reasons owner_line owner_pid why
  probe=$(cold_arm_probe) || die "cold-start supervision probe failed: upstream libraries under $FM_CODE_ROOT/bin are unreadable"
  decision=$(cold_arm_decision_from_probe "$probe")
  # Control #8 revise-2c: a cold-start open claim is only a valid defer target
  # when a live cold-start arm-owner (typed-composer delivery) holds it. A
  # Stop-hook or dead owner cannot deliver to this turn-idle console, so supersede
  # it and let the launcher arm its own typed-delivery owner (which attaches to
  # the existing healthy watcher, never a second one).
  if [ "$decision" = defer-open-claim ] \
    && [ "$(cold_arm_claim_deliverable "$(cold_arm_field "$probe" ledger_owner_kind)")" = stale ]; then
    cold_arm_log "ensure: open claim gen=$(cold_arm_field "$probe" ledger_gen) owner=$(cold_arm_field "$probe" ledger_owner) kind=$(cold_arm_field "$probe" ledger_owner_kind) cannot deliver to this freshly launched console; superseding"
    printf 'enter-firstmate: supervision: the open auto-arm generation belongs to a prior console incarnation and cannot deliver a wake to this one; taking over supervision delivery\n' >&2
    sup=$(cold_arm_supersede_stale "$(cold_arm_field "$probe" ledger_gen)" "$(cold_arm_field "$probe" ledger_owner)")
    cold_arm_log "ensure: supersede stale claim -> $sup"
    probe=$(cold_arm_probe) || true
    decision=$(cold_arm_decision_from_probe "$probe")
  fi
  cold_arm_log "ensure backend=$backend target=$target decision=$decision $probe"
  case "$decision" in
    skip-not-needed)
      printf 'enter-firstmate: supervision: not required (%s); watcher not armed\n' "$(cold_arm_need_desc "$probe")" >&2
      return 0 ;;
    skip-afk)
      printf 'enter-firstmate: supervision: NOT armed by the launcher - away mode is active (state/.afk), so the away daemon owns the watcher; the session must resume /afk recovery on its first turn (%s)\n' "$(cold_arm_need_desc "$probe")" >&2
      return 0 ;;
    refuse-state-unwritable)
      die "supervision is required ($(cold_arm_need_desc "$probe")) but $FM_HOME/state is not writable, so no watcher lock, beacon, ledger, or session lock can be recorded; refusing to start an unsupervisable console" ;;
    defer-live-session)
      printf 'enter-firstmate: supervision: NOT armed by the launcher - a live session (harness pid %s) already holds this home'"'"'s session lock and its own between-turn arm owns the watcher (watcher %s, beacon %ss); this console will open read-only until that session ends\n' \
        "$(cold_arm_field "$probe" lock_pid)" "$( [ "$(cold_arm_field "$probe" healthy)" = 1 ] && printf 'live pid %s' "$(cold_arm_field "$probe" watcher_pid)" || printf 'NOT live')" "$(cold_arm_field "$probe" beacon)" >&2
      return 0 ;;
    defer-open-claim)
      # A live owner already holds the current auto-arm generation: a cold-start
      # owner that outlived a previous console, or a live Stop hook. It delivers
      # its own close (re-resolving this home's console record), so verify only.
      deadline=$(( $(date +%s) + COLD_ARM_TIMEOUT ))
      while [ "$(cold_arm_field "$probe" healthy)" != 1 ] && [ "$(date +%s)" -lt "$deadline" ]; do
        # An open claim whose watcher lock is released and whose ledger entry is
        # older than one arm bound is an owner PAST its close: it is delivering
        # that wake (bounded by its own deliver wait), not still arming.
        if [ "$(cold_arm_field "$probe" watch_lock_held)" = 0 ] && [ "$(cold_arm_field "$probe" ledger_age)" != never ] \
          && [ "$(cold_arm_field "$probe" ledger_age)" -gt "$COLD_ARM_TIMEOUT" ]; then break; fi
        sleep 0.5; probe=$(cold_arm_probe) || break
      done
      if [ "$(cold_arm_field "$probe" healthy)" = 1 ]; then
        printf 'enter-firstmate: supervision: watcher attached pid=%s (beacon %ss); auto-arm generation %s is owned by live pid %s, which delivers its close to this console\n' \
          "$(cold_arm_field "$probe" watcher_pid)" "$(cold_arm_field "$probe" beacon)" "$(cold_arm_field "$probe" ledger_gen)" "$(cold_arm_field "$probe" ledger_owner)" >&2
        cold_arm_log "ensure: attached to generation $(cold_arm_field "$probe" ledger_gen) owner $(cold_arm_field "$probe" ledger_owner) watcher $(cold_arm_field "$probe" watcher_pid)"
        return 0
      fi
      if [ "$(cold_arm_field "$probe" watch_lock_held)" = 0 ] && [ "$(cold_arm_field "$probe" ledger_age)" != never ] \
        && [ "$(cold_arm_field "$probe" ledger_age)" -gt "$COLD_ARM_TIMEOUT" ]; then
        printf 'enter-firstmate: supervision: auto-arm generation %s owner pid %s has closed its watcher cycle and is delivering that wake to this console as a typed watcher wake; the watcher re-arms at this console'"'"'s first turn end (Stop hook), and the wake itself stays durable in state/.wake-queue\n' \
          "$(cold_arm_field "$probe" ledger_gen)" "$(cold_arm_field "$probe" ledger_owner)" >&2
        cold_arm_log "ensure: generation $(cold_arm_field "$probe" ledger_gen) owner $(cold_arm_field "$probe" ledger_owner) is past its close (delivering); no second watcher"
        return 0
      fi
      cold_arm_degraded_banner "auto-arm generation $(cold_arm_field "$probe" ledger_gen) is claimed by live pid $(cold_arm_field "$probe" ledger_owner) but no live identity-matched watcher with a fresh beacon appeared within ${COLD_ARM_TIMEOUT}s (beacon $(cold_arm_field "$probe" beacon))"
      cold_arm_log "ensure: DEGRADED open claim without a healthy watcher $probe"
      return 0 ;;
    arm) ;;
    *) die "cold-start supervision decision is not one this launcher knows: '$decision'" ;;
  esac
  mkdir -p "$FM_HOME/state"
  handoff=$(mktemp "$FM_HOME/state/.cold-start-arm.XXXXXX") || die "cannot create the cold-start arm handoff file under $FM_HOME/state"
  # Detached exactly like the Herdr server start above: its own session (no
  # controlling tty, so the pane's hangup never reaches it), reparented to init
  # when this subshell returns, stdio on the log. The owner forks the watcher as
  # its FOREGROUND arm's tracked child, never with a bare `&`.
  ( setsid "$COLD_ARM_SELF" --arm-owner "$backend" "$target" "$handoff" </dev/null >>"$COLD_ARM_LOG" 2>&1 & )
  deadline=$(( $(date +%s) + COLD_ARM_TIMEOUT ))
  while :; do
    armline=$(cold_arm_arm_line "$handoff")
    case "$armline" in started|attached) break ;; esac
    owner_line=$(grep -E '^decision: ' "$handoff" 2>/dev/null | tail -1 || true)
    case "$owner_line" in ''|'decision: arm'*) ;; *) break ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 0.5
  done
  owner_line=$(grep -E '^decision: ' "$handoff" 2>/dev/null | tail -1 || true)
  owner_pid=${owner_line##*owner_pid=}; [ "$owner_pid" != "$owner_line" ] || owner_pid=unknown
  probe=$(cold_arm_probe) || probe=''
  reasons=$(cold_arm_reasons "$handoff")
  case "$owner_line" in
    'decision: arm'*|'')
      if [ "$(cold_arm_field "$probe" healthy)" = 1 ] && { [ "$armline" = started ] || [ "$armline" = attached ]; }; then
        printf 'enter-firstmate: supervision: watcher %s pid=%s (beacon %ss), armed before the harness by cold-start owner pid=%s (auto-arm generation %s); its close is delivered to this console as a typed watcher wake\n' \
          "$armline" "$(cold_arm_field "$probe" watcher_pid)" "$(cold_arm_field "$probe" beacon)" "$owner_pid" "$(cold_arm_field "$probe" ledger_gen)" >&2
        cold_arm_log "ensure: verified $armline watcher $(cold_arm_field "$probe" watcher_pid) owner $owner_pid gen $(cold_arm_field "$probe" ledger_gen)"
        return 0
      fi
      if [ -n "$reasons" ]; then
        printf 'enter-firstmate: supervision: watcher %s by cold-start owner pid=%s and its first cycle already closed with an actionable wake (%s); the owner is delivering it to this console as a typed watcher wake\n' \
          "$armline" "$owner_pid" "$(printf '%s' "$reasons" | head -1)" >&2
        cold_arm_log "ensure: cycle closed during verification; delivery under way"
        return 0
      fi
      why="last arm line: $(grep -E '^watcher: ' "$handoff" 2>/dev/null | tail -1); owner pid $owner_pid; watcher lock pid $(cold_arm_field "$probe" watch_lock_pid) alive=$(cold_arm_field "$probe" watch_lock_alive); beacon $(cold_arm_field "$probe" beacon)"
      case "$why" in 'last arm line: ;'*) why="no arm line within ${COLD_ARM_TIMEOUT}s;${why#last arm line: ;}" ;; esac
      case "$why" in *'beacon never') ;; *) why="${why}s ago" ;; esac
      cold_arm_degraded_banner "$why"
      cold_arm_log "ensure: DEGRADED $why"
      return 0 ;;
    'decision: defer-open-claim'*)
      printf 'enter-firstmate: supervision: %s; that owner delivers its close to this console\n' "${owner_line#decision: }" >&2
      return 0 ;;
    *)
      printf 'enter-firstmate: supervision: owner reported %s; watcher not armed by the launcher\n' "${owner_line#decision: }" >&2
      return 0 ;;
  esac
}

# cold_arm_delivery_target <backend> <launch-target>: where the wake is typed.
# On Herdr the console is identified by THIS HOME'S OWN RECORD (see
# ensure_console_workspace), so an owner that outlived its console delivers to
# the console that replaced it; a record for another harness never qualifies.
cold_arm_delivery_target() {
  local backend=$1 target=$2 pane
  if [ "$backend" = herdr ] && [ -f "$CONSOLE_RECORD" ] \
    && [ "$(jq -r '.session // empty' "$CONSOLE_RECORD" 2>/dev/null)" = "$FM_HERDR_SESSION" ] \
    && [ "$(jq -r '.harness // empty' "$CONSOLE_RECORD" 2>/dev/null)" = "$FM_HARNESS" ]; then
    pane=$(jq -r '.pane_id // empty' "$CONSOLE_RECORD" 2>/dev/null)
    if [ -n "$pane" ]; then printf '%s:%s' "$FM_HERDR_SESSION" "$pane"; return 0; fi
  fi
  printf '%s' "$target"
}

# cold_arm_deliver <backend> <launch-target> <reason-lines>: the one actionable
# close becomes a typed `watcher`-kind operational input in the console's
# composer, through the same guards the away daemon applies: the endpoint must
# exist (read-only probe), the composer must classify affirmatively `empty`
# (never a dead shell, pending text, or unreadable pane), then the backend's
# verified submit core types ONCE and retries only Enter. Prints delivered |
# unconfirmed | undelivered. Bounded by COLD_ARM_DELIVER_WAIT.
cold_arm_deliver() {
  local backend=$1 target=$2 reasons=$3 body encoded t composer verdict deadline last=''
  body=$(cold_arm_wake_body "$reasons")
  fm_operational_input_encode watcher "$body" encoded || { cold_arm_log "deliver: could not encode the watcher-kind input"; echo undelivered; return 1; }
  deadline=$(( $(date +%s) + COLD_ARM_DELIVER_WAIT ))
  while :; do
    t=$(cold_arm_delivery_target "$backend" "$target")
    if ! fm_backend_target_exists "$backend" "$t"; then
      [ "$last" = "absent:$t" ] || { cold_arm_log "deliver: console endpoint $t absent; waiting for a console"; last="absent:$t"; }
    else
      composer=$(fm_backend_composer_state "$backend" "$t" 2>/dev/null)
      if [ "$composer" = empty ]; then
        verdict=$(fm_backend_send_text_submit "$backend" "$t" "$encoded" 3 0.5 0.5)
        case "$verdict" in
          empty) cold_arm_log "deliver: watcher wake submitted to $t (composer confirmed empty after Enter)"; echo delivered; return 0 ;;
          send-failed) [ "$last" = send-failed ] || { cold_arm_log "deliver: backend send to $t failed before typing; retrying"; last=send-failed; } ;;
          *) cold_arm_log "deliver: watcher wake typed into $t but the submit stayed unconfirmed (verdict=${verdict:-unknown}); not retyping"; echo unconfirmed; return 0 ;;
        esac
      else
        [ "$last" = "composer:$t:$composer" ] || { cold_arm_log "deliver: $t composer not confirmed-empty (state=${composer:-unknown}: pending input, dead-shell prompt, or unreadable pane); waiting"; last="composer:$t:$composer"; }
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      cold_arm_log "deliver: gave up after ${COLD_ARM_DELIVER_WAIT}s; the wake stays durable in $FM_HOME/state/.wake-queue for the next drain"
      echo undelivered; return 1
    fi
    sleep 2
  done
}

# cold_arm_owner <backend> <target> <handoff>: the detached owner (--arm-owner).
# Mirrors bin/fm-claude-stop-autoarm.sh step for step - gates, generation
# claim, foreground arm, bounded retry, benign-healthy close, ownership
# re-verification before every side effect, owned ledger commit - with the
# typed delivery above in place of the hook's exit-2 rewake.
cold_arm_owner() {
  local backend=$1 target=$2 handoff=$3 state probe decision rc gen attempt attempts=2 reasons='' healthy=0 delivered=''
  set +e
  # shellcheck source=/dev/null
  . "$FM_CODE_ROOT/bin/fm-wake-lib.sh" || { echo "watcher: FAILED - cannot load $FM_CODE_ROOT/bin/fm-wake-lib.sh" >> "$handoff"; exit 1; }
  # shellcheck source=/dev/null
  . "$FM_CODE_ROOT/bin/fm-supervision-lib.sh"
  # shellcheck source=/dev/null
  . "$FM_CODE_ROOT/bin/fm-operational-input.sh"
  # shellcheck source=/dev/null
  . "$FM_CODE_ROOT/bin/fm-backend.sh"
  state=$FM_HOME/state
  note() { printf '%s\n' "$*" >> "$handoff"; cold_arm_log "owner: $*"; }
  probe=$(cold_arm_probe) || { note "watcher: FAILED - probe failed inside the owner"; exit 1; }
  decision=$(cold_arm_decision_from_probe "$probe")
  case "$decision" in
    arm) ;;
    defer-open-claim) note "decision: defer-open-claim gen=$(cold_arm_field "$probe" ledger_gen) owner_pid=$(cold_arm_field "$probe" ledger_owner)"; exit 0 ;;
    *) note "decision: $decision"; exit 0 ;;
  esac
  fm_autoarm_claim_next "$state" "${FM_GUARD_GRACE:-300}"; rc=$?
  if [ "$rc" -eq 2 ]; then
    probe=$(cold_arm_probe)
    note "decision: defer-open-claim gen=$(cold_arm_field "$probe" ledger_gen) owner_pid=$(cold_arm_field "$probe" ledger_owner)"
    exit 0
  fi
  [ "$rc" -eq 0 ] && [ -n "${FM_AUTOARM_MY_GEN:-}" ] || { note "watcher: FAILED - could not claim an auto-arm generation in $state/.claude-autoarm-epoch (ledger contended or unwritable)"; exit 1; }
  gen=$FM_AUTOARM_MY_GEN
  note "decision: arm gen=$gen owner_pid=$$"
  attempt=0
  while [ "$attempt" -lt "$attempts" ]; do
    fm_autoarm_still_owner "$state" "$gen" || { cold_arm_log "owner: superseded before arm attempt $((attempt + 1)); standing down"; rm -f "$handoff"; exit 0; }
    attempt=$((attempt + 1))
    # FOREGROUND arm: the canonical owner starts or attaches, verifies, prints its
    # one line into the handoff, then blocks until the cycle closes.
    FM_WATCH_ARM_ORIGIN=cold-start "$FM_CODE_ROOT/bin/fm-watch-arm.sh" >> "$handoff" 2>&1
    rc=$?
    cold_arm_log "owner: arm attempt $attempt closed rc=$rc"
    if [ -e "$state/.afk" ]; then
      fm_autoarm_write_owned "$state" "$gen" afk >/dev/null 2>&1 || true
      cold_arm_log "owner: away mode appeared mid-cycle; the daemon owns triage now"; exit 0
    fi
    reasons=$(cold_arm_reasons "$handoff")
    [ -z "$reasons" ] || break
    if fm_watcher_healthy "$state" "$FM_CODE_ROOT/bin/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME"; then healthy=1; break; fi
  done
  if ! fm_supervision_needed "$state" "${FM_GUARD_GRACE:-300}"; then
    fm_autoarm_write_owned "$state" "$gen" clean >/dev/null 2>&1 || true
    cold_arm_log "owner: supervision no longer needed; closing quietly"; rm -f "$handoff"; exit 0
  fi
  if [ "$healthy" -eq 1 ]; then
    fm_autoarm_reset_owned "$state" "$gen" >/dev/null 2>&1 || true
    fm_autoarm_write_owned "$state" "$gen" clean >/dev/null 2>&1 || true
    cold_arm_log "owner: non-actionable close but another verified watcher owns this home; clean"; rm -f "$handoff"; exit 0
  fi
  if [ -n "$reasons" ]; then
    fm_autoarm_still_owner "$state" "$gen" || { cold_arm_log "owner: superseded before delivery; the durable queue keeps the wake"; rm -f "$handoff"; exit 0; }
    cold_arm_log "owner: actionable close: $(printf '%s' "$reasons" | tr '\n' '|')"
    delivered=$(cold_arm_deliver "$backend" "$target" "$reasons")
    fm_autoarm_write_owned "$state" "$gen" rewake >/dev/null 2>&1; rc=$?
    cold_arm_log "owner: delivery=$delivered ledger-commit rewake rc=$rc (0 committed, 2 superseded, 1 unwritable)"
    rm -f "$handoff"
    exit 0
  fi
  fm_autoarm_write_owned "$state" "$gen" failed >/dev/null 2>&1 || true
  note "watcher: FAILED - cold-start arm exhausted $attempt attempt(s) with no live watcher and no actionable close"
  exit 1
}

# --- Console launch contract: runtime (control issue #8 REVISE 2; see the header) ---
# console_backend <function> [args...]: run ONE upstream backend helper in its
# own bash (the upstream libraries are not `set -e` clean), printing its stdout.
console_backend() {
  FM_HOME="$FM_HOME" HERDR_SESSION="$FM_HERDR_SESSION" bash -c '
    set +e
    root=$1; shift
    . "$root/bin/fm-wake-lib.sh" >/dev/null 2>&1 || exit 1
    . "$root/bin/fm-backend.sh" >/dev/null 2>&1 || exit 1
    fm_backend_source herdr >/dev/null 2>&1 || exit 1
    "$@"
  ' _ "$FM_CODE_ROOT" "$@"
}
console_pane_process() {  # <pane> -> "name=<n> pid=<p> ppid=<pp> shell_pid=<s> count=<c>" or nothing when the pane is unreadable
  local info name pid ppid shell_pid count
  info=$(hs pane process-info --pane "$1" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg pane "$1" '.result.type == "pane_process_info" and .result.process_info.pane_id == $pane' >/dev/null 2>&1 || return 1
  name=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].name // empty')
  pid=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].pid // empty')
  shell_pid=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty')
  count=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes | length')
  ppid=''
  [ -z "$pid" ] || ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
  printf 'name=%s pid=%s ppid=%s shell_pid=%s count=%s\n' "${name:-none}" "${pid:-0}" "${ppid:-0}" "${shell_pid:-0}" "${count:-0}"
}
console_pane_recorded_session_of() {  # <pane> -> Herdr's own persisted claude session id for the pane, if any
  hs pane get "$1" 2>/dev/null | jq -r '.result.pane.agent_session // empty | select(.agent=="claude" and .kind=="id") | .value // empty' 2>/dev/null || true
}
# console_pane_state <pane>: the observed class of the recorded console pane.
console_pane_state() {
  local pane=$1 proc cpid alive=0 cls
  proc=$(console_pane_process "$pane") || { echo absent; return 0; }
  cpid=$(console_record_field console_pid); case "$cpid" in ''|*[!0-9]*) cpid=0 ;; esac
  [ "$cpid" = 0 ] || ! kill -0 "$cpid" 2>/dev/null || alive=1
  cls=$(console_pane_classify "$(cold_arm_field "$proc" name)" "$(cold_arm_field "$proc" pid)" "$(cold_arm_field "$proc" ppid)" "$cpid" "$alive" "${FM_HARNESS##*/}")
  if [ "$cls" = shell ]; then
    # The upstream idle-shell proof (one lone recognized shell, no child, sleeping)
    # is the only thing that turns "a shell is in the foreground" into "stranded".
    console_backend fm_backend_herdr_pane_idle_shell_pid "$FM_HERDR_SESSION" "$pane" >/dev/null 2>&1 || cls=other
  fi
  echo "$cls"
}
# console_restore_settle <pane>: after THIS launch started the server, wait for
# Herdr's restore to settle on the recorded pane: the pane must exist and its
# foreground must read the same for three consecutive seconds (a native resume
# that fails takes about 1.5 s to fall back to the shell).
console_restore_settle() {
  local pane=$1 deadline last='' same=0 proc key
  deadline=$(( $(date +%s) + CONSOLE_RESTORE_SETTLE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if proc=$(console_pane_process "$pane"); then
      key="$(cold_arm_field "$proc" name):$(cold_arm_field "$proc" pid)"
      if [ "$key" = "$last" ]; then same=$((same + 1)); else same=0; last=$key; fi
      [ "$same" -lt 2 ] || { console_log "converge: restore settled on pane $pane ($proc)"; return 0; }
    fi
    sleep 1
  done
  console_log "converge: restore did not settle on pane $pane within ${CONSOLE_RESTORE_SETTLE}s (last: ${last:-unreadable})"
  return 0
}
# console_restart_in_pane <ws> <pane> <resume-id|""> <why>: type the canonical
# console contract into the stranded pane's shell, once per two minutes.
console_restart_in_pane() {
  local ws=$1 pane=$2 sid=$3 why=$4 marker cmd old_cpid new_cpid deadline age
  marker="$FM_HOME/state/.console-restart.$(printf '%s' "$pane" | tr -c 'A-Za-z0-9' '_')"
  if [ -f "$marker" ]; then
    age=$(( $(date +%s) - $(cat "$marker" 2>/dev/null || echo 0) ))
    [ "$age" -ge 120 ] || die "the console was already restarted in pane $pane ${age}s ago and is not canonical yet ($why); refusing a second restart within two minutes (no retry loop) - inspect with $FM_HOME/enter-firstmate.sh --doctor"
  fi
  printf -v cmd "exec env FM_CONSOLE_PROFILE=%q FM_HARNESS=%q %q --console" "$FM_CONSOLE_PROFILE" "$FM_HARNESS" "$FM_HOME/enter-firstmate.sh"
  if [ -n "$sid" ]; then console_resume_id_valid "$sid" || die "refusing to pass a malformed resume id to --console: $sid"; cmd="$cmd --resume '$sid'"; fi
  old_cpid=$(console_record_field console_pid)
  date +%s > "$marker"
  hs pane run "$pane" "$cmd" >/dev/null 2>&1 || die "could not restart the console in pane $pane"
  console_log "converge: restarted the console contract in pane $pane ($why) resume=${sid:-none}"
  deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    new_cpid=$(console_record_field console_pid)
    if [ -n "$new_cpid" ] && [ "$new_cpid" != "$old_cpid" ] && kill -0 "$new_cpid" 2>/dev/null; then
      printf 'enter-firstmate: console restarted in pane %s (%s); the console contract is running there as pid %s\n' "$pane" "$why" "$new_cpid" >&2
      printf '%s %s restarted\n' "$ws" "$pane"
      return 0
    fi
    sleep 0.5
  done
  printf 'enter-firstmate: WARNING: the console contract was typed into pane %s (%s) but did not claim the console record within 20s; watch that pane\n' "$pane" "$why" >&2
  printf '%s %s restart-unconfirmed\n' "$ws" "$pane"
  return 1
}
# console_converge <ws> <pane>: the recorded pane exists; decide from what is
# OBSERVED in it whether the canonical console is live, and converge if not.
console_converge() {
  local ws=$1 pane=$2 target cls sid composer action verdict deadline proc
  target="$FM_HERDR_SESSION:$pane"
  [ "$SESSION_STARTED_NOW" = 0 ] || console_restore_settle "$pane"
  cls=$(console_pane_state "$pane")
  sid=''; composer=unknown
  if [ "$cls" = foreign-harness ]; then
    sid=$(console_pane_recorded_session_of "$pane")
    composer=$(console_backend fm_backend_composer_state herdr "$target" 2>/dev/null || echo unknown)
    # A harness Herdr has just restored is still drawing its UI and running its
    # session-start hooks; give its composer a bounded chance to read empty
    # before deciding it cannot be converged.
    if [ "$SESSION_STARTED_NOW" = 1 ] && [ "$composer" != empty ]; then
      deadline=$(( $(date +%s) + CONSOLE_COMPOSER_WAIT ))
      while [ "$composer" != empty ] && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 2; composer=$(console_backend fm_backend_composer_state herdr "$target" 2>/dev/null || echo unknown)
      done
    fi
  fi
  action=$(console_converge_action "$cls" "$SESSION_STARTED_NOW" "$composer" "$sid")
  console_log "converge: pane=$pane class=$cls session_started_now=$SESSION_STARTED_NOW composer=$composer herdr_session_id=${sid:-none} action=$action"
  case "$action" in
    reuse)
      printf '%s %s existing\n' "$ws" "$pane"
      return 0 ;;
    restart)
      console_restart_in_pane "$ws" "$pane" "" "pane was stranded at an idle shell; the previous console pid $(console_record_field console_pid) is gone"
      return $? ;;
    converge)
      # Herdr's native resume-on-restore put a harness this launcher did not start
      # into the console pane (only possible right after THIS launch started the
      # server). Its composer is provably empty, so exit it the way fm-control
      # does, then relaunch the SAME conversation under the canonical contract.
      printf 'enter-firstmate: console pane %s runs %s restored natively by Herdr (session %s), not by this launcher; exiting it and relaunching that session under the canonical console contract\n' "$pane" "$FM_HARNESS" "$sid" >&2
      verdict=$(console_backend fm_backend_send_text_submit herdr "$target" "$(console_exit_command)" 3 0.5 1.2 2>/dev/null || echo send-failed)
      [ "$verdict" != send-failed ] || die "could not send the exit command into pane $pane; leaving it alone - exit it by hand and click the launcher again"
      deadline=$(( $(date +%s) + CONSOLE_EXIT_WAIT ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if proc=$(console_pane_process "$pane"); then
          case "$(cold_arm_field "$proc" name)" in sh|bash|zsh|dash|ksh|fish) break ;; esac
        fi
        sleep 1
      done
      [ "$(console_pane_state "$pane")" = shell ] || die "pane $pane did not return to an idle shell within ${CONSOLE_EXIT_WAIT}s after the exit command (submit verdict: $verdict); leaving it alone - inspect it and click the launcher again"
      console_restart_in_pane "$ws" "$pane" "$sid" "Herdr's native resume of session $sid was exited (verdict $verdict)"
      return $? ;;
    *)
      case "$cls" in
        foreign-harness)
          printf 'enter-firstmate: WARNING: console pane %s runs %s NOT started by this launcher (no cold-start arm, style, or permission policy applied)%s; it is left untouched. Exit it (%s) and click the launcher again, or read %s --doctor\n' \
            "$pane" "$FM_HARNESS" "$( [ "$SESSION_STARTED_NOW" = 1 ] && printf ' - composer %s, herdr session id %s' "$composer" "${sid:-none}" || printf ' - the server was already running, so this may be a live session' )" "$(console_exit_command)" "$FM_HOME/enter-firstmate.sh" >&2 ;;
        absent)
          printf 'enter-firstmate: WARNING: console pane %s vanished while converging; click the launcher again\n' "$pane" >&2 ;;
        *)
          printf 'enter-firstmate: WARNING: console pane %s foreground is neither the canonical console nor an idle shell (%s); it is left untouched - inspect it\n' "$pane" "$cls" >&2 ;;
      esac
      printf 'enter-firstmate: console convergence is incomplete (%s); refusing to report a successful launch\n' "$cls" >&2
      return 1 ;;
  esac
}
console_exit_command() {  # the harness's own exit command, as bin/fm-control-lib.sh's fm_control_exit_command
  case "$FM_HARNESS" in codex|pi|pi-signed) printf '/quit' ;; *) printf '/exit' ;; esac
}
console_pane_recorded_session() { console_pane_recorded_session_of "$HERDR_PANE_ID"; }
# console_run [harness args...]: --console's launch step, after the supervision
# arm. Owns the resume decision, the argv, the record, and the observed
# stale-resume fallback. Never returns: it exits with the harness's status.
console_run() {
  local resume='' origin='' verdict argv=() fresh=() started rc elapsed outcome policy_state style off arg
  local -a passthrough=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume) [ $# -ge 2 ] || die "--console --resume needs a session id"; resume=$2; origin=explicit; shift 2 ;;
      --resume=*) resume=${1#--resume=}; origin=explicit; shift ;;
      *) passthrough+=("$1"); shift ;;
    esac
  done
  if [ -z "$resume" ] && [ "$FM_HARNESS" = claude ]; then
    resume=$(console_pane_recorded_session || true)
    [ -z "$resume" ] || origin=herdr-record
  fi
  if [ -n "$resume" ]; then
    if [ "$FM_HARNESS" != claude ]; then
      console_log "resume-skipped id=$resume origin=$origin verdict=harness-$FM_HARNESS"; resume=''
    else
      verdict=$(console_resume_candidate "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$FM_CODE_ROOT" "$resume")
      if [ "$verdict" != valid ]; then
        printf 'enter-firstmate: console: not resuming Claude session %s (%s: %s); starting a fresh session under the same contract\n' "$resume" "$origin" "$verdict" >&2
        console_log "resume-skipped id=$resume origin=$origin verdict=$verdict"
        resume=''
      fi
    fi
  fi
  policy_state=$(permission_policy_state "$FM_HARNESS")
  style=${HARNESS_STYLE_SETTINGS:-}
  while IFS= read -r arg; do fresh+=("$arg"); done < <(console_harness_argv "$FM_HARNESS" "$FM_CONSOLE_MODEL" "$style" "" "${passthrough[@]}")
  if [ -n "$resume" ]; then
    while IFS= read -r arg; do argv+=("$arg"); done < <(console_harness_argv "$FM_HARNESS" "$FM_CONSOLE_MODEL" "$style" "$resume" "${passthrough[@]}")
  else
    argv=("${fresh[@]}")
  fi
  # Launch-byte watched red (control #7): a profile console can never start
  # without the captain-authorized posture, whatever composed the argv.
  case "$(permission_policy_state "$FM_HARNESS")" in
    QUALIFIED)
      case " ${argv[*]} " in *" $(permission_policy_posture "$FM_HARNESS") "*) ;; *) die "console argv lost the captain-authorized permission posture ($(permission_policy_posture "$FM_HARNESS")); refusing to start an approval-prompting console" ;; esac ;;
  esac
  # $0/subscription boundary: no paid/gateway/provider/budget selector may reach
  # the composed launch (fresh or resume). Refuse rather than pay.
  if ! off=$(console_argv_subscription_only "${argv[@]}"); then
    die "refusing to launch: the composed console argv carries a paid/gateway selector ($off); the primary console is \$0/subscription-only (no API/gateway fallback, no overage, no budget flag)"
  fi
  if ! off=$(console_argv_subscription_only "${fresh[@]}"); then
    die "refusing to launch: the fresh-fallback console argv carries a paid/gateway selector ($off); the primary console is \$0/subscription-only"
  fi
  console_record_update "$(jq -n --arg pid "$$" --arg mode "$( [ -n "$resume" ] && echo resume || echo fresh )" --arg id "$resume" --arg t "$(date -u +%FT%TZ)" --arg argv "${argv[*]}" --arg pol "$policy_state" \
    '{console_pid:($pid|tonumber), launch_stage:"launching", launch_mode:$mode, resume_id:$id, launched_at:$t, argv:$argv, permission_state:$pol}')" \
    || printf 'enter-firstmate: note: the console record does not name this pane; launch fields not recorded\n' >&2
  printf 'enter-firstmate: console: %s %s; permissions %s [%s]; style %s\n' "$FM_HARNESS" \
    "$( [ -n "$resume" ] && printf 'resuming session %s (%s)' "$resume" "$origin" || printf 'fresh session' )" \
    "$(permission_policy_posture "$FM_HARNESS")" "$policy_state" "${style:-off}" >&2
  console_log "launch harness=$FM_HARNESS mode=$( [ -n "$resume" ] && echo resume || echo fresh ) resume=${resume:-none} origin=${origin:-none} permission=$policy_state argv=${argv[*]}"
  started=$(date +%s)
  set +e
  if [ "$FM_HARNESS" = codex ]; then
    python3 "$FM_CODE_ROOT/bin/fm-console-codex.py" "${argv[@]}"; rc=$?
  else
    "$FM_HARNESS" "${argv[@]}"; rc=$?
  fi
  set -e
  elapsed=$(( $(date +%s) - started ))
  outcome=$(console_launch_outcome "$( [ -n "$resume" ] && echo 1 || echo 0 )" "$rc" "$elapsed" "$CONSOLE_RESUME_WINDOW")
  if [ "$outcome" = fallback-fresh ]; then
    printf 'enter-firstmate: console: STALE RESUME - %s exited rc=%s after %ss while resuming session %s (%s); starting ONE fresh session under the identical contract (no further retry)\n' "$FM_HARNESS" "$rc" "$elapsed" "$resume" "$origin" >&2
    console_log "stale-resume-fallback id=$resume origin=$origin rc=$rc elapsed=${elapsed}s -> fresh"
    console_record_update "$(jq -n --arg t "$(date -u +%FT%TZ)" --arg argv "${fresh[*]}" '{launch_mode:"fresh-after-stale-resume", resume_id:"", launched_at:$t, argv:$argv}')" || true
    started=$(date +%s)
    set +e
    "$FM_HARNESS" "${fresh[@]}"; rc=$?
    set -e
    elapsed=$(( $(date +%s) - started ))
    console_log "exited mode=fresh-after-stale-resume rc=$rc elapsed=${elapsed}s"
  else
    console_log "exited mode=$( [ -n "$resume" ] && echo resume || echo fresh ) rc=$rc elapsed=${elapsed}s"
  fi
  console_record_update "$(jq -n --arg rc "$rc" --arg t "$(date -u +%FT%TZ)" '{launch_stage:"exited", exit_rc:($rc|tonumber), exited_at:$t}')" || true
  [ "$rc" -eq 0 ] || printf 'enter-firstmate: console: %s exited rc=%s after %ss; this pane ends with it (no interactive shell is left behind as a nominal success) - relaunch from the Desktop shortcut, or read %s --doctor\n' "$FM_HARNESS" "$rc" "$elapsed" "$FM_HOME/enter-firstmate.sh" >&2
  exit "$rc"
}

if [ "$MODE" = arm-owner ]; then
  [ "$#" -eq 3 ] || die "--arm-owner needs <backend> <target> <handoff-file>"
  cold_arm_owner "$1" "$2" "$3"
  # shellcheck disable=SC2317 # every owner path exits itself; this is the belt.
  exit 1
fi
# --- Post-attach convergence owner (control issue #8 REVISE 2, live relaunch 2) ---
if [ "$MODE" = converge-owner ]; then
  [ "$#" -eq 2 ] || die "--converge-owner needs <workspace> <pane>"
  SESSION_STARTED_NOW=1
  console_log "converge-owner: waiting up to ${CONSOLE_ATTACH_WAIT}s for pane $2 to materialize (Herdr spawns restored panes on TUI attach)"
  deadline=$(( $(date +%s) + CONSOLE_ATTACH_WAIT ))
  until console_pane_process "$2" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then console_log "converge-owner: pane $2 never materialized within ${CONSOLE_ATTACH_WAIT}s; convergence incomplete"; printf 'enter-firstmate: console convergence timed out\n' >&2; exit 1; fi
    sleep 1
  done
  console_log "converge-owner: pane $2 materialized; settling and classifying"
  exec 9>"$FM_HOME/state/console-launch.lock" || exit 2
  flock -w 10 9 || exit 2
  rec=$(console_record_pane) || exit $?
  [ "$rec" = "$1 $2" ] || exit 2
  console_converge "$1" "$2"
  exit $?
fi
# --- exchange/current freshness owner (control issue #3, exchange projection maintenance gap) ---
# The captain-facing projection E:\FirstMate-Cleanroom\exchange\current\ is code-owned by
# exchange/bin/exchange-current.py (renderer, watermark, doctor, idempotent refresh). This
# launcher is the SESSION-START RECONCILIATION seam (one bounded refresh before the console
# harness starts) and the doctor's freshness surface; the durable milestone seams are the
# control receipt wrapper and the apply step (exchange/README-FIRST.md section 5). No daemon,
# scheduler or watcher: a refresh with unchanged authoritative inputs is a byte-stable NO-OP.
EXCHANGE_OWNER=$(resolve_host_path "${FM_EXCHANGE_OWNER:-}" exchange-owner)
EXCHANGE_LOG=$FM_HOME/state/exchange-current-refresh.log
exchange_current_refresh() {  # <origin>: session-start | apply | receipt
  [ -f "$EXCHANGE_OWNER" ] || { printf 'enter-firstmate: exchange/current: owner absent (%s); projection not refreshed\n' "$EXCHANGE_OWNER" >&2; return 0; }
  local out rc=0
  out=$(EXCHANGE_FM_HOME="$FM_HOME" timeout 120 python3 "$EXCHANGE_OWNER" refresh 2>&1) || rc=$?   # set -e safe
  printf '%s origin=%s rc=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$rc" "$(printf '%s' "$out" | head -1)" >> "$EXCHANGE_LOG" 2>/dev/null || true
  case $rc in
    0) printf 'enter-firstmate: %s\n' "$(printf '%s' "$out" | head -1)" >&2 ;;
    4) printf 'enter-firstmate: WARNING: exchange/current refresh could-not-observe a source; the affected registers were left as they were (%s)\n' "$EXCHANGE_LOG" >&2 ;;
    *) printf 'enter-firstmate: WARNING: exchange/current refresh failed rc=%s (%s); the console starts anyway and the doctor reports STALE\n' "$rc" "$EXCHANGE_LOG" >&2 ;;
  esac
  return 0   # never fatal: a stale projection is reported by the doctor, it must not block the captain
}
exchange_current_doctor_brief() {
  [ -f "$EXCHANGE_OWNER" ] || { echo "COULD-NOT-OBSERVE (owner absent: $EXCHANGE_OWNER)"; return 0; }
  EXCHANGE_FM_HOME="$FM_HOME" timeout 120 python3 "$EXCHANGE_OWNER" doctor --brief 2>&1 | head -1 || true
}

# --- Doctor -----------------------------------------------------------------
if [ "$MODE" = doctor ]; then
  control() {  # <fsc3_config.py argument...>
    [ -f "$FM_CONTROL_RESOLVER" ] || { echo "COULD-NOT-OBSERVE (resolver absent)"; return 0; }
    python3 "$FM_CONTROL_RESOLVER" "$@" 2>&1 | head -20 || true
  }
  herdr_field() {  # <jq-path>
    command -v herdr >/dev/null 2>&1 || { echo "COULD-NOT-OBSERVE (herdr absent)"; return 0; }
    herdr status --json --session "$FM_HERDR_SESSION" 2>/dev/null | jq -r "$1 // \"COULD-NOT-OBSERVE\"" 2>/dev/null || echo "COULD-NOT-OBSERVE"
  }
  floors=$(
    FM_HOME="$FM_HOME" bash -c '
      . "'"$FM_CODE_ROOT"'/bin/fm-backend.sh" >/dev/null 2>&1 || exit 1
      fm_backend_source herdr >/dev/null 2>&1 || exit 1
      printf "protocol>=%s events>=%s workspace-move>=%s presentation>=%s (herdr %s)\n" \
        "$FM_BACKEND_HERDR_MIN_PROTOCOL" "$FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL" \
        "$FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL" "$FM_BACKEND_HERDR_MIN_PRESENTATION_PROTOCOL" \
        "$FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION"
    ' 2>/dev/null
  ) || floors=""
  [ -n "$floors" ] || floors="COULD-NOT-OBSERVE (adapter constants unreadable)"
  console_state="absent (created on the next console launch)"
  if rec=$(console_record_pane 2>/dev/null); then
    console_state="present: workspace ${rec% *} pane ${rec#* } (this home's recorded console)"
  elif [ -f "$CONSOLE_RECORD" ]; then
    console_state="recorded but its pane is gone (re-created on the next console launch)"
  fi
  session_running || console_state="session not running; $console_state"
  console_labeled=$(console_workspaces 2>/dev/null | tr '\n' ' ')

  echo "=== FirstMate-Cleanroom :: effective identity (doctor; nothing was started) ==="
  echo
  echo "-- host"
  echo "  wsl distro:        ${WSL_DISTRO_NAME:-<unset>}"
  echo "  uname:             $(uname -sr)"
  echo "  date:              $(date -Is)"
  echo
  echo "-- firstmate"
  echo "  code root:         $FM_CODE_ROOT"
  echo "  code head:         $(git -C "$FM_CODE_ROOT" rev-parse --short HEAD 2>/dev/null || echo COULD-NOT-OBSERVE)"
  echo "  code worktree:     $(test -z "$(git -C "$FM_CODE_ROOT" status --porcelain 2>/dev/null)" && echo clean || echo DIRTY)"
  echo "  FM_HOME:           $FM_HOME"
  echo "  cwd:               $PWD"
  echo "  harness:           $(command -v "$FM_HARNESS" 2>/dev/null || echo "NOT FOUND: $FM_HARNESS")"
  echo
  echo "-- captain console"
  echo "  captain_console_transport: herdr-session   (was: plain-terminal before 2026-09-02)"
  echo "  console session:   $FM_HERDR_SESSION"
  echo "  console workspace: $console_state"
  echo "  console command:   $FM_HOME/enter-firstmate.sh --console  (typed into the workspace's root pane; no worker spawned)"
  echo "  console record:    $CONSOLE_RECORD"
  echo "  '$FM_CONSOLE_LABEL' workspaces: ${console_labeled:-none}  (label is not identity; the record is)"
  if rec=$(console_record_pane 2>/dev/null); then
    doc_pane=${rec#* }
    doc_proc=$(console_pane_process "$doc_pane" 2>/dev/null || echo 'unreadable')
    echo "  observed pane:     ${doc_proc}"
    echo "  console class:     $(console_pane_state "$doc_pane" 2>/dev/null || echo COULD-NOT-OBSERVE)  (canonical = harness started by --console pid $(console_record_field console_pid); shell = stranded; foreign-harness = not started by this launcher)"
    echo "  last launch:       stage=$(console_record_field launch_stage) mode=$(console_record_field launch_mode) resume=$(console_record_field resume_id) at=$(console_record_field launched_at) rc=$(console_record_field exit_rc) permission=$(console_record_field permission_state)"
    doc_sid=$(console_pane_recorded_session_of "$doc_pane")
    echo "  herdr session id:  ${doc_sid:-none}  (Herdr's own pane record; the resume candidate for the next --console)$( [ -z "$doc_sid" ] || printf ' -> %s' "$(console_resume_candidate "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$FM_CODE_ROOT" "$doc_sid")")"
  fi
  echo "  fresh console argv: $FM_HARNESS $(console_harness_argv "$FM_HARNESS" "$FM_CONSOLE_MODEL" "$( [ "$FM_HARNESS" = claude ] && [ -f "$FM_HOME/config/claude-settings.json" ] && printf '%s' "$FM_HOME/config/claude-settings.json" )" "" | tr '\n' ' ')"
  echo "  resume window:     ${CONSOLE_RESUME_WINDOW}s (a resume exiting non-zero inside it falls back ONCE to a fresh session)   restore settle: ${CONSOLE_RESTORE_SETTLE}s   exit wait: ${CONSOLE_EXIT_WAIT}s"
  echo
  console_profile_menu_render
  echo "  herdr native resume: $(grep -E '^\s*resume_agents_on_restore\s*=' "$HOME/.config/herdr/config.toml" 2>/dev/null | tail -1 | tr -d ' ' || true)$(grep -qE '^\s*resume_agents_on_restore\s*=' "$HOME/.config/herdr/config.toml" 2>/dev/null || printf 'unset -> default true')  (global ~/.config/herdr/config.toml; shared with the other live home, so not changed by this launcher)"
  echo "  launch log:        $CONSOLE_LOG$( [ -f "$CONSOLE_LOG" ] && printf '  last: %s' "$(tail -1 "$CONSOLE_LOG" | cut -c1-200)" || printf '  (absent)')"
  echo
  echo "-- harness permission policy (control issue #7 ruling 3; owner: this launcher's permission_policy_* block)"
  echo "  primary ($FM_HARNESS): $(permission_policy_posture "$FM_HARNESS")  [$(permission_policy_state "$FM_HARNESS")]  owner: $(permission_policy_owner "$FM_HARNESS")"
  for h in $(permission_policy_harnesses); do
    tok=$(permission_policy_spawn_token "$h")
    if [ -n "$tok" ]; then
      if grep -qF -- "$tok" "$FM_CODE_ROOT/bin/fm-spawn.sh" 2>/dev/null; then drift="present in bin/fm-spawn.sh"; else drift="DRIFT: token '$tok' NOT in bin/fm-spawn.sh"; fi
    else
      drift="no spawn token (nothing to prove)"
    fi
    printf '  %-10s %-14s %s  <- %s\n' "$h:" "$(permission_policy_state "$h")" "$(permission_policy_posture "$h")" "$drift"
  done
  echo "  scope:             interactive approval prompts only; FirstMate authority, merge/landing rules, gates, validators, credentials unchanged"
  echo "  global untouched:  ~/.claude/settings.json skipDangerousModePermissionPrompt=$(jq -r '.skipDangerousModePermissionPrompt // "unset"' "$HOME/.claude/settings.json" 2>/dev/null)  permissions.defaultMode=$(jq -r '.permissions.defaultMode // "unset"' "$HOME/.claude/settings.json" 2>/dev/null)  (read only; never written here)"
  echo
  echo "-- runtime backend and herdr identity"
  echo "  config/backend:    $FM_BACKEND_CONFIGURED"
  echo "  HERDR_SESSION:     $HERDR_SESSION   (from config/herdr-session)"
  echo "  herdr binary:      $(command -v herdr 2>/dev/null || echo 'NOT FOUND')"
  echo "  herdr client:      v$(herdr_field .client.version) protocol $(herdr_field .client.protocol)"
  echo "  herdr server:      $(herdr_field .server.status) v$(herdr_field .server.version)"
  echo "  adapter floors:    $floors"
  echo "  session socket:    $(session_socket || true)$(session_socket >/dev/null 2>&1 && [ -n "$(session_socket)" ] || echo "not created yet (the console launch starts this session's own server)")"
  if srv_pid=$(session_server_pid); then
    srv_path=$(session_env_field "$srv_pid" PATH)
    echo "  server pid:        $srv_pid"
    echo "  server NM_HOME:    $(session_env_field "$srv_pid" NM_HOME || true)  $([ "$(session_env_field "$srv_pid" NM_HOME)" = "$NM_HOME" ] && echo '(matches)' || echo '(MISMATCH - every worker and gate agent inherits this; restart is captain-gated)')"
    echo "  server PATH[0]:    ${srv_path%%:*}  $([ "${srv_path%%:*}" = "$FM_TOOLS" ] && echo '(clean-room tools first)' || echo '(MISMATCH - every worker and gate agent inherits this; restart is captain-gated)')"
  else
    echo "  server pid:        not running (the console launch starts it with this shell's NM_HOME and PATH)"
  fi
  echo "  workspace label:   $FM_CONSOLE_LABEL  (constant for every primary home; isolated here by the session, not the label)"
  echo "  parent pane:       $FM_HERDR_ANCESTRY"
  echo
  echo "-- tools (policy projected from the pinned upstream floors; repair is always clean-room-scoped)"
  echo "  PATH head:         $(printf '%s' "$PATH" | cut -d: -f1-3)"
  echo "  tools first:       $(doctor_tools_first "$PATH" "$FM_TOOLS")"
  "$FM_TOOLS_ROOT/tool-policy.sh" --code-root "$FM_CODE_ROOT" 2>&1 | sed 's/^/  /'
  echo "  jq / python3:      $(command -v jq || echo MISSING) / $(command -v python3 || echo MISSING)"
  echo
  echo "-- tool profile (observed from real consumer shells; owner: ${TOOL_PROFILE_OWNER#"$FM_CODE_ROOT"/}$([ -x "$TOOL_PROFILE_OWNER" ] || echo ' ABSENT at the pinned code root, inline fallback'))"
  echo "  direct shell:"
  tool_profile_observe direct | sed 's/^/    /'
  echo "  login shell (negative control; a stock ~/.profile re-prepends ~/.local/bin):"
  tool_profile_observe login | sed 's/^/    /'
  echo
  echo "-- no-mistakes isolation"
  echo "  NM_HOME:           $NM_HOME"
  echo "  shared root:       $NM_SHARED_ROOT  (never used from here; daemon pid $(nm_shared_pid || echo unknown) untouched)"
  echo "  client:            $NM_BIN  $(no-mistakes --version 2>/dev/null | head -1)  [$NM_STATE]"
  echo "  clean-room daemon: $(nm_daemon_running && echo "running (pid $(nm_daemon_pid))" || echo "not running (the console launch starts it under NM_HOME)")"
  echo "  root distinct:     $([ "$(nm_root_canonical "$NM_HOME")" != "$(nm_root_canonical "$NM_SHARED_ROOT")" ] && echo yes || echo 'NO - REFUSE')"
  echo
  echo "-- captain presentation (output style; private activation, global untouched)"
  echo "  canonical copy:    $FM_HOME/config/output-styles/attention-kind.md  sha256 $(sha256sum "$FM_HOME/config/output-styles/attention-kind.md" 2>/dev/null | cut -c1-16 || echo COULD-NOT-OBSERVE)"
  echo "  donor pin:         $(jq -r '"\(.donor_repo)@\(.donor_commit[0:8]) (\(.donor_tag)) \(.donor_path) sha256 \(.donor_sha256[0:16]) \(.license)"' "$FM_HOME/config/output-styles/attention-kind.pin.json" 2>/dev/null || echo COULD-NOT-OBSERVE)"
  echo "  materialized:      $HOME/.claude/output-styles/attention-kind.md  $(cmp -s "$FM_HOME/config/output-styles/attention-kind.md" "$HOME/.claude/output-styles/attention-kind.md" 2>/dev/null && echo byte-identical || echo 'ABSENT or DRIFTED (re-materialized at console launch)')"
  echo "  activation owner:  $FM_HOME/config/claude-settings.json -> outputStyle=$(jq -r '.outputStyle // "unset"' "$FM_HOME/config/claude-settings.json" 2>/dev/null)  (passed as --settings by --console only)"
  echo "  global settings:   ~/.claude/settings.json outputStyle=$(jq -r '.outputStyle // "unset"' "$HOME/.claude/settings.json" 2>/dev/null)   legacy home: $(jq -r '.outputStyle // "unset"' "$FM_RETIRED_HOME/.claude/settings.json" 2>/dev/null)"
  echo
  echo "-- control plane (projected through the single resolver; never re-authored here)"
  echo "  resolver:          $FM_CONTROL_RESOLVER"
  echo "  owner:             $(control home)/config/control-plane.yaml"
  echo "  protocol:          $(control get control.protocol)"
  echo "  repository:        $(control get control.repository)"
  echo "  browser sol proj:  $(control get control.browser_sol_project)"
  echo "  browser sol thread:$(control get control.browser_sol_thread)"
  echo "  routing:           $(control get routing.from) -> $(control get routing.to)  [$(control get routing.escalation_label) / $(control get routing.destination_label)]"
  echo "  config generation: $(control digest)"
  echo "  schema generation: $(python3 "$(dirname "$FM_CONTROL_RESOLVER")/fsc3.py" digest 2>/dev/null || echo COULD-NOT-OBSERVE)  (generation 3)"
  echo "  listener:          $(control listener | tr -d '\n ' | head -c 300)"
  echo "  inbound monitor:   $(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_CODE_ROOT" "$FM_CODE_ROOT/bin/fm-procevent.sh" list 2>/dev/null | grep -F -- '-inbound' | head -1 || echo 'NOT REGISTERED - control commissions need a manual wake')"
  echo
  echo "-- exchange/current (captain-facing projection; owner exchange/bin/exchange-current.py; refreshed at every --console start)"
  echo "  freshness:         $(exchange_current_doctor_brief)"
  echo "  log:               $EXCHANGE_LOG$( [ -f "$EXCHANGE_LOG" ] && printf '  last: %s' "$(tail -1 "$EXCHANGE_LOG" | cut -c1-160)" || printf '  (absent)')"
  echo
  echo "-- supervision (cold-start arm posture; the doctor arms nothing)"
  if arm_probe=$(cold_arm_probe); then
    arm_decision=$(cold_arm_decision_from_probe "$arm_probe")
    echo "  required:          $(cold_arm_field "$arm_probe" needed)  ($(cold_arm_need_desc "$arm_probe"))"
    if [ "$(cold_arm_field "$arm_probe" healthy)" = 1 ]; then
      echo "  watcher:           live pid $(cold_arm_field "$arm_probe" watcher_pid) (identity-matched lock, beacon $(cold_arm_field "$arm_probe" beacon)s)"
    else
      echo "  watcher:           NOT live (lock pid $(cold_arm_field "$arm_probe" watch_lock_pid) alive=$(cold_arm_field "$arm_probe" watch_lock_alive); beacon $(cold_arm_field "$arm_probe" beacon)$( [ "$(cold_arm_field "$arm_probe" beacon)" = never ] || printf 's ago'))"
    fi
    echo "  arm owner ledger:  generation $(cold_arm_field "$arm_probe" ledger_gen) owner pid $(cold_arm_field "$arm_probe" ledger_owner) (alive=$(cold_arm_field "$arm_probe" ledger_owner_alive), kind $(cold_arm_field "$arm_probe" ledger_owner_kind)) outcome $(cold_arm_field "$arm_probe" ledger_outcome); claim open: $(cold_arm_field "$arm_probe" claim_open); deliverable to a cold-start console: $(cold_arm_claim_deliverable "$(cold_arm_field "$arm_probe" ledger_owner_kind)")  ($FM_HOME/state/.claude-autoarm-epoch, shared with the Stop hook)"
    echo "  session lock:      $(cold_arm_field "$arm_probe" lock_state) (pid $(cold_arm_field "$arm_probe" lock_pid))   away mode: $( [ "$(cold_arm_field "$arm_probe" afk)" = 1 ] && echo on || echo off)   state writable: $(cold_arm_field "$arm_probe" writable)"
    echo "  cold-start arm:    would '$arm_decision' at the next --console launch (bound ${COLD_ARM_TIMEOUT}s; deliver wait ${COLD_ARM_DELIVER_WAIT}s)"
  else
    echo "  posture:           COULD-NOT-OBSERVE (probe failed; upstream libraries unreadable)"
  fi
  echo "  arm log:           $COLD_ARM_LOG$( [ -f "$COLD_ARM_LOG" ] && printf '  last: %s' "$(tail -1 "$COLD_ARM_LOG" | cut -c1-160)" || printf '  (absent)')"
  echo
  echo "-- non-adoption of the other live FirstMate home"
  echo "  its home:          ${FM_RETIRED_HOME:-<none configured>}  (not on this launch path)"
  echo "  its herdr session: default           (this launch uses '$HERDR_SESSION')"
  echo "  FM_HOME leak:      $(doctor_fm_home_leak)"
  echo "  PATH leak:         $(doctor_path_leak)"
  echo "  NM_HOME leak:      $([ "$(nm_root_canonical "$NM_HOME")" = "$(nm_root_canonical "$NM_SHARED_ROOT")" ] && echo 'YES - REFUSE' || echo none)"
  echo
  echo "=== end doctor ==="
  if [ -t 0 ] && [ -t 1 ]; then
    printf '\npress Enter to close this window... '
    read -r _ || true
  fi
  exit 0
fi

# --- ensure the clean-room no-mistakes daemon (its own root, never the shared one) ---
if ! nm_daemon_running; then
  if ! no-mistakes daemon start >>"$FM_HOME/state/no-mistakes-daemon-start.log" 2>&1; then
    printf 'enter-firstmate: WARNING: the clean-room no-mistakes daemon under %s did not start (see state/no-mistakes-daemon-start.log); planning/control use continues, product-facing shipping stays held\n' "$NM_HOME" >&2
  fi
fi
if [ -n "$(nm_daemon_pid)" ] && [ "$(nm_daemon_pid)" = "$(nm_shared_pid)" ]; then
  die "the clean-room NM_HOME reports the SHARED daemon's pid; refusing (fallback-to-shared-root watched red)"
fi

# --- captain presentation: Attention-kind output style (control issue #5) ---------
# The canonical donor copy lives in this home; the harness discovers styles only in
# ~/.claude/output-styles (or a project's .claude/output-styles, which here is the
# read-only pinned checkout), so a byte-identical materialization is kept there and
# ACTIVATED only for this console through --settings. Global and legacy settings
# are never written. Nothing in a style may change authority, routing or tooling
# (keep-coding-instructions: true).
STYLE_CANON=$FM_HOME/config/output-styles/attention-kind.md
STYLE_MATERIALIZED=$HOME/.claude/output-styles/attention-kind.md
STYLE_SETTINGS=$FM_HOME/config/claude-settings.json
style_materialize() {
  [ -f "$STYLE_CANON" ] || return 1
  mkdir -p "$(dirname "$STYLE_MATERIALIZED")"
  if ! cmp -s "$STYLE_CANON" "$STYLE_MATERIALIZED"; then cp "$STYLE_CANON" "$STYLE_MATERIALIZED"; fi
  cmp -s "$STYLE_CANON" "$STYLE_MATERIALIZED"
}
HARNESS_STYLE_SETTINGS=''
if [ "$FM_HARNESS" = claude ] && [ -f "$STYLE_SETTINGS" ] && style_materialize; then
  HARNESS_STYLE_SETTINGS=$STYLE_SETTINGS
fi

# --- console run (inside the clean-room session's own pane) ---------------------
if [ "$MODE" = console-run ]; then
  # Supervision first (control issue #8): the watcher is verified live, or the
  # degraded banner is printed, before the harness replaces this shell.
  cold_arm_ensure herdr "$FM_HERDR_SESSION:$HERDR_PANE_ID"
  # Session-start reconciliation of the captain-facing projection (control issue #3,
  # exchange maintenance gap, condition 5): idempotent, bounded, never fatal.
  exchange_current_refresh session-start
  # Then the launch contract (control issue #8 REVISE 2, control issue #7):
  # validated resume or fresh, permission policy on the argv, observed
  # stale-resume fallback. console_run exits with the harness's status.
  console_run "$@"
  # shellcheck disable=SC2317 # console_run always exits; this is the belt.
  die "console_run returned; this is a launcher bug"
fi

# --- console launch (outside Herdr, or after dropping a foreign ancestry) ------
command -v herdr >/dev/null 2>&1 || die "herdr is not installed; the captain console runs inside the named Herdr session"
# Loud, never weakened: the lint and test gates refuse on these same facts, so
# they are printed here where the captain can act before a run pays for them.
mkdir -p "$FM_HOME/state"
if ! tool_profile_observe direct >"$FM_HOME/state/tool-profile.last" 2>&1; then
  printf 'enter-firstmate: WARNING: ENVIRONMENT_UNREADY from the console shell (product-facing shipping will refuse at the gate; planning/control use continues):\n' >&2
  grep '^ENVIRONMENT_UNREADY' "$FM_HOME/state/tool-profile.last" | sed 's/^/enter-firstmate:   /' >&2
fi
ensure_session
assert_session_env
sock=$(session_socket)
[ -n "$sock" ] || die "the clean-room session '$FM_HERDR_SESSION' reports no socket"
case "$sock" in "$HOME/.config/herdr/herdr.sock") die "the clean-room session resolved to the DEFAULT server socket; refusing to attach to the legacy session" ;; esac
console_location=$(ensure_console_workspace) || exit $?
read -r ws pane how <<< "$console_location"
[ -n "$ws" ] && [ -n "$pane" ] && [ -n "$how" ] || die "console workspace result is incomplete"
printf 'enter-firstmate: console workspace %s pane %s (%s) in session %s at %s\n' "$ws" "$pane" "$how" "$FM_HERDR_SESSION" "$sock" >&2
converge_pid=''
if [ "$how" = deferred ]; then
  # This launch started the server: Herdr will spawn the restored console pane
  # only once the TUI below attaches, so the convergence (restart a stranded
  # shell, or exit a natively resumed harness and relaunch it canonically) is
  # owned by one child process that acts after that attach.
  "$COLD_ARM_SELF" --converge-owner "$ws" "$pane" </dev/null &
  converge_pid=$!
  console_log "launch: server started by this launch; convergence of pane $pane deferred to a post-attach owner"
  printf 'enter-firstmate: the server was started by this launch, so Herdr restores the console pane only when the TUI attaches; a supervised owner converges it through the console contract right after (log: %s)\n' "$CONSOLE_LOG" >&2
fi
# Evidence capture only: FM_ENTRY_NO_ATTACH=1 stops here, after the session and
# console exist, so a non-interactive run can prove the placement without a tty.
[ -z "${FM_ENTRY_NO_ATTACH:-}" ] || {
  printf 'enter-firstmate: FM_ENTRY_NO_ATTACH set; not attaching the TUI\n' >&2
  [ -z "$converge_pid" ] || wait "$converge_pid" || exit $?
  exit 0
}
# Retain this shell so the failure-display owner also sees attach failures.
if [ -n "$converge_pid" ]; then
  herdr --session "$FM_HERDR_SESSION" <&0 &
  attach_pid=$!
  converge_rc=0
  wait "$converge_pid" || converge_rc=$?
  if [ "$converge_rc" != 0 ]; then
    kill "$attach_pid" 2>/dev/null || true
    wait "$attach_pid" 2>/dev/null || true
    exit "$converge_rc"
  fi
  wait "$attach_pid"
else
  herdr --session "$FM_HERDR_SESSION"
fi
