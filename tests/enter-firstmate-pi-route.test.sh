#!/usr/bin/env bash
# The primary Pi route is qualified through the executable launcher and Pi owner.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/package/dist/core" "$TMP/package/node_modules/@earendil-works/pi-ai/dist" "$TMP/bin" "$TMP/home/.pi/agent" "$TMP/home/config"
cat > "$TMP/package/package.json" <<'EOF'
{"type":"module","version":"0.81.1"}
EOF
cat > "$TMP/package/dist/cli.js" <<'EOF'
#!/usr/bin/env node
if (process.argv[2] === '--version') console.log(process.env.FAKE_PI_VERSION || '0.81.1');
EOF
chmod +x "$TMP/package/dist/cli.js"
ln -s "$TMP/package/dist/cli.js" "$TMP/bin/pi"
cat > "$TMP/package/dist/core/model-runtime.js" <<'EOF'
export class ModelRuntime {
  static async create() { return new ModelRuntime(); }
  getModel(provider, id) {
    if (id !== (process.env.FAKE_MODEL || 'gpt-5.6-sol')) return undefined;
    if (provider !== (process.env.FAKE_PROVIDER || 'openai-codex') && !(process.env.FAKE_DUPLICATE === 'yes' && provider === 'opencode')) return undefined;
    return {provider, id, api:process.env.FAKE_API || 'openai-codex-responses',
      baseUrl:process.env.FAKE_BASE_URL || 'https://chatgpt.com/backend-api',
      thinkingLevelMap:{xhigh:process.env.FAKE_XHIGH || 'xhigh', max:process.env.FAKE_MAX || 'max'}};
  }
  getAvailableSnapshot() {
    if (process.env.FAKE_CATALOG === 'absent') return [];
    const rows = [{provider:process.env.FAKE_PROVIDER || 'openai-codex',id:process.env.FAKE_MODEL || 'gpt-5.6-sol'}];
    if (process.env.FAKE_DUPLICATE === 'yes') rows.push({provider:'opencode',id:process.env.FAKE_MODEL || 'gpt-5.6-sol'});
    return rows;
  }
  getProviderAuthStatus() { return {configured:process.env.FAKE_AUTH !== 'absent',source:process.env.FAKE_AUTH_SOURCE || 'stored'}; }
  isUsingOAuth() { return process.env.FAKE_OAUTH !== 'no'; }
}
EOF
cat > "$TMP/package/node_modules/@earendil-works/pi-ai/dist/models.js" <<'EOF'
export function getSupportedThinkingLevels() { return ['high','xhigh','max']; }
EOF
cp "$TMP/package/package.json" "$TMP/package/node_modules/@earendil-works/pi-ai/package.json"
CHECK="$ROOT/bin/fm-console-pi-check.mjs"
clean() { env -u OPENAI_API_KEY -u OPENCODE_API_KEY -u OPENROUTER_API_KEY -u AZURE_OPENAI_API_KEY "$@"; }
check() { HOME="$TMP/home" clean node "$CHECK" "$TMP/bin/pi" "$@"; }
expect_pending() {
  local out rc=0
  out=$(check "$@") || rc=$?
  [ "$rc" -ne 0 ] && [[ "$out" == PENDING:* ]] || { printf 'not ok - expected PENDING; got %s\n' "$out" >&2; exit 1; }
}
[ "$(FAKE_MODEL=gpt-5.6-sol check openai-codex gpt-5.6-sol xhigh 0.81.1)" = ROUTE_VERIFIED ]
[ "$(FAKE_MODEL=gpt-5.6-luna check openai-codex gpt-5.6-luna max 0.81.1)" = ROUTE_VERIFIED ]
[ "$(FAKE_MODEL=gpt-6-astra check openai-codex gpt-6-astra max 0.81.1)" = ROUTE_VERIFIED ]
[ "$(FAKE_DUPLICATE=yes check openai-codex gpt-5.6-sol xhigh 0.81.1)" = ROUTE_VERIFIED ]
for alias in opencode openrouter openai azure-openai-responses; do
  FAKE_PROVIDER="$alias" expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
done
FAKE_MODEL=gpt-5.6-luna expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
FAKE_CATALOG=absent expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
FAKE_XHIGH=high expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
FAKE_AUTH=absent expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
FAKE_OAUTH=no expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
FAKE_AUTH_SOURCE='env' expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
FAKE_API=openai-responses expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
FAKE_BASE_URL=https://api.openai.com/v1 expect_pending openai-codex gpt-5.6-sol xhigh 0.81.1
expect_pending openai-codex gpt-5.6-sol max 0.81.1
expect_pending openai-codex gpt-5.6-sol xhigh 0.82.0
expect_pending '' gpt-5.6-sol xhigh 0.81.1
rc=0
out=$(HOME="$TMP/home" OPENCODE_API_KEY=synthetic node "$CHECK" "$TMP/bin/pi" openai-codex gpt-5.6-sol xhigh 0.81.1) || rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *OPENCODE_API_KEY* ]] || { echo 'not ok - OpenCode key environment escaped refusal' >&2; exit 1; }
rc=0
out=$(HOME="$TMP/home" PI_PACKAGE_DIR="$TMP/other-package" clean node "$CHECK" "$TMP/bin/pi" openai-codex gpt-5.6-sol xhigh 0.81.1) || rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *PI_PACKAGE_DIR* ]] || { echo 'not ok - Pi package override escaped refusal' >&2; exit 1; }

# Exercise the launcher's persisted selection and its exact route grant.
FM_ENTRY_LIB=1 . "$ROOT/bin/enter-firstmate.sh"
unset OPENCODE_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY AZURE_OPENAI_API_KEY
export HOME="$TMP/home" FM_HOME="$TMP/home" PATH="$TMP/bin:$PATH"
printf 'pi-sol\n' > "$FM_HOME/config/console-profile"
printf 'pi-sol\n' > "$FM_HOME/config/console-qualified-profiles"
[[ $(console_profile_gate pi-sol) == PENDING:* ]] || { echo 'not ok - stale name grant became qualified' >&2; exit 1; }
printf '%s\n' 'pi-sol@pi@0.81.1@opencode/gpt-5.6-sol:xhigh@chatgpt-oauth' > "$FM_HOME/config/console-qualified-profiles"
[[ $(console_profile_gate pi-sol) == PENDING:* ]] || { echo 'not ok - alias provider grant became qualified' >&2; exit 1; }
printf '%s\n' 'pi-sol@pi@0.81.1@openai-codex/gpt-5.6-sol:xhigh@chatgpt-oauth' > "$FM_HOME/config/console-qualified-profiles"
[[ $(FAKE_MODEL=gpt-5.6-sol console_profile_gate pi-sol) == 'PENDING: exact Pi OAuth route verified; included-allowance-only spend is CNO'* ]]
[[ $(FAKE_MODEL=gpt-5.6-luna console_profile_gate pi-sol) == PENDING:* ]]
[[ $(console_profile_gate pi-luna-max) == PENDING:* ]] || { echo 'not ok - Sol grant qualified Luna' >&2; exit 1; }
[[ $(console_profile_gate pi-astra) == PENDING:* ]] || { echo 'not ok - Sol grant qualified Astra' >&2; exit 1; }
printf '%s\n' 'pi-luna-max@pi@0.81.1@openai-codex/gpt-5.6-luna:max@chatgpt-oauth' > "$FM_HOME/config/console-qualified-profiles"
[[ $(FAKE_MODEL=gpt-5.6-luna console_profile_gate pi-luna-max) == 'PENDING: exact Pi OAuth route verified; included-allowance-only spend is CNO'* ]]
printf '%s\n' 'pi-astra@pi@0.81.1@openai-codex/gpt-6-astra:max@chatgpt-oauth' > "$FM_HOME/config/console-qualified-profiles"
[[ $(FAKE_MODEL=gpt-6-astra console_profile_gate pi-astra) == 'PENDING: exact Pi OAuth route verified; included-allowance-only spend is CNO'* ]]
[ "$(console_profile_resolve)" = pi-sol ]
[[ $(console_harness_argv pi "$(console_profile_model pi-sol)" '' '' | tr '\n' ' ') == '--model openai-codex/gpt-5.6-sol:xhigh ' ]]
printf 'pi\n' > "$FM_HOME/config/crew-harness"
[ "$(FM_CONSOLE_PROFILE=pi-sol bash "$ROOT/bin/fm-harness.sh" crew)" = pi ]
[ "$(FM_CONSOLE_PROFILE=pi-astra bash "$ROOT/bin/fm-harness.sh" crew)" = pi ]
printf 'ok - provider, model, effort, OAuth, version and grant stay independent; spend CNO refuses\n'
