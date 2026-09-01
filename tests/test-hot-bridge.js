#!/usr/bin/env node
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const [bridge, fake] = process.argv.slice(2);
if (!bridge || !fake) throw new Error('usage: test-hot-bridge.js BRIDGE FAKE_CODEX');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-hot-bridge-test.'));
const runtime = path.join(root, 'runtime');
const commands = path.join(runtime, 'Commands');
const account = path.join(root, 'account');
fs.mkdirSync(commands, { recursive: true, mode: 0o700 });
fs.mkdirSync(account, { recursive: true, mode: 0o700 });
fs.writeFileSync(path.join(account, 'auth.json'), JSON.stringify({
  auth_mode: 'chatgpt',
  tokens: { access_token: 'test-access', account_id: 'acct-test', refresh_token: 'test-refresh' }
}), { mode: 0o600 });

const child = spawn(bridge, ['app-server', '--stdio'], {
  env: {
    ...process.env,
    CODEX_SWITCHBOARD_OFFICIAL_CLI: fake,
    CODEX_SWITCHBOARD_RUNTIME_DIR: runtime,
    CODEX_SWITCHBOARD_TEST_AUTH_ROOT: root
  },
  stdio: ['pipe', 'pipe', 'pipe']
});
let output = '';
let errors = '';
child.stdout.on('data', data => { output += data.toString(); });
child.stderr.on('data', data => { errors += data.toString(); });

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const messages = () => output.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
async function waitFor(check, label, timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (check()) return;
    await delay(20);
  }
  throw new Error(`timeout waiting for ${label}\nstdout=${output}\nstderr=${errors}`);
}
async function command(id, value) {
  fs.writeFileSync(path.join(commands, `request-${id}.json`), JSON.stringify(value), { mode: 0o600 });
  const response = path.join(commands, `response-${id}.json`);
  await waitFor(() => fs.existsSync(response), `response ${id}`);
  return JSON.parse(fs.readFileSync(response, 'utf8'));
}

(async () => {
  child.stdin.write(JSON.stringify({ id: 1, method: 'initialize', params: { clientInfo: { name: 'desktop' } } }) + '\n');
  await waitFor(() => output.includes('"id":1'), 'initialize response');
  await waitFor(() => {
    if (!fs.existsSync(path.join(runtime, 'status.json'))) return false;
    return JSON.parse(fs.readFileSync(path.join(runtime, 'status.json'), 'utf8')).ready === true;
  }, 'ready after initialize response');
  const committed = await command('commit-old', { command: 'commit', profileID: 'profile-old' });
  if (!committed.ok) throw new Error(`commit failed: ${JSON.stringify(committed)}`);
  child.stdin.write(JSON.stringify({ id: 2, method: 'turn/start', params: { threadId: 'thread-test', input: [{ type: 'text', text: 'trigger-delayed-limit' }] } }) + '\n');
  await waitFor(() => messages().some(message => message.method === 'turn/started'), 'delayed turn start');
  const switchedBeforeLimit = await command('switch-before-limit', {
    command: 'switch', authPath: path.join(account, 'auth.json'), profileID: 'profile-test', plan: 'plus'
  });
  if (!switchedBeforeLimit.ok) throw new Error(`early switch failed: ${JSON.stringify(switchedBeforeLimit)}`);
  await waitFor(() => {
    if (!fs.existsSync(path.join(runtime, 'status.json'))) return false;
    const value = JSON.parse(fs.readFileSync(path.join(runtime, 'status.json'), 'utf8'));
    return value.pendingLimitThreadID === 'thread-test' && value.pendingLimitProfileID === 'profile-old';
  }, 'usage limit status');
  await waitFor(() => messages().some(message => message.method === 'account/updated'), 'account update');
  if (messages().some(message => message.params?.authMode === 'chatgptAuthTokens')) {
    throw new Error('external auth mode leaked to desktop');
  }
  await waitFor(() => messages().some(message => message.method === 'test/refreshReceived'), 'external token refresh');
  if (messages().some(message => message.method === 'account/chatgptAuthTokens/refresh')) throw new Error('refresh request leaked to desktop');
  child.stdin.write(JSON.stringify({ id: 3, method: 'getAuthStatus', params: { includeToken: true, refreshToken: false } }) + '\n');
  child.stdin.write(JSON.stringify({ id: 4, method: 'getAuthStatus', params: { includeToken: false, refreshToken: false } }) + '\n');
  await waitFor(() => output.includes('"id":3') && output.includes('"id":4'), 'desktop auth compatibility responses');
  const parsedMessages = messages();
  const authWithToken = parsedMessages.find(message => message.id === 3)?.result;
  const authWithoutToken = parsedMessages.find(message => message.id === 4)?.result;
  if (authWithToken?.authMethod !== 'chatgpt' || authWithToken?.authToken !== 'test-access') {
    throw new Error(`invalid compatible auth response: ${JSON.stringify(authWithToken)}`);
  }
  if (authWithoutToken?.authMethod !== 'chatgpt' || authWithoutToken?.authToken !== null) {
    throw new Error(`token leaked when not requested: ${JSON.stringify(authWithoutToken)}`);
  }
  child.stdin.write(JSON.stringify({ id: 5, method: 'turn/start', params: { threadId: 'thread-rate', input: [{ type: 'text', text: 'trigger-rate-update' }] } }) + '\n');
  await waitFor(() => {
    const value = JSON.parse(fs.readFileSync(path.join(runtime, 'status.json'), 'utf8'));
    return value.rateLimits?.primary?.usedPercent === 37 && value.rateLimits?.secondary?.usedPercent === 51;
  }, 'rate limit push');
  const continued = await command('continue', { command: 'continue', threadID: 'thread-test' });
  if (!continued.ok) throw new Error(`continue failed: ${JSON.stringify(continued)}`);
  await waitFor(() => output.includes('continued-turn'), 'continued turn events');
  const status = JSON.parse(fs.readFileSync(path.join(runtime, 'status.json'), 'utf8'));
  if (status.activeProfileID !== 'profile-test' || status.ready !== true) {
    throw new Error(`invalid status: ${JSON.stringify(status)}`);
  }
  child.stdin.end();
  await new Promise((resolve, reject) => {
    child.once('exit', code => code === 0 ? resolve() : reject(new Error(`bridge exit ${code}: ${errors}`)));
  });
  fs.rmSync(root, { recursive: true, force: true });
  process.stdout.write('hot bridge protocol test passed\n');
})().catch(error => {
  child.kill('SIGTERM');
  fs.rmSync(root, { recursive: true, force: true });
  console.error(error.stack || error);
  process.exit(1);
});
