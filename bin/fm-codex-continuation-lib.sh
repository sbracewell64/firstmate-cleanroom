# shellcheck shell=bash
# Codex turn-end custody, shared by the Stop guard and the existing away owner.
# A finite checkpoint is never a post-final receiver. The away daemon may
# publish continuity only in its own live lock, bound to the exact home/root and
# the actual pane target. This proves transport custody, never canonical
# control-message acceptance.
#
# THE GUARD MUST PROVE CUSTODY BY OBSERVING WHAT CUSTODY ACTUALLY CONSISTS OF,
# NOT BY COMPARING RECORDED IDENTITIES. Custody is a live daemon holding its own
# lock and injecting into this pane, so the published record carries only what
# cannot change while that daemon lives - home, root, backend and target - while
# every process fact (daemon liveness and start identity, primary session
# membership, the primary's working directory) is re-observed at Stop time. A
# recorded identity that outlives what it described would report a healthy
# session as unverified, and the bounded refusal would then allow exactly the
# blind idle this guard exists to prevent.
#
# The daemon is the sole writer of .supervise-daemon.lock/continuation; its
# lock lifecycle retires it. Stop owns .turnend-codex-blocks (session-scoped
# bounded recovery and explicit CNO failure, never task completion). A recovery
# budget names the session being budgeted - the caller's own harness ancestry -
# so concurrent sessions in one home can never spend each other's turns.
#
# Custody is NOT evaluable at all when a supervisor target override is in
# effect, because the daemon publishes the target that override resolved while
# the hook can only compose its own pane. That configuration gets its own
# self-naming disposition and an immediate CNO; it is never reported as a
# custody failure, because custody is held and merely unprovable here.
# Requires fm-wake-lib.sh and fm-session-lock-lib.sh, sourced by the caller.
# No process launch, pipeline control or source effect.

# The fleet's single owner of supervisor-pane composition; the hook must resolve
# its own pane exactly as the daemon resolved the one it publishes.
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-supervisor-target-lib.sh"

fm_codex_continuation_publish() { # <state> <home> <root> <backend> <target>
  local state=$1 home=$2 root=$3 backend=$4 target=$5 lock pid tmp
  lock="$state/.supervise-daemon.lock"
  pid=$(cat "$lock/pid" 2>/dev/null) || return 1
  [ "$pid" = "${BASHPID:-$$}" ] || return 1
  tmp="$lock/continuation.tmp"
  {
    printf 'schema=fm-codex-away-continuation.v1\nhome=%s\nroot=%s\n' "$home" "$root"
    printf 'backend=%s\ntarget=%s\n' "$backend" "$target"
  } > "$tmp" && mv "$tmp" "$lock/continuation"
}

fm_codex_continuation_owned() { # <state> <home> <root>
  local state=$1 home=$2 root=$3 lock record pid identity primary target backend command cwd
  lock="$state/.supervise-daemon.lock"
  record="$lock/continuation"
  [ -f "$state/.afk" ] && [ ! -e "$state/.subsuper-inject-wedged" ] || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  pid=$(cat "$lock/pid" 2>/dev/null) || return 1
  fm_pid_alive "$pid" || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  [ "$identity" = "$(cat "$lock/pid-identity" 2>/dev/null)" ] || return 1
  # Basename, carried by the start identity verified above. The interpreter
  # spelling and the launcher's logical path are not part of custody.
  command=$(ps -p "$pid" -o args= 2>/dev/null) || return 1
  case " $command " in
    *"/fm-supervise-daemon.sh "*) ;;
    *) return 1 ;;
  esac
  # Verify this hook belongs to the primary session; an unrelated live PID
  # cannot confer permission to stop this session.
  fm_session_lock_owned_by_self "$state" || return 1
  primary=$(cat "$state/.lock" 2>/dev/null) || return 1
  if [ -d "/proc/$primary" ]; then
    cwd=$(readlink "/proc/$primary/cwd" 2>/dev/null) || return 1
  else
    cwd=$(lsof -a -p "$primary" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p') || return 1
  fi
  [ "$cwd" = "$root" ] || return 1
  # Use the hook's actual pane, never the daemon's override or fallback target:
  # both env overrides are cleared, and the fallback's non-zero status refuses.
  backend=$(unset FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET; discover_supervisor_backend) || return 1
  target=$(unset FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET; discover_supervisor_target) || return 1
  # Compare the complete record so duplicates, missing fields and unknown
  # versions cannot be accepted by a permissive scalar reader.
  [ "$(cat "$record")" = "$(printf 'schema=fm-codex-away-continuation.v1\nhome=%s\nroot=%s\nbackend=%s\ntarget=%s' \
    "$home" "$root" "$backend" "$target")" ]
}

fm_codex_continuation_session_key() {
  local pid identity
  # The budget identity names the session being budgeted: this caller's own
  # verified harness ancestry, never the home, the fleet-lock holder, the
  # vendor payload or a literal. The POSIX session the hook runs in is the only
  # fallback, because it is the one remaining value that stays constant for a
  # session's whole life and still differs between concurrent sessions.
  pid=$(fm_harness_ancestry_pid) || pid=$(ps -o sess= -p "$$" 2>/dev/null | tr -d '[:space:]')
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  identity=$(fm_pid_identity "$pid") || identity=start-unresolved
  printf 'harness=%s %s' "$pid" "$identity"
}

fm_codex_continuation_refuse() { # <state> <session-key> <reason> [unevaluable]
  local state=$1 session=$2 reason=$3 unevaluable=${4:-no} lock file count=0 saved tmp notified=no wake
  lock="$state/.turnend-codex-blocks.lock"
  file="$state/.turnend-codex-blocks"
  # A lock/write failure is a loud CNO, never a false receipt or an endless
  # sequence of forced model turns. The caller leaves unfinished work intact.
  fm_lock_try_acquire "$lock" || {
    printf 'CONTINUATION_CNO: recovery budget unreadable; unfinished work remains open\n' >&2
    return 0
  }
  saved=$(sed -n '1s/^session=//p' "$file" 2>/dev/null || true)
  if [ "$saved" = "$session" ]; then
    count=$(sed -n '2s/^blocks=//p' "$file" 2>/dev/null || true)
    case "$count" in 0|1|2|3) ;; *) count=3 ;; esac
    notified=$(sed -n 's/^notified=//p' "$file" 2>/dev/null || true)
  fi
  if [ "$unevaluable" = yes ]; then
    # Three forced continuations buy nothing when custody is known to be
    # unprovable, so this disposition starts spent rather than climbing a
    # ladder it can never finish.
    count=3
  else
    [ "$count" -ge 3 ] || count=$((count + 1))
  fi
  if [ "$count" -ge 3 ] && [ "$notified" != yes ]; then
    # The existing durable wake queue carries the escalation, while the task
    # records retain unfinished work. Queue-before-receipt may repeat a wake
    # after a crash, but never loses the failure or authorizes another action.
    wake='check: Codex continuation CNO - bounded Stop recovery exhausted; supervision retains unfinished work; verify native receiver custody before idle'
    [ "$unevaluable" != yes ] || wake='check: Codex continuation CNO - Stop custody is not evaluable under a supervisor target override; supervision retains unfinished work; verify native receiver custody before idle'
    if fm_wake_append check codex-continuation-cno "$wake"; then
      notified=yes
    else
      notified=no
      printf 'CONTINUATION_CNO: escalation queue unreadable; durable failure remains pending\n' >&2
    fi
  fi
  tmp="$file.tmp.${BASHPID:-$$}"
  if ! printf 'session=%s\nblocks=%s\noutcome=CNO\nreason=%s\nnotified=%s\n' "$session" "$count" "$reason" "$notified" > "$tmp" \
    || ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    printf 'CONTINUATION_CNO: recovery receipt could not be recorded; unfinished work remains open\n' >&2
    return 0
  fi
  fm_lock_release "$lock"
  if [ "$unevaluable" = yes ]; then
    printf 'CONTINUATION_CNO: custody is not evaluable under a supervisor target override (%s); Stop custody is NOT verified in this configuration and no bounded recovery is attempted; unfinished work remains open for the supervision owner\n' "$reason" >&2
    return 0
  fi
  if [ "$count" -ge 3 ]; then
    printf 'CONTINUATION_CNO: bounded recovery exhausted (%s); no verified post-final receiver; unfinished work remains open for the supervision owner\n' "$reason" >&2
    return 0
  fi
  printf 'CONTINUATION_REQUIRED: %s; finite watcher liveness and Stop retry are not post-final custody. Resume checkpoint/drain/handle/ack, then re-enter the checkpoint while work remains.\n' "$reason" >&2
  return 2
}
