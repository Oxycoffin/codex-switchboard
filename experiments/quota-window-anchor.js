#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const readline = require('readline');

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) => {
  if (value.startsWith('--')) pairs.push([value.slice(2), all[index + 1]]);
  return pairs;
}, []));

const authPath = args.auth;
const outputPath = args.output;
const expectedEmail = args.email;
const earliestEpoch = Number(args.after || 0);
if (!authPath || !outputPath || !expectedEmail || !Number.isFinite(earliestEpoch)) {
  throw new Error('Required: --auth PATH --output PATH --email EMAIL --after EPOCH');
}

const result = {
  experiment: 'codex-five-hour-window-anchor',
  account: expectedEmail,
  model: 'gpt-5.6-luna',
  effort: 'low',
  earliestProbeAt: new Date(earliestEpoch * 1000).toISOString(),
  stage: 'scheduled',
  observations: [],
};

function persist() {
  result.updatedAt = new Date().toISOString();
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const temporary = `${outputPath}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, outputPath);
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function jwtEmail(file) {
  try {
    const auth = JSON.parse(fs.readFileSync(file));
    const segment = auth.tokens?.access_token?.split('.')[1];
    if (!segment) return null;
    const payload = JSON.parse(Buffer.from(segment.replace(/-/g, '+').replace(/_/g, '/'), 'base64'));
    return payload.email || payload['https://api.openai.com/profile']?.email || null;
  } catch {
    return null;
  }
}

function resolveAuthFile() {
  const candidates = [authPath, path.join(os.homedir(), '.codex/auth.json')];
  const profiles = path.join(os.homedir(), 'Library/Application Support/Codex Switchboard/Profiles');
  try {
    for (const id of fs.readdirSync(profiles)) candidates.push(path.join(profiles, id, 'Account/auth.json'));
  } catch {}
  const match = candidates.find(file => fs.existsSync(file) && jwtEmail(file) === expectedEmail);
  if (!match) throw new Error(`No stored session found for ${expectedEmail}`);
  return match;
}

class AppServer {
  constructor(home) {
    this.nextId = 1;
    this.pending = new Map();
    this.notifications = [];
    this.process = spawn('/Applications/ChatGPT.app/Contents/Resources/codex', ['app-server', '--stdio'], {
      env: { ...process.env, CODEX_HOME: home },
      stdio: ['pipe', 'pipe', 'ignore'],
    });
    readline.createInterface({ input: this.process.stdout }).on('line', line => {
      const message = JSON.parse(line);
      const pending = this.pending.get(String(message.id));
      if (pending) {
        this.pending.delete(String(message.id));
        message.error ? pending.reject(new Error(message.error.message)) : pending.resolve(message.result || {});
      } else if (message.method) {
        this.notifications.push(message);
      }
    });
  }

  request(method, params = {}, timeout = 20000) {
    return new Promise((resolve, reject) => {
      const id = String(this.nextId++);
      this.pending.set(id, { resolve, reject });
      this.process.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`Timeout: ${method}`));
      }, timeout);
    });
  }

  notify(method, params = {}) {
    this.process.stdin.write(`${JSON.stringify({ method, params })}\n`);
  }

  async waitFor(method, predicate, timeout = 120000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const index = this.notifications.findIndex(message => message.method === method && predicate(message.params));
      if (index >= 0) return this.notifications.splice(index, 1)[0].params;
      await sleep(50);
    }
    throw new Error(`Timeout waiting for ${method}`);
  }

  stop() {
    if (!this.process.killed) this.process.kill('SIGTERM');
  }
}

function codexLimit(response) {
  const snapshot = response.rateLimitsByLimitId?.codex || response.rateLimits;
  return snapshot ? {
    readAt: new Date().toISOString(),
    primary: snapshot.primary || null,
    secondary: snapshot.secondary || null,
    limitId: snapshot.limitId || null,
    limitReason: snapshot.rateLimitReachedType || null,
  } : { readAt: new Date().toISOString(), error: 'No Codex rate-limit snapshot' };
}

async function main() {
  persist();
  const waitMs = earliestEpoch * 1000 - Date.now() + 2500;
  if (waitMs > 0) await sleep(waitMs);

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-window-anchor.'));
  const home = path.join(root, 'home');
  fs.mkdirSync(home, { mode: 0o700 });
  fs.copyFileSync(resolveAuthFile(), path.join(home, 'auth.json'));
  fs.chmodSync(path.join(home, 'auth.json'), 0o600);

  const app = new AppServer(home);
  try {
    result.stage = 'waiting-for-clean-reset';
    persist();
    await app.request('initialize', {
      clientInfo: { name: 'codex-switchboard-quota-experiment', title: 'Quota window experiment', version: '1.0.0' },
      capabilities: { experimentalApi: true },
    });
    app.notify('initialized');
    const account = await app.request('account/read', { refreshToken: false });
    if (account.account?.email !== expectedEmail) {
      throw new Error(`Unexpected account: ${account.account?.email || 'none'}`);
    }

    let baseline;
    const resetDeadline = Date.now() + 15 * 60 * 1000;
    while (Date.now() < resetDeadline) {
      baseline = codexLimit(await app.request('account/rateLimits/read'));
      result.observations.push({ phase: 'pre-probe', ...baseline });
      persist();
      const primary = baseline.primary;
      if (primary && primary.usedPercent === 0) break;
      if (primary && primary.usedPercent > 0 && primary.resetsAt * 1000 > Date.now() + 60_000) {
        throw new Error('Experiment contaminated: another task opened the five-hour window before the probe.');
      }
      await sleep(5000);
    }
    if (!baseline?.primary || baseline.primary.usedPercent !== 0) {
      throw new Error('The five-hour window did not return to 0% within the observation period.');
    }

    result.stage = 'sending-minimal-probe';
    result.probeStartedAt = new Date().toISOString();
    persist();
    const threadResult = await app.request('thread/start', {
      cwd: root,
      model: 'gpt-5.6-luna',
      ephemeral: true,
      approvalPolicy: 'never',
      sandbox: 'read-only',
      developerInstructions: 'Return only the literal text OK. Do not call tools.',
    });
    const threadId = threadResult.thread?.id;
    if (!threadId) throw new Error('thread/start did not return a thread id');
    const turnResult = await app.request('turn/start', {
      threadId,
      model: 'gpt-5.6-luna',
      effort: 'low',
      input: [{ type: 'text', text: 'Reply exactly OK.' }],
      approvalPolicy: 'never',
      sandboxPolicy: { type: 'readOnly' },
    });
    const turnId = turnResult.turn?.id;
    const completed = await app.waitFor('turn/completed', params => params.threadId === threadId && params.turn?.id === turnId);
    result.probeCompletedAt = new Date().toISOString();
    result.probeStatus = completed.turn?.status || null;
    result.probeError = completed.turn?.error || null;
    if (result.probeStatus !== 'completed') throw new Error(`Probe turn ended as ${result.probeStatus}`);

    result.stage = 'observing-accounting';
    persist();
    const delays = [0, 5000, 15000, 40000, 60000];
    let elapsed = 0;
    for (const delay of delays) {
      await sleep(delay - elapsed);
      elapsed = delay;
      result.observations.push({
        phase: 'post-probe',
        secondsAfterCompletion: Math.round((Date.now() - Date.parse(result.probeCompletedAt)) / 1000),
        ...codexLimit(await app.request('account/rateLimits/read')),
      });
      persist();
    }
    const firstPost = result.observations.find(item => item.phase === 'post-probe' && item.primary?.resetsAt);
    result.inference = firstPost ? {
      resetAt: new Date(firstPost.primary.resetsAt * 1000).toISOString(),
      secondsFromProbeStart: firstPost.primary.resetsAt - Math.floor(Date.parse(result.probeStartedAt) / 1000),
      anchoredNearFiveHours: Math.abs(firstPost.primary.resetsAt - Math.floor(Date.parse(result.probeStartedAt) / 1000) - 18000) <= 180,
    } : { anchoredNearFiveHours: false, reason: 'No post-probe resetsAt observed' };
    result.stage = 'complete';
    persist();
  } catch (error) {
    result.stage = 'failed';
    result.error = error.message;
    persist();
    process.exitCode = 1;
  } finally {
    app.stop();
  }
}

main();
