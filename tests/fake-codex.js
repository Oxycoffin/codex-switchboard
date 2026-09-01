#!/usr/bin/env node
const readline = require('readline');
let experimental = false;
let authMode = 'chatgpt';
const send = (value) => process.stdout.write(JSON.stringify(value) + '\n');
const input = readline.createInterface({ input: process.stdin });
input.on('line', (line) => {
  const message = JSON.parse(line);
  if (message.method === 'initialize') {
    experimental = message.params?.capabilities?.experimentalApi === true;
    send({ id: message.id, result: { userAgent: 'fake-codex/1.0' } });
  } else if (message.method === 'account/login/start') {
    if (!experimental) {
      send({ id: message.id, error: { code: -1, message: 'experimentalApi missing' } });
      return;
    }
    authMode = 'chatgptAuthTokens';
    send({ id: message.id, result: { type: 'chatgptAuthTokens' } });
    send({ method: 'account/login/completed', params: { loginId: null, success: true, error: null } });
    send({ method: 'account/updated', params: { authMode: 'chatgptAuthTokens', planType: message.params.chatgptPlanType } });
    send({ id: 99, method: 'account/chatgptAuthTokens/refresh', params: { reason: 'unauthorized', previousAccountId: 'acct-test' } });
  } else if (message.method === 'getAuthStatus') {
    send({ id: message.id, result: {
      authMethod: authMode,
      authToken: message.params?.includeToken ? 'test-access' : null,
      requiresOpenaiAuth: true
    } });
  } else if (message.method === 'account/read') {
    send({ id: message.id, result: { account: { email: 'test@example.com', planType: 'plus' } } });
  } else if (message.method === 'turn/start') {
    if (message.params.input?.[0]?.text === 'trigger-rate-update') {
      send({ id: message.id, result: { turn: { id: 'rate-turn', status: 'inProgress', items: [], error: null } } });
      send({ method: 'account/rateLimits/updated', params: { rateLimits: {
        primary: { usedPercent: 37, windowDurationMins: 300, resetsAt: 2000000000 },
        secondary: { usedPercent: 51, windowDurationMins: 10080, resetsAt: 2000100000 },
        planType: 'plus'
      } } });
      send({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'rate-turn', status: 'completed', error: null } } });
      return;
    }
    if (message.params.input?.[0]?.text === 'trigger-limit') {
      send({ id: message.id, result: { turn: { id: 'limited-turn', status: 'inProgress', items: [], error: null } } });
      send({ method: 'turn/started', params: { threadId: message.params.threadId, turn: { id: 'limited-turn', status: 'inProgress' } } });
      send({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'limited-turn', status: 'failed', error: { message: 'limit', codexErrorInfo: 'usageLimitExceeded' } } } });
      return;
    }
    if (message.params.input?.[0]?.text === 'trigger-delayed-limit') {
      send({ id: message.id, result: { turn: { id: 'delayed-limited-turn', status: 'inProgress', items: [], error: null } } });
      send({ method: 'turn/started', params: { threadId: message.params.threadId, turn: { id: 'delayed-limited-turn', status: 'inProgress' } } });
      setTimeout(() => send({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'delayed-limited-turn', status: 'failed', error: { message: 'limit', codexErrorInfo: 'usageLimitExceeded' } } } }), 200);
      return;
    }
    send({ id: message.id, result: { turn: { id: 'continued-turn', status: 'inProgress', items: [], error: null } } });
    send({ method: 'turn/started', params: { threadId: message.params.threadId, turn: { id: 'continued-turn', status: 'inProgress' } } });
    send({ method: 'turn/completed', params: { threadId: message.params.threadId, turn: { id: 'continued-turn', status: 'completed', error: null } } });
  } else if (message.id === 99 && message.result?.accessToken === 'test-access') {
    send({ method: 'test/refreshReceived', params: { ok: true } });
  }
});
