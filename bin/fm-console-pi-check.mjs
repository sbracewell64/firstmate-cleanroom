#!/usr/bin/env node
// Read-only qualification of the installed Pi provider route for the primary console.
// Pi's own model and auth runtime reads its normal stores; this script never reads
// or reports credential content. The launcher owns the account-specific grant.
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

function refuse(reason) {
  process.stdout.write(`PENDING: ${reason}\n`);
  process.exitCode = 1;
}

const [binary, provider, modelId, effort, version] = process.argv.slice(2);
const ids = new Map([
  ['gpt-5.6-luna', 'max'],
  ['gpt-5.6-sol', 'xhigh'],
  ['gpt-6-astra', 'max'],
]);
if (!binary || provider !== 'openai-codex' || !ids.has(modelId) || ids.get(modelId) !== effort || version !== '0.81.1') {
  refuse('Pi route tuple or installed version differs from the qualified tuple');
} else {
  const forbidden = Object.keys(process.env).filter((key) => process.env[key] &&
    (/^(OPENAI_|AZURE_OPENAI_|OPENCODE_|OPENROUTER_|PI_API_|PI_MODEL_|PI_PROVIDER_)/u.test(key) ||
      ['CHATGPT_BASE_URL', 'CODEX_RESPONSES_API_PROXY_URL', 'PI_PACKAGE_DIR'].includes(key)));
  if (forbidden.length) {
    refuse(`API, provider or endpoint environment override is present: ${forbidden.sort().join(', ')}`);
  } else {
    try {
      const cli = realpathSync(binary);
      const dist = dirname(cli);
      if (!cli.endsWith('/dist/cli.js')) throw Error('Pi binary is not the installed CLI');
      const installed = JSON.parse(readFileSync(join(dist, '../package.json'), 'utf8'));
      if (installed.version !== version) throw Error('Pi package version differs from the qualified version');
      const agentDir = process.env.PI_CODING_AGENT_DIR || join(process.env.HOME, '.pi', 'agent');
      if (resolve(agentDir) !== resolve(process.env.HOME, '.pi', 'agent')) throw Error('Pi auth owner is overridden');
      if (existsSync(join(agentDir, 'models.json'))) throw Error('custom Pi models.json needs separate qualification');
      const { ModelRuntime } = await import(pathToFileURL(join(dist, 'core/model-runtime.js')).href);
      const { getSupportedThinkingLevels } = await import(pathToFileURL(join(dist, '../node_modules/@earendil-works/pi-ai/dist/models.js')).href);
      const runtime = await ModelRuntime.create({
        authPath: join(agentDir, 'auth.json'),
        modelsPath: join(agentDir, 'models.json'),
        allowModelNetwork: false,
      });
      const selected = runtime.getModel(provider, modelId);
      const available = runtime.getAvailableSnapshot().some((item) => item.provider === provider && item.id === modelId);
      const auth = runtime.getProviderAuthStatus(provider);
      if (!selected || !available || selected.provider !== provider || selected.id !== modelId) throw Error('exact provider/model is absent from Pi catalog');
      if (selected.api !== 'openai-codex-responses' || selected.baseUrl !== 'https://chatgpt.com/backend-api') throw Error('provider transport or endpoint is not ChatGPT OAuth');
      if (!runtime.isUsingOAuth(provider) || !auth.configured || auth.source !== 'stored') throw Error('stored ChatGPT OAuth is unavailable');
      if (!getSupportedThinkingLevels(selected).includes(effort) || selected.thinkingLevelMap?.[effort] !== effort) throw Error('exact effort is unsupported or remapped');
      process.stdout.write('ROUTE_VERIFIED\n');
    } catch (error) {
      const known = new Set([
        'Pi binary is not the installed CLI',
        'Pi package version differs from the qualified version',
        'Pi auth owner is overridden',
        'custom Pi models.json needs separate qualification',
        'exact provider/model is absent from Pi catalog',
        'provider transport or endpoint is not ChatGPT OAuth',
        'stored ChatGPT OAuth is unavailable',
        'exact effort is unsupported or remapped',
      ]);
      refuse(error instanceof Error && known.has(error.message) ? error.message : 'Pi runtime qualification failed');
    }
  }
}
