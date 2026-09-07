#!/usr/bin/env bash
# Deterministic regression for the child-stdin EPIPE invariant shared by the
# OpenCode and Pi turn-end guard twins.
#
# A guard child that exits before draining its stdin closes the read end under
# the host's payload write; that raises EPIPE on the child.stdin writable. An
# unlistened 'error' on a writable becomes an uncaught exception and crashes the
# host, so each writer attaches `child.stdin.on("error", () => {})` before the
# write and lets the child's real verdict ride on exit code and stderr.
#
# The real crash is scheduling-dependent (the guard payload is a ~26-byte JSON
# that the kernel buffers instantly, so a real write almost never errors), which
# is why the landed OpenCode test did not pin it. This suite makes it
# deterministic by substituting node:child_process through a loader hook: the
# fake child's stdin raises EPIPE on every write. The fake records that it raised
# the error, so a pass is not vacuous - surviving an emitted 'error' is only
# possible when the production handler is attached. Delete that handler and the
# emitted error becomes an uncaught exception, the host process crashes, and the
# `SURVIVED` line never prints.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_test_require_node_ts   # the Pi guard twin is a .ts source imported through node

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard-epipe)
export NODE_NO_WARNINGS=1

# Loader that replaces node:child_process for the driven guard module with a
# fake whose stdin errors deterministically. The close code stays 0 so the guard
# returns "supervision healthy" and never reaches the separate encoder writer -
# this isolates the guard's own runProcess/runGuard writer as the code under
# test. Every stdin write touches FM_MOCK_EPIPE_MARKER before emitting, so the
# test can assert the EPIPE path was actually exercised.
write_epipe_loader() {
  local dir=$1
  cat > "$dir/mock-loader.mjs" <<'EOF'
import { register } from "node:module";
register("./cp-hook.mjs", import.meta.url);
EOF
  cat > "$dir/cp-hook.mjs" <<'EOF'
export async function load(url, context, nextLoad) {
  if (url === "node:child_process") {
    const source = `
      import { EventEmitter } from "node:events";
      import { appendFileSync } from "node:fs";
      const CLOSE = Number(process.env.FM_MOCK_CLOSE_CODE ?? "0");
      const MARKER = process.env.FM_MOCK_EPIPE_MARKER;
      function raiseEpipe(stdin) {
        if (MARKER) appendFileSync(MARKER, "epipe\\n");
        const err = new Error("write EPIPE");
        err.code = "EPIPE";
        stdin.emit("error", err);
      }
      export function spawn() {
        const child = new EventEmitter();
        const stdin = new EventEmitter();
        stdin.end = () => { queueMicrotask(() => raiseEpipe(stdin)); };
        stdin.write = stdin.end;
        child.stdin = stdin;
        child.stdout = new EventEmitter();
        child.stderr = new EventEmitter();
        queueMicrotask(() => { child.emit("close", CLOSE); });
        return child;
      }
      export function spawnSync() { return { status: 0, stdout: "", stderr: "" }; }
      export default { spawn, spawnSync };
    `;
    return { format: "module", shortCircuit: true, source };
  }
  return nextLoad(url, context);
}
EOF
}

test_opencode_guard_swallows_child_stdin_epipe() {
  local repo home marker out status
  repo="$TMP_ROOT/opencode-epipe-root"
  home="$TMP_ROOT/opencode-epipe-home"
  marker="$TMP_ROOT/opencode-epipe.marker"
  mkdir -p "$repo/.opencode/plugins/lib" "$repo/bin" "$home/state"
  write_epipe_loader "$repo"
  cp "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$repo/.opencode/plugins/"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$repo/.opencode/plugins/lib/"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$repo/bin/fm-turnend-guard.sh"
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  cat > "$repo/drive.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.GUARD).href);
const hooks = await mod.FmPrimaryTurnendGuard({
  client: { session: { promptAsync: async () => {} } },
  directory: process.env.WT,
  worktree: process.env.WT,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "epipe-session" } } });
await new Promise((resolve) => setTimeout(resolve, 50));
console.log("SURVIVED");
EOF
  out=$(FM_HOME="$home" FM_MOCK_EPIPE_MARKER="$marker" \
    GUARD="$repo/.opencode/plugins/fm-primary-turnend-guard.js" WT="$repo" \
    node --import "$repo/mock-loader.mjs" "$repo/drive.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "OpenCode guard must survive a child-stdin EPIPE: $out"
  assert_contains "$out" "SURVIVED" "OpenCode guard did not complete after the child-stdin EPIPE"
  [ -s "$marker" ] || fail "OpenCode guard test never raised the EPIPE it claims to swallow"
  pass "OpenCode turn-end guard swallows a child-stdin EPIPE without crashing the host"
}

test_pi_guard_swallows_child_stdin_epipe() {
  local repo home marker out status
  repo="$TMP_ROOT/pi-epipe-root"
  home="$TMP_ROOT/pi-epipe-home"
  marker="$TMP_ROOT/pi-epipe.marker"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  write_epipe_loader "$repo"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$repo/bin/fm-turnend-guard.sh"
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  cat > "$repo/drive.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.GUARD).href);
let settled = null;
const pi = {
  on(name, handler) {
    if (name === "agent_settled") settled = handler;
    return () => {};
  },
  sendUserMessage: async () => {},
  sendMessage: () => {},
};
mod.default(pi);
if (!settled) {
  console.error("Pi guard did not register an agent_settled handler");
  process.exit(3);
}
await settled();
await new Promise((resolve) => setTimeout(resolve, 50));
console.log("SURVIVED");
EOF
  out=$(FM_HOME="$home" FM_MOCK_EPIPE_MARKER="$marker" \
    GUARD="$repo/.pi/extensions/fm-primary-turnend-guard.ts" \
    node --import "$repo/mock-loader.mjs" "$repo/drive.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "Pi guard must survive a child-stdin EPIPE: $out"
  assert_contains "$out" "SURVIVED" "Pi guard did not complete after the child-stdin EPIPE"
  [ -s "$marker" ] || fail "Pi guard test never raised the EPIPE it claims to swallow"
  pass "Pi turn-end guard swallows a child-stdin EPIPE without crashing the host"
}

test_opencode_guard_swallows_child_stdin_epipe
test_pi_guard_swallows_child_stdin_epipe
