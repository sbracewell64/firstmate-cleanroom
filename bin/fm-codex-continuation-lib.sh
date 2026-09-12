# shellcheck shell=bash
# Codex turn-end custody, shared by the Stop guard and the existing away owner.
# A finite checkpoint is never a post-final receiver. The away daemon may
# publish continuity only in its own live lock, bound to the current primary
# process/start identity, exact home/root and actual pane target. This proves
# transport custody, never canonical control-message acceptance.
#
# The daemon is the sole writer of .supervise-daemon.lock/continuation; its
# lock lifecycle retires it. Stop owns .turnend-codex-blocks (session-scoped
# bounded recovery and explicit CNO failure, never task completion).
# Requires fm-wake-lib.sh. No process launch, pipeline control or source effect.

fm_codex_continuation_publish() { # <state> <home> <root> <backend> <target>
  local state=$1 home=$2 root=$3 backend=$4 target=$5 lock pid primary identity tmp
  lock="$state/.supervise-daemon.lock"
  pid=$(cat "$lock/pid" 2>/dev/null) || return 1
  [ "$pid" = "${BASHPID:-$$}" ] || return 1
  primary=$(cat "$state/.lock" 2>/dev/null) || return 1
  identity=$(fm_pid_identity "$primary") || return 1
  tmp="$lock/continuation.tmp"
  {
    printf 'schema=fm-codex-away-continuation.v1\nhome=%s\nroot=%s\n' "$home" "$root"
    printf 'backend=%s\ntarget=%s\nprimary=%s\nprimary_identity=%s\n' "$backend" "$target" "$primary" "$identity"
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
  command=$(ps -p "$pid" -o args= 2>/dev/null) || return 1
  case "$command" in
    "bash $root/bin/fm-supervise-daemon.sh"|"/bin/bash $root/bin/fm-supervise-daemon.sh"|"/usr/bin/bash $root/bin/fm-supervise-daemon.sh") ;;
    *) return 1 ;;
  esac
  # Verify this hook belongs to the primary session; an unrelated live PID
  # cannot confer permission to stop this session.
  fm_session_lock_owned_by_self "$state" || return 1
  primary=$(cat "$state/.lock" 2>/dev/null) || return 1
  identity=$(fm_pid_identity "$primary") || return 1
  if [ -d "/proc/$primary" ]; then
    cwd=$(readlink "/proc/$primary/cwd" 2>/dev/null) || return 1
  else
    cwd=$(lsof -a -p "$primary" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p') || return 1
  fi
  [ "$cwd" = "$root" ] || return 1
  # Use the hook's actual pane, never the daemon's override or fallback target.
  if [ -n "${TMUX_PANE:-}" ]; then
    backend=tmux; target=$TMUX_PANE
  elif [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] && [ -n "${HERDR_SESSION:-}" ]; then
    backend=herdr; target="$HERDR_SESSION:$HERDR_PANE_ID"
  else
    return 1
  fi
  # Compare the complete record so duplicates, missing fields and unknown
  # versions cannot be accepted by a permissive scalar reader.
  [ "$(cat "$record")" = "$(printf 'schema=fm-codex-away-continuation.v1\nhome=%s\nroot=%s\nbackend=%s\ntarget=%s\nprimary=%s\nprimary_identity=%s' \
    "$home" "$root" "$backend" "$target" "$primary" "$identity")" ]
}

fm_codex_continuation_refuse() { # <state> <session-id> <reason>
  local state=$1 session=$2 reason=$3 lock file count=0 saved tmp notified=no
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
  [ "$count" -ge 3 ] || count=$((count + 1))
  if [ "$count" -ge 3 ] && [ "$notified" != yes ]; then
    # The existing durable wake queue carries the escalation, while the task
    # records retain unfinished work. Queue-before-receipt may repeat a wake
    # after a crash, but never loses the failure or authorizes another action.
    if fm_wake_append check codex-continuation-cno \
      'check: Codex continuation CNO - bounded Stop recovery exhausted; supervision retains unfinished work; verify native receiver custody before idle'; then
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
  if [ "$count" -ge 3 ]; then
    printf 'CONTINUATION_CNO: bounded recovery exhausted (%s); no verified post-final receiver; unfinished work remains open for the supervision owner\n' "$reason" >&2
    return 0
  fi
  printf 'CONTINUATION_REQUIRED: %s; finite watcher liveness and Stop retry are not post-final custody. Resume checkpoint/drain/handle/ack, then re-enter the checkpoint while work remains.\n' "$reason" >&2
  return 2
}
