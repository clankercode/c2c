import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const provider = fileURLToPath(new URL('./fixtures/t3-codex-provider.mjs', import.meta.url));

// All activity is an offline child-process wire exchange; no T3/server/model is
// launched. Deadlines only detect hangs; tests synchronize on protocol events.
async function fixture(t, { control = false, log = true, args = ['app-server'], env = {} } = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'c2c-codex-wire-'));
  const logPath = path.join(directory, 'calls.jsonl');
  const controlPath = path.join(directory, 'control.json');
  if (control) fs.writeFileSync(controlPath, '{}', { mode: 0o600 });
  const child = spawn(process.execPath, [provider, ...args], {
    env: { PATH: process.env.PATH, HOME: directory, CODEX_HOME: directory,
      ...(log ? { C2C_T3_FIXTURE_LOG: logPath } : {}),
      ...(control ? { C2C_T3_FIXTURE_CONTROL: controlPath } : {}), ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const inbox = [];
  const pending = new Set();
  let stderr = '';
  let stdout = '';
  let exitResult;
  let sequence = 0;
  let failure;
  child.stderr.on('data', (bytes) => { stderr += bytes.toString(); });
  const exited = new Promise((resolve) => child.once('close', (code, signal) => {
    exitResult = { code, signal };
    resolve(exitResult);
    for (const waiter of pending) waiter.reject(new Error(`Fixture exited: ${code}; ${stderr}`));
  }));
  child.on('error', (error) => {
    failure = error;
    for (const waiter of pending) waiter.reject(error);
  });
  child.stdin.on('error', () => {}); // A bounded-input rejection may close stdin.
  child.stdout.on('data', (bytes) => { stdout += bytes.toString(); });
  const lines = readline.createInterface({ input: child.stdout });
  lines.on('line', (line) => {
    if (args.includes('--version')) return;
    let message;
    try { message = JSON.parse(line); }
    catch (error) {
      failure = error;
      for (const waiter of pending) waiter.reject(error);
      return;
    }
    assert.equal(message.jsonrpc, '2.0');
    const waiter = [...pending].find((entry) => entry.matches(message));
    if (waiter) waiter.resolve(message);
    else inbox.push(message);
  });
  t.after(async () => {
    for (const waiter of pending) waiter.reject(new Error('Fixture cleanup'));
    if (!exitResult) {
      child.stdin.end();
      const deadline = setTimeout(() => child.kill('SIGKILL'), 1000);
      await exited;
      clearTimeout(deadline);
    }
    lines.close();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  function waitFor(matches) {
    if (failure) return Promise.reject(failure);
    const index = inbox.findIndex(matches);
    if (index !== -1) return Promise.resolve(inbox.splice(index, 1)[0]);
    if (exitResult) return Promise.reject(new Error(`Fixture already exited: ${stderr}`));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => waiter.reject(new Error('Fixture response deadline')), 4000);
      const waiter = { matches, resolve: (message) => {
        clearTimeout(timer); pending.delete(waiter); resolve(message);
      }, reject: (error) => { clearTimeout(timer); pending.delete(waiter); reject(error); } };
      pending.add(waiter);
    });
  }
  function request(method, params = {}, id = ++sequence) {
    const response = waitFor((message) => message.id === id);
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    return response;
  }
  async function ok(method, params, id) {
    const message = await request(method, params, id);
    assert.equal(message.error, undefined, JSON.stringify(message.error));
    return message.result;
  }
  return { child, directory, logPath, controlPath, exited, inbox, waitFor, request, ok,
    notify: (method) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method })}\n`),
    next: (method, predicate = () => true) => waitFor((message) => message.method === method && predicate(message.params)),
    control: (value) => fs.writeFileSync(controlPath, JSON.stringify(value), { mode: 0o600 }),
    journal: () => fs.readFileSync(logPath, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse),
    stderr: () => stderr, stdout: () => stdout };
}

async function initialized(t, options) {
  const peer = await fixture(t, options);
  const result = await peer.ok('initialize', { clientInfo: { name: 'c2c-fixture-test', version: '1' } }, 'init');
  assert.equal(result.userAgent, 'c2c-codex-fixture/0.145.0');
  peer.notify('initialized');
  return peer;
}

async function startThread(peer) {
  const result = await peer.ok('thread/start', { cwd: peer.directory, model: 'c2c-fixture' });
  assert.equal(result.thread.parentThreadId, null);
  assert.equal(result.thread.sessionId, result.thread.id);
  assert.equal(result.thread.projectId, null);
  assert.equal(result.thread.gitInfo, null);
  assert.equal(result.thread.status.type, 'idle');
  assert.equal(result.approvalsReviewer, 'auto_review');
  return result.thread.id;
}

async function turn(peer, threadId, text) {
  return (await peer.ok('turn/start', { threadId, input: [{ type: 'text', text }] })).turn;
}

async function completed(peer, threadId, turnId) {
  return (await peer.next('turn/completed', (params) => params.threadId === threadId && params.turn.id === turnId)).params.turn;
}

test('offline app-server advertises one synthetic model and explicit unsupported methods', async (t) => {
  const peer = await initialized(t);
  assert.deepEqual(await peer.ok('account/read'), { account: { type: 'apiKey' }, requiresOpenaiAuth: false });
  const catalog = await peer.ok('model/list');
  assert.equal(catalog.data.length, 1);
  assert.equal(catalog.data[0].id, 'c2c-fixture');
  assert.equal(catalog.nextCursor, null);
  assert.deepEqual(await peer.ok('skills/list'), { data: [] });
  for (const method of ['account/rateLimits/read', 'do-not-exist']) {
    assert.equal((await peer.request(method)).error.code, -32601);
    assert(peer.journal().some((row) => row.method === method));
  }
  assert.equal((await peer.request('initialize')).error.message, 'Already initialized');
});

test('threads, turns, resume/read, and request ids are isolated', async (t) => {
  const peer = await initialized(t);
  const first = await startThread(peer);
  const second = await startThread(peer);
  assert.notEqual(first, second);
  assert.equal((await peer.ok('thread/read', { threadId: second, includeTurns: false }, 0)).thread.id, second);
  const firstTurn = await turn(peer, first, 'C2C_FIXTURE:success private-input-sentinel');
  const secondTurn = await turn(peer, second, 'C2C_FIXTURE:success');
  assert.notEqual(firstTurn.id, secondTurn.id);
  assert.equal((await completed(peer, first, firstTurn.id)).status, 'completed');
  assert.equal((await completed(peer, second, secondTurn.id)).status, 'completed');
  assert.equal((await peer.ok('thread/resume', { threadId: first, excludeTurns: true })).thread.turns.length, 0);
  const read = await peer.ok('thread/read', { threadId: first, includeTurns: true });
  assert.equal(read.thread.turns.length, 1);
  assert.equal(read.thread.turns[0].items[0].text, 'C2C_FIXTURE_SUCCESS');
  assert.deepEqual(await peer.ok('thread/unsubscribe', { threadId: first }), { status: 'unsubscribed' });
  assert.equal(fs.statSync(peer.logPath).mode & 0o777, 0o600);
  assert.equal(fs.readFileSync(peer.logPath, 'utf8').includes('private-input-sentinel'), false);
  peer.child.stdin.end();
  assert.equal((await peer.exited).code, 0, 'EOF closes the provider without a lingering watcher');
});

for (const [scenario, code, phrase] of [
  ['availability', 'flexUnavailable', 'temporarily unavailable'],
  ['text-only', null, 'temporarily unavailable'],
  ['code-only', 'serverOverloaded', 'Upstream capacity exhausted'],
  ['auth', 'unauthorized', 'Authentication failed'],
  ['usage', 'usageLimitExceeded', 'Usage limit exceeded'],
]) {
  test(`${scenario} fails the current root turn, then literal Continue recovers`, async (t) => {
    const peer = await initialized(t);
    const threadId = await startThread(peer);
    const first = await turn(peer, threadId, `C2C_FIXTURE:${scenario}`);
    const terminal = await completed(peer, threadId, first.id);
    assert.equal(terminal.status, 'failed');
    assert.equal(terminal.error.codexErrorInfo, code);
    assert(terminal.error.message.includes(phrase));
    assert.equal(terminal.error.additionalDetails, null);
    const notification = await peer.next('error', (params) => params.turnId === first.id);
    assert.equal(notification.params.willRetry, false);
    const continued = await turn(peer, threadId, 'Continue');
    assert.equal((await completed(peer, threadId, continued.id)).status, 'completed');
    const final = await peer.ok('thread/read', { threadId, includeTurns: true });
    assert.equal(final.thread.turns[1].items[0].text, 'C2C_FIXTURE_RECOVERED');
    assert(peer.journal().some((row) => row.method === 'turn/start' && row.continuation));
  });
}

for (const scenario of ['child-failure', 'mixed']) {
  test(`${scenario} emits real native child activity with its own failed turn`, async (t) => {
    const peer = await initialized(t);
    const threadId = await startThread(peer);
    const rootTurn = await turn(peer, threadId, `C2C_FIXTURE:${scenario}`);
    const activity = await peer.next('item/completed', (params) => params.item.type === 'subAgentActivity');
    const childId = activity.params.item.agentThreadId;
    assert.notEqual(childId, threadId);
    const started = await peer.next('turn/started', (params) => params.threadId === childId);
    const child = await completed(peer, childId, started.params.turn.id);
    assert.equal(child.status, 'failed');
    assert.equal(child.error.codexErrorInfo, 'flexUnavailable');
    const root = await completed(peer, threadId, rootTurn.id);
    assert.equal(root.status, scenario === 'mixed' ? 'failed' : 'completed');
    if (scenario === 'mixed') assert.equal(root.error.codexErrorInfo, 'unauthorized');
    const snapshot = await peer.ok('thread/resume', { threadId: childId });
    assert.equal(snapshot.thread.parentThreadId, threadId);
    assert.equal(snapshot.thread.source.subAgent.thread_spawn.parent_thread_id, threadId);
  });
}

test('mixed-root replaces a transient root retry with a terminal authentication failure', async (t) => {
  const peer = await initialized(t);
  const threadId = await startThread(peer);
  const rootTurn = await turn(peer, threadId, 'C2C_FIXTURE:mixed-root');
  const retry = await peer.next('error', (params) => params.turnId === rootTurn.id && params.willRetry);
  assert.equal(retry.params.error.codexErrorInfo, 'flexUnavailable');
  const terminal = await completed(peer, threadId, rootTurn.id);
  assert.equal(terminal.status, 'failed');
  assert.equal(terminal.error.codexErrorInfo, 'unauthorized');
  assert.match(terminal.error.message, /Authentication failed/);
  const failure = await peer.next('error', (params) => params.turnId === rootTurn.id && !params.willRetry);
  assert.equal(failure.params.error.codexErrorInfo, 'unauthorized');
});

test('hold persists across steer and releases only through explicit scratch control', async (t) => {
  const peer = await initialized(t, { control: true });
  const threadId = await startThread(peer);
  const active = await turn(peer, threadId, 'C2C_FIXTURE:hold');
  assert.deepEqual(await peer.ok('turn/steer', { threadId, expectedTurnId: active.id,
    input: [{ type: 'text', text: 'c2c inbound fixture' }] }), { turnId: active.id });
  const snapshot = await peer.ok('thread/read', { threadId, includeTurns: true });
  assert.equal(snapshot.thread.status.type, 'active');
  assert.equal(snapshot.thread.turns[0].status, 'inProgress');
  peer.control({ action: 'complete' });
  const terminal = await completed(peer, threadId, active.id);
  assert.equal(terminal.status, 'completed');
  assert.equal(terminal.items.at(-1).text, 'C2C_FIXTURE_RELEASED');
  peer.child.stdin.end();
  assert.equal((await peer.exited).code, 0);
});

test('interrupt validates the exact active turn and terminalizes it once', async (t) => {
  const peer = await initialized(t);
  const threadId = await startThread(peer);
  const active = await turn(peer, threadId, 'C2C_FIXTURE:hold');
  assert.equal((await peer.request('turn/interrupt', { threadId, turnId: 'wrong' })).error.code, -32602);
  await peer.ok('turn/interrupt', { threadId, turnId: active.id });
  assert.equal((await completed(peer, threadId, active.id)).status, 'interrupted');
  assert.equal((await peer.request('turn/interrupt', { threadId, turnId: active.id })).error.code, -32602);
});

for (const scenario of ['retry', 'update']) {
  test(`${scenario} updates the same native error/turn from retrying to terminal`, async (t) => {
    const peer = await initialized(t, { control: true });
    const threadId = await startThread(peer);
    const active = await turn(peer, threadId, `C2C_FIXTURE:${scenario}`);
    const retry = await peer.next('error', (params) => params.turnId === active.id);
    assert.equal(retry.params.willRetry, true);
    assert.equal((await peer.ok('thread/read', { threadId })).thread.turns[0].status, 'inProgress');
    peer.control({ action: 'fail' });
    const failure = await peer.next('error', (params) => params.turnId === active.id && !params.willRetry);
    assert.equal(failure.params.error.codexErrorInfo, 'flexUnavailable');
    assert.equal((await completed(peer, threadId, active.id)).status, 'failed');
    const read = await peer.ok('thread/read', { threadId });
    assert.equal(read.thread.turns.length, 1);
    assert.equal(read.thread.turns[0].id, active.id);
  });
}

test('invalid framing, oversized input, and unsafe log paths fail explicitly', async (t) => {
  const peer = await fixture(t);
  const parseError = peer.waitFor((message) => message.id === null);
  peer.child.stdin.write('not-json\n');
  assert.equal((await parseError).error.code, -32700);
  assert.equal((await peer.request('thread/start')).error.code, -32002);
  await peer.ok('initialize');
  peer.child.stdin.write(`${' '.repeat(1024 * 1024 + 1)}\n`);
  assert.equal((await peer.exited).code, 2);
  assert.match(peer.stderr(), /input line bound reached/);

  const unsafe = await fixture(t, { env: { C2C_T3_FIXTURE_LOG: 'relative-file' } });
  assert.equal((await unsafe.exited).code, 2);
  assert.match(unsafe.stderr(), /invalid scratch configuration/);
});

test('version probing does not start an app-server or create scratch state', async (t) => {
  const peer = await fixture(t, { args: ['--version'] });
  assert.equal((await peer.exited).code, 0);
  // The version line is intentionally plain CLI output, rather than JSON-RPC.
  assert.equal(peer.stdout(), 'codex-cli 0.145.0 (c2c offline fixture)\n');
  assert.equal(fs.existsSync(peer.logPath), false);
});
