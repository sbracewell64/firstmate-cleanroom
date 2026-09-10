#!/usr/bin/env bash
set -euo pipefail
repo=$PWD
fixture=$(mktemp -d /var/tmp/fm-runtime-evidence.XXXXXX)
export FM_HOME="$fixture/home" FM_PROCEVENT_CLAIM_ROOT="$fixture/claims"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
pe() { "$repo/bin/fm-procevent.sh" "$@"; }
cleanup() { pe sweep-home >/dev/null 2>&1 || true; chmod -R u+w "$fixture"; rm -rf "$fixture"; }
trap cleanup EXIT
mkdir -p "$FM_HOME"
cp -R docs/examples/process-event-extension "$fixture/package"
chmod 755 "$fixture/package" "$fixture/package/file-signal.mjs"
printf 'Isolated CLI qualification; no live primary, control publication, or model call.\n'
printf '$ fm-extension.mjs bind <shipped-example> --adapter file-signal --trust-same-user-code --consent artifact-references\n'
"$repo/bin/fm-extension.mjs" bind "$fixture/package" --adapter file-signal --trust-same-user-code --consent artifact-references
printf '$ fm-procevent.sh register-extension file-signal evidence-source --config-ref file:<signal>\n'
pe register-extension file-signal evidence-source --config-ref "file:$fixture/signal"
sleep 0.01 & dead=$!; wait "$dead"
printf '%s\n' "$dead" > "$FM_HOME/state/procevent/evidence-source.runner"
chmod 600 "$FM_HOME/state/procevent/evidence-source.runner"
printf 'Fixture: private runner record for exited PID %s, before any signal exists.\n' "$dead"
printf '$ fm-procevent.sh reconcile\n'
pe reconcile
printf '$ fm-procevent.sh list\n'
pe list
printf 'Publish a local fixture signal after detached startup.\n'
printf 'later fixture message: build 42 complete\n' > "$fixture/signal"
result="$FM_HOME/state/procevent-inbox/evidence-source.1.result"
for _ in $(seq 1 200); do
  if [ -f "$result" ] && [ ! -f "$FM_HOME/state/procevent/evidence-source.source" ]; then break; fi
  sleep 0.05
done
[ -f "$result" ]
printf '$ cat <durably captured result>\n'
cat "$result"
printf '$ fm-procevent.sh classify <captured-result>\n'
pe classify "$result"
printf '$ cat <durable wake queue>\n'
cat "$FM_HOME/state/.wake-queue"
printf '$ fm-procevent.sh handled evidence-source 1\n'
pe handled evidence-source 1
printf '$ fm-procevent.sh handled evidence-source 1\n'
pe handled evidence-source 1
printf '$ fm-procevent.sh reconcile\n'
pe reconcile
printf '$ cat <durable handled marker>\n'
cat "$FM_HOME/state/procevent-inbox/evidence-source.1.handled"
printf 'Legacy built-in source using a symlinked state root:\n'
mkdir "$fixture/legacy-state"
ln -s "$fixture/legacy-state" "$fixture/state-link"
FM_STATE_OVERRIDE="$fixture/state-link" pe register lavish legacy-evidence -- /bin/echo legacy-capture
FM_STATE_OVERRIDE="$fixture/state-link" pe start legacy-evidence
printf '$ cat <legacy durably captured result>\n'
cat "$fixture/legacy-state/procevent-inbox/legacy-evidence.1.result"
FM_STATE_OVERRIDE="$fixture/state-link" pe handled legacy-evidence 1
FM_STATE_OVERRIDE="$fixture/state-link" pe retire legacy-evidence
