#!/usr/bin/env node
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const [bridge, fake] = process.argv.slice(2);
if (!bridge || !fake) throw new Error('usage: test-auxiliary-passthrough.js BRIDGE FAKE_CODEX');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-auxiliary-test.'));
const child = spawn(bridge, ['app-server', '--stdio'], {
  env: {
    ...process.env,
    CODEX_SWITCHBOARD_OFFICIAL_CLI: fake,
    CODEX_SWITCHBOARD_FORCE_PASSTHROUGH: '1',
    CODEX_SWITCHBOARD_RUNTIME_DIR: path.join(root, 'runtime')
  },
  stdio: ['pipe', 'pipe', 'pipe']
});
let output = '';
child.stdout.on('data', data => { output += data.toString(); });
child.stdin.write(JSON.stringify({ id: 1, method: 'initialize', params: {} }) + '\n');
const deadline = Date.now() + 4000;
const timer = setInterval(() => {
  if (!output.includes('"id":1') && Date.now() < deadline) return;
  clearInterval(timer);
  child.kill('SIGTERM');
  const status = path.join(root, 'runtime/status.json');
  if (!output.includes('"id":1')) throw new Error(`passthrough did not respond: ${output}`);
  if (fs.existsSync(status)) throw new Error('auxiliary host claimed the shared bridge runtime');
  fs.rmSync(root, { recursive: true, force: true });
  process.stdout.write('auxiliary passthrough test passed\n');
}, 20);
