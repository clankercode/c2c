#!/usr/bin/env node
// Synthetic, offline Codex app-server for the unmodified T3 compatibility probe.
// Never forwards a request, reads provider credentials, or executes prompt text.
// Run as the Codex binary (app-server [flags]) or directly with newline JSON-RPC.
// C2C_FIXTURE:<scenario> in the first turn selects the deterministic behavior.
// hold/retry/update require C2C_T3_FIXTURE_CONTROL for an explicit transition:
// {"action":"complete"|"fail", "threadId"?:"...", "message"?:"...", "code"?:"..."}.
// A missing threadId is accepted only when exactly one held turn exists.
// Controls are applied once per distinct file content; add a nonce to repeat one.
// Only C2C_T3_FIXTURE_LOG and C2C_T3_FIXTURE_CONTROL name scratch files we access.
//
// Thread/turn wire shapes are adapted from T3 Code's codexMultiAgentWire.json,
// captured with codex-cli 0.145.0. The fixture has no runtime T3 source dependency.
// Copyright (c) 2026 T3 Tools Inc. (MIT-licensed reference wire fixture).
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions: The above copyright notice and this
// permission notice shall be included in all copies or substantial portions of
// the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const MAX_LINE = 1024 * 1024;
const MAX_REQUESTS = 4096;
const MAX_THREADS = 128;
const MAX_TURNS = 64;
const MAX_OUTPUT = 8 * 1024 * 1024;
const MAX_LOG = 1024 * 1024;
const MAX_CONTROL = 4096;
const MODEL = 'c2c-fixture';
const scenarios = new Set(['availability', 'text-only', 'code-only', 'auth', 'usage',
  'child-failure', 'mixed', 'mixed-root', 'hold', 'retry', 'update', 'success']);
const codes = new Set(['contextWindowExceeded', 'sessionBudgetExceeded', 'usageLimitExceeded',
  'rateLimitExceeded', 'flexUnavailable', 'serverOverloaded', 'cyberPolicy',
  'misalignmentPolicyViolation', 'tooManyDenials', 'internalServerError', 'unauthorized',
  'badRequest', 'threadRollbackFailed', 'sandboxError', 'other']);
const now = () => Math.floor(Date.now() / 1000);
const hash = (text) => crypto.createHash('sha256').update(text).digest('hex');
const threads = new Map();
let outputBytes = 0;
let requestCount = 0;
let initialized = false;
let pending = Buffer.alloc(0);
let stopping = false;
let logFd;
let watcher;
let lastControl;

function write(value) {
  if (stopping) return;
  const line = `${JSON.stringify({ jsonrpc: '2.0', ...value })}\n`;
  outputBytes += Buffer.byteLength(line);
  if (outputBytes > MAX_OUTPUT) return fatal('output bound reached');
  process.stdout.write(line);
}

function fatal(reason) {
  if (stopping) return;
  stopping = true;
  process.stderr.write(`c2c Codex fixture: ${reason}\n`);
  process.exitCode = 2;
  process.stdin.pause();
  watcher?.close();
  if (logFd !== undefined) { fs.closeSync(logFd); logFd = undefined; }
  process.stdin.destroy();
}

function journal(value) {
  if (logFd === undefined || stopping) return;
  const line = `${JSON.stringify({ timestamp: Date.now(), pid: process.pid, ...value })}\n`;
  if (fs.fstatSync(logFd).size + Buffer.byteLength(line) > MAX_LOG) {
    return fatal('journal bound reached');
  }
  fs.writeSync(logFd, line);
}

function scratchPath(name) {
  const value = process.env[name];
  if (value === undefined) return undefined;
  if (!path.isAbsolute(value)) throw new Error('scratch path must be absolute');
  const parent = fs.lstatSync(path.dirname(value));
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== process.getuid()) {
    throw new Error('scratch directory must be owned by this user');
  }
  return value;
}

function openJournal(filename) {
  const fd = fs.openSync(filename, fs.constants.O_CREAT | fs.constants.O_APPEND |
    fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK, 0o600);
  const stat = fs.fstatSync(fd);
  if (!stat.isFile() || stat.uid !== process.getuid() || stat.nlink !== 1 ||
      (stat.mode & 0o077) !== 0 || stat.size > MAX_LOG) {
    fs.closeSync(fd);
    throw new Error('journal must be a bounded private regular file');
  }
  return fd;
}

function reply(id, result) { write({ id, result }); }
function reject(id, code, message) { write({ id, error: { code, message } }); }
function notify(method, params) { write({ method, params }); }

function newThread({ id = crypto.randomUUID(), cwd = process.cwd(), parent = null } = {}) {
  if (threads.size >= MAX_THREADS) throw new Error('thread bound reached');
  const thread = {
    id, extra: null, sessionId: id, forkedFromId: null, parentThreadId: parent,
    preview: '', projectId: null, ephemeral: false, historyMode: 'legacy',
    model: MODEL, reasoningEffort: 'low', modelProvider: 'openai',
    createdAt: now(), updatedAt: now(), recencyAt: now(), status: { type: 'idle' },
    path: `/fixtures/c2c-codex/${id}.jsonl`, cwd, cliVersion: '0.145.0',
    source: parent === null ? 'appServer' : { subAgent: { thread_spawn: {
      parent_thread_id: parent, depth: 1, agent_path: '/root/fixture-child',
    } } },
    canAcceptDirectInput: parent === null, threadSource: null,
    agentNickname: parent === null ? null : 'fixture-child',
    agentRole: null, gitInfo: null, name: null, turns: [],
  };
  const state = { thread, scenario: null, active: null, held: false };
  threads.set(id, state);
  return state;
}

function threadResponse(state, excludeTurns = false) {
  return { thread: { ...state.thread, turns: excludeTurns ? [] : state.thread.turns },
    model: MODEL, modelProvider: 'openai', serviceTier: 'default', cwd: state.thread.cwd,
    runtimeWorkspaceRoots: [state.thread.cwd], instructionSources: [],
    approvalPolicy: 'on-request', approvalsReviewer: 'auto_review',
    sandbox: { type: 'workspaceWrite', writableRoots: [], networkAccess: false,
      excludeTmpdirEnvVar: false, excludeSlashTmp: false },
    activePermissionProfile: null, reasoningEffort: 'low', multiAgentMode: 'explicitRequestOnly' };
}

function startTurn(state) {
  if (state.thread.turns.length >= MAX_TURNS) throw new Error('turn bound reached');
  const turn = { id: crypto.randomUUID(), items: [], itemsView: 'notLoaded',
    status: 'inProgress', error: null, startedAt: now(), completedAt: null, durationMs: null };
  state.thread.turns.push(turn);
  state.active = turn;
  state.thread.status = { type: 'active', activeFlags: [] };
  state.thread.updatedAt = now();
  return turn;
}

function announceStart(state) {
  notify('thread/status/changed', { threadId: state.thread.id, status: state.thread.status });
  notify('turn/started', { threadId: state.thread.id, turn: state.active });
}

function agentMessage(state, text, phase = 'final_answer') {
  const item = { type: 'agentMessage', id: crypto.randomUUID(), text, phase };
  state.active.items.push(item);
  const common = { threadId: state.thread.id, turnId: state.active.id, item };
  notify('item/started', { ...common, startedAtMs: Date.now() });
  notify('item/agentMessage/delta', { threadId: state.thread.id, turnId: state.active.id,
    itemId: item.id, delta: text });
  notify('item/completed', { ...common, completedAtMs: Date.now() });
}

function availabilityError() {
  return { message: 'Model c2c-fixture is temporarily unavailable. Please try again later.',
    codexErrorInfo: 'flexUnavailable', additionalDetails: null };
}

function authenticationError() {
  return { message: 'Authentication failed: invalid API key.',
    codexErrorInfo: 'unauthorized', additionalDetails: null };
}

function failure(state, error, willRetry = false) {
  notify('error', { threadId: state.thread.id, turnId: state.active.id, error, willRetry });
  if (!willRetry) finish(state, 'failed', error);
}

function finish(state, status = 'completed', error = null) {
  const turn = state.active;
  if (turn === null) return;
  turn.status = status;
  turn.error = error;
  turn.completedAt = now();
  turn.durationMs = Math.max(0, (turn.completedAt - turn.startedAt) * 1000);
  notify('turn/completed', { threadId: state.thread.id, turn });
  state.active = null;
  state.held = false;
  state.thread.updatedAt = now();
  state.thread.recencyAt = now();
  state.thread.status = { type: 'idle' };
  notify('thread/status/changed', { threadId: state.thread.id, status: state.thread.status });
}

function childFailure(root, mixed) {
  const child = newThread({ cwd: root.thread.cwd, parent: root.thread.id });
  notify('thread/started', { thread: child.thread });
  const item = { type: 'subAgentActivity', id: crypto.randomUUID(), kind: 'started',
    agentThreadId: child.thread.id, agentPath: '/root/fixture-child' };
  root.active.items.push(item);
  notify('item/completed', { threadId: root.thread.id, turnId: root.active.id,
    item, completedAtMs: Date.now() });
  startTurn(child);
  announceStart(child);
  failure(child, availabilityError());
  if (mixed) failure(root, authenticationError());
  else { agentMessage(root, 'C2C_FIXTURE_HEALTHY_ROOT'); finish(root); }
}

function executeTurn(state, continuation) {
  if (continuation || state.thread.turns.length > 1) {
    agentMessage(state, continuation ? 'C2C_FIXTURE_RECOVERED' : 'C2C_FIXTURE_SUCCESS');
    finish(state);
    return;
  }
  switch (state.scenario) {
    case 'availability': failure(state, availabilityError()); break;
    case 'text-only': failure(state, { ...availabilityError(), codexErrorInfo: null }); break;
    case 'code-only': failure(state, { message: 'Upstream capacity exhausted.',
      codexErrorInfo: 'serverOverloaded', additionalDetails: null }); break;
    case 'auth': failure(state, authenticationError()); break;
    case 'usage': failure(state, { message: 'Usage limit exceeded. Try again later.',
      codexErrorInfo: 'usageLimitExceeded', additionalDetails: null }); break;
    case 'child-failure': childFailure(state, false); break;
    case 'mixed': childFailure(state, true); break;
    case 'mixed-root':
      failure(state, { ...availabilityError(), message: 'Reconnecting... 1/2',
        additionalDetails: availabilityError().message }, true);
      failure(state, authenticationError());
      break;
    case 'hold':
      state.held = true;
      agentMessage(state, 'C2C_FIXTURE_HOLDING', 'commentary');
      break;
    case 'retry':
    case 'update':
      state.held = true;
      failure(state, { ...availabilityError(), message: 'Reconnecting... 1/2',
        additionalDetails: availabilityError().message }, true);
      break;
    default: agentMessage(state, 'C2C_FIXTURE_SUCCESS'); finish(state);
  }
}

function inputText(params) {
  if (!Array.isArray(params?.input)) return '';
  return params.input.filter((item) => item?.type === 'text' && typeof item.text === 'string')
    .map((item) => item.text).join('\n');
}

function handle(message) {
  if (message === null || typeof message !== 'object' || Array.isArray(message) ||
      ![undefined, '2.0'].includes(message.jsonrpc) || typeof message.method !== 'string' ||
      !['undefined', 'string', 'number'].includes(typeof message.id) ||
      (typeof message.id === 'number' && !Number.isFinite(message.id))) {
    reject(null, -32600, 'Invalid Request');
    return;
  }
  if (++requestCount > MAX_REQUESTS) return fatal('request bound reached');
  const { id, method } = message;
  const params = message.params ?? {};
  const state = threads.get(params?.threadId);
  const text = inputText(params);
  journal({ method: method.slice(0, 128), ...(state ? { threadId: state.thread.id } : {}),
    ...(method === 'turn/start' || method === 'turn/steer' ?
      { inputBytes: Buffer.byteLength(text), inputHash: hash(text), continuation: text.trim() === 'Continue' } : {}) });
  if (stopping) return;
  if (id === undefined) {
    if (method !== 'initialized') journal({ method: 'fixture/unknown-notification', name: method.slice(0, 128) });
    return;
  }
  if (method === 'initialize') {
    if (initialized) return reject(id, -32600, 'Already initialized');
    initialized = true;
    reply(id, { userAgent: 'c2c-codex-fixture/0.145.0', codexHome: process.env.CODEX_HOME ?? '/fixtures/c2c-codex',
      platformFamily: 'unix', platformOs: 'linux' });
    return;
  }
  if (!initialized) return reject(id, -32002, 'Initialize first');
  if (method === 'account/read') return reply(id, { account: { type: 'apiKey' }, requiresOpenaiAuth: false });
  if (method === 'account/rateLimits/read') return reject(id, -32601, 'Rate limits unsupported by offline fixture');
  if (method === 'skills/list') return reply(id, { data: [] });
  if (method === 'model/list') return reply(id, { data: [{ id: MODEL, model: MODEL,
    displayName: 'c2c offline fixture', description: 'Synthetic provider; no model calls',
    hidden: false, isDefault: true, defaultReasoningEffort: 'low',
    supportedReasoningEfforts: [{ reasoningEffort: 'low', description: 'Synthetic' }],
    inputModalities: ['text'], supportsPersonality: false, upgrade: null,
    upgradeInfo: null, availabilityNux: null, additionalSpeedTiers: [],
    serviceTiers: [], defaultServiceTier: null, multiAgentVersion: 'v2' }], nextCursor: null });
  if (params === null || typeof params !== 'object' || Array.isArray(params)) {
    return reject(id, -32602, 'Invalid params');
  }
  if (method === 'thread/start') {
    if (params.cwd !== undefined && (typeof params.cwd !== 'string' || !path.isAbsolute(params.cwd))) {
      return reject(id, -32602, 'Absolute cwd required');
    }
    const created = newThread({ cwd: params.cwd });
    journal({ method: 'fixture/thread-created', threadId: created.thread.id });
    reply(id, threadResponse(created));
    notify('thread/started', { thread: created.thread });
    return;
  }
  if (method === 'thread/resume') {
    if (typeof params.threadId !== 'string' || !/^[a-zA-Z0-9-]{1,128}$/.test(params.threadId)) {
      return reject(id, -32602, 'Bounded threadId required');
    }
    const resumed = state ?? newThread({ id: params.threadId, cwd: params.cwd });
    reply(id, threadResponse(resumed, params.excludeTurns === true));
    return;
  }
  if (method === 'thread/read') {
    if (!state) return reject(id, -32602, 'Unknown fixture thread');
    return reply(id, { thread: threadResponse(state, params.includeTurns === false).thread });
  }
  if (method === 'thread/unsubscribe') {
    if (!state) return reject(id, -32602, 'Unknown fixture thread');
    return reply(id, { status: 'unsubscribed' });
  }
  if (method === 'turn/start') {
    if (!state || state.active !== null) return reject(id, -32602, 'Thread unavailable or already active');
    const marker = /\bC2C_FIXTURE:([a-z-]+)\b/.exec(text);
    if (marker && !scenarios.has(marker[1])) return reject(id, -32602, 'Unknown fixture scenario');
    if (state.scenario === null) state.scenario = marker?.[1] ?? 'success';
    const turn = startTurn(state);
    journal({ method: 'fixture/turn-created', threadId: state.thread.id,
      turnId: turn.id, scenario: state.scenario });
    reply(id, { turn });
    announceStart(state);
    executeTurn(state, text.trim() === 'Continue');
    return;
  }
  if (method === 'turn/steer') {
    if (!state?.active || params.expectedTurnId !== state.active.id) {
      return reject(id, -32602, 'Active turn changed');
    }
    // Steering does not release a held fixture: the harness controls completion.
    return reply(id, { turnId: state.active.id });
  }
  if (method === 'turn/interrupt') {
    if (!state?.active || params.turnId !== state.active.id) return reject(id, -32602, 'Active turn changed');
    reply(id, {});
    finish(state, 'interrupted');
    return;
  }
  reject(id, -32601, 'Method not found in offline fixture');
}

function readControl(filename) {
  let fd;
  try {
    fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || stat.nlink !== 1 || stat.size > MAX_CONTROL) {
      throw new Error('invalid control');
    }
    const bytes = Buffer.alloc(MAX_CONTROL + 1);
    const length = fs.readSync(fd, bytes, 0, bytes.length, 0);
    if (length > MAX_CONTROL) throw new Error('oversized control');
    return bytes.subarray(0, length).toString('utf8');
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}

function applyControl(filename) {
  try {
    const text = readControl(filename);
    if (hash(text) === lastControl) return;
    lastControl = hash(text);
    const control = JSON.parse(text);
    if (control === null || typeof control !== 'object' || Array.isArray(control) ||
        !['complete', 'fail'].includes(control.action) ||
        (control.message !== undefined && (typeof control.message !== 'string' || control.message.length > 1024)) ||
        (control.code !== undefined && control.code !== null && !codes.has(control.code))) {
      throw new Error('invalid control');
    }
    const candidates = [...threads.values()].filter((state) => state.held && state.active !== null &&
      (control.threadId === undefined || control.threadId === state.thread.id));
    if (candidates.length !== 1) throw new Error('ambiguous control target');
    const state = candidates[0];
    journal({ method: 'fixture/control', action: control.action, threadId: state.thread.id });
    if (control.action === 'fail') failure(state, { message: control.message ?? availabilityError().message,
      codexErrorInfo: control.code === undefined ? 'flexUnavailable' : control.code, additionalDetails: null });
    else { agentMessage(state, 'C2C_FIXTURE_RELEASED'); finish(state); }
  } catch (error) {
    if (error.code !== 'ENOENT') journal({ method: 'fixture/control-rejected' });
  }
}

const args = process.argv.slice(2);
if (args.length === 1 && ['--version', '-V'].includes(args[0])) {
  process.stdout.write('codex-cli 0.145.0 (c2c offline fixture)\n');
} else if (args.length !== 0 && !args.includes('app-server')) {
  fatal('only app-server and --version are supported');
} else {
  try {
    const logPath = scratchPath('C2C_T3_FIXTURE_LOG');
    const controlPath = scratchPath('C2C_T3_FIXTURE_CONTROL');
    if (logPath !== undefined) logFd = openJournal(logPath);
    if (controlPath !== undefined) {
      watcher = fs.watch(path.dirname(controlPath), (_event, filename) => {
        if (filename === null || filename.toString() === path.basename(controlPath)) applyControl(controlPath);
      });
      watcher.on('error', () => fatal('control watcher failed'));
      watcher.unref();
      // Existing control contents are stale, never replayed when a process starts.
      try { lastControl = hash(readControl(controlPath)); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    journal({ method: 'fixture/ready' });
    process.stdin.on('data', (chunk) => {
      if (stopping) return;
      let start = 0;
      while (start < chunk.length) {
        const newline = chunk.indexOf(10, start);
        const end = newline === -1 ? chunk.length : newline;
        if (pending.length + end - start > MAX_LINE) return fatal('input line bound reached');
        pending = Buffer.concat([pending, chunk.subarray(start, end)]);
        if (newline === -1) break;
        const line = pending.toString('utf8');
        pending = Buffer.alloc(0);
        let message;
        try { message = JSON.parse(line); }
        catch { reject(null, -32700, 'Parse error'); start = newline + 1; continue; }
        try { handle(message); } catch { fatal('fixture state bound or I/O failure'); }
        if (stopping) return;
        start = newline + 1;
      }
    });
    process.stdin.on('end', () => {
      if (pending.length !== 0) reject(null, -32700, 'Newline required');
      watcher?.close();
      if (logFd !== undefined) { fs.closeSync(logFd); logFd = undefined; }
    });
    process.stdin.on('error', () => fatal('input failed'));
    process.stdout.on('error', () => fatal('output failed'));
  } catch { fatal('invalid scratch configuration'); }
}
