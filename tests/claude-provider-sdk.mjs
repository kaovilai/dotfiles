// Use the SDK bundled in this installed T3 build. Initialization only: no prompt
// is yielded, so this checks real protocol compatibility without inference.
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { n as query } from '/Applications/T3 Code (Alpha).app/Contents/Resources/app.asar/apps/server/dist/claudeHistoryWorker-Cod2UZ5a.mjs';

const backend = process.argv[2];
if (!['copilot', 'vertex', 'openai', 'enmass'].includes(backend)) process.exit(2);
const cwd = await mkdtemp(join(tmpdir(), 'claude-sdk-bridge-'));
const abort = new AbortController();
let q;
const start = Date.now();
const timeout = setTimeout(() => abort.abort(), 25000);
try {
  q = query({
    prompt: (async function* () {
      await new Promise(resolve => {
        if (abort.signal.aborted) resolve();
        else abort.signal.addEventListener('abort', resolve, { once: true });
      });
    })(),
    options: {
      cwd,
      pathToClaudeCodeExecutable: join(process.env.HOME, '.local/bin', `claude-t3-${backend}`),
      abortController: abort,
      model: 't3-sonnet',
      settingSources: [],
      strictMcpConfig: true,
      mcpServers: {},
      env: { ...process.env, ENABLE_CLAUDEAI_MCP_SERVERS: 'false',
        CLAUDE_CODE_AUTO_CONNECT_IDE: '0', CLAUDE_CONFIG_DIR: cwd },
      stderr: () => {},
    },
  });
  const initialized = await q.initializationResult();
  console.log(JSON.stringify({ backend, initialized: true, seconds: (Date.now() - start) / 1000,
    modelCount: initialized.models?.length ?? 0 }));
} catch {
  // SDK errors may include transport settings; do not print raw exception data.
  console.error(JSON.stringify({ backend, initialized: false, seconds: (Date.now() - start) / 1000 }));
  process.exitCode = 1;
} finally {
  clearTimeout(timeout);
  abort.abort();
  q?.close();
  await rm(cwd, { recursive: true, force: true });
}
