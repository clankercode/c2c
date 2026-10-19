#!/usr/bin/env node
// Development-only behavioral proof against an owned stock-T3 fixture. This is
// not the production recovery worker. It never invokes a real model or borrows
// provider credentials; only the synthetic fixture operator receives broad auth.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { authorizedProbe, readPrivate, withStateLock, writePrivate } from './t3-connector-probe.mjs';
import { fixtureStatus, readFixtureState } from './t3-connector-fixture.mjs';
import { connectFixtureOperator } from './t3-fixture-operator.mjs';

const VERSION = 1;
const MAX_PAGES = 16;
const MAX_BYTES = 8 * 1024 * 1024;
const MAX_CALLS = 3000;
const WAIT_MS = 120_000;
const MODEL = 'c2c-fixture';
const PROVIDER = fileURLToPath(new URL('./fixtures/t3-codex-provider.mjs', import.meta.url));
const SCRIPT = fileURLToPath(import.meta.url);
const terminal = new Set(['completed', 'failed', 'interrupted', 'cancelled']);
const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');

export class MatrixError extends Error {}
function check(value, code) { if (!value) throw new MatrixError(code); }

export function parseArguments(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    check(['--root', '--t3-bin', '--state-dir'].includes(name) && args[index + 1]
      && !Object.hasOwn(options, name), 'Expected unique --root, --t3-bin and --state-dir options');
    options[name] = args[index + 1];
  }
  for (const name of ['--root', '--t3-bin', '--state-dir']) {
    check(path.isAbsolute(options[name] ?? ''), 'All matrix paths must be explicit and absolute');
  }
  return { root: path.resolve(options['--root']), t3Bin: options['--t3-bin'],
    stateDir: path.resolve(options['--state-dir']) };
}

// Deliberately narrow fixture policy. Codes, titles, messages and tool output
// are not evidence. T009 must implement and test its own production decision.
export function availabilityText(text) {
  if (typeof text !== 'string' || text.length > 128 * 1024) return false;
  if (/authenticat|unauthori[sz]ed|api[ -]?key|access denied|subscription|permission|not have access|quota|usage limit|rate limit|context (?:window|limit)|workspace|configuration|not found|does not exist/i.test(text)) return false;
  return /\bmodel\b[^\n]{0,120}\b(?:unavailable|not\s+available)\b/i.test(text);
}

export function recoveryObservation(snapshot, providerInstanceId) {
  const { thread, recentRuns, items } = snapshot;
  const hold = (reason) => ({ eligible: false, reason });
  if (!snapshot.complete || snapshot.queueComplete !== true || thread.runCount !== recentRuns.length) return hold('incomplete');
  if (thread.parentThreadId !== null) return hold('not-root');
  if (thread.archived || thread.settled || thread.snoozed) return hold('inactive');
  if (thread.runtimeMode !== 'auto' || thread.providerInstanceId !== providerInstanceId || thread.model !== MODEL) return hold('provider-or-authority');
  if (thread.activeRunId !== null || thread.pendingRequestCount !== 0) return hold('busy-or-approval');
  if (snapshot.queuedRunIds.length || recentRuns.some((run) => run.status === 'queued')) return hold('queued');
  const executed = recentRuns.filter((run) => run.status !== 'queued'
    && !(run.status === 'cancelled' && run.startedAt === null));
  if (!executed.length) return hold('no-execution');
  const end = (run) => run.completedAt === null ? Infinity : Date.parse(run.completedAt);
  if (executed.some((run) => run.completedAt !== null && !Number.isFinite(end(run)))) return hold('incomplete');
  const latest = executed.reduce((left, right) => end(right) > end(left)
    || (end(right) === end(left) && right.ordinal > left.ordinal) ? right : left);
  if (latest.status !== 'failed') return hold('not-failed');
  if (items.some((item) => item.visibility === 'local' && item.sourceThreadId === thread.threadId
      && item.runId === latest.runId && item.type === 'run_interrupt_request')) return hold('stopped');
  const errors = items.filter((item) => item.visibility === 'local'
    && item.sourceThreadId === thread.threadId && item.runId === latest.runId && item.type === 'error');
  if (!errors.length || errors.some((item) => item.textTruncated || item.status !== 'failed')) return hold('incomplete-error');
  if (!errors.every((item) => availabilityText(item.text))) return hold('non-availability-or-mixed');
  return { eligible: true, reason: 'availability', runId: latest.runId,
    errorIds: errors.map((item) => item.itemId).sort() };
}

export function summarizeSnapshot(snapshot) {
  return {
    thread: { threadId: snapshot.thread.threadId, status: snapshot.thread.status,
      parentThreadId: snapshot.thread.parentThreadId, activeRunId: snapshot.thread.activeRunId,
      runCount: snapshot.thread.runCount, pendingRequestCount: snapshot.thread.pendingRequestCount,
      runtimeMode: snapshot.thread.runtimeMode },
    runs: snapshot.recentRuns.map(({ runId, ordinal, status }) => ({ runId, ordinal, status })),
    errors: snapshot.items.filter((item) => item.type === 'error').map((item) => ({
      itemId: item.itemId, runId: item.runId, sourceThreadId: item.sourceThreadId,
      visibility: item.visibility, status: item.status, position: item.position,
      textSha256: hash(item.text ?? ''), textBytes: Buffer.byteLength(item.text ?? ''),
      availabilityText: availabilityText(item.text), fields: Object.keys(item).sort(),
    })),
    interruptRunIds: snapshot.items.filter((item) => item.type === 'run_interrupt_request').map((item) => item.runId),
    subagentCount: snapshot.items.filter((item) => item.type === 'subagent').length,
    complete: snapshot.complete, queueComplete: snapshot.queueComplete,
    queuedRunIds: snapshot.queuedRunIds,
  };
}

export function parseProviderLog(text) {
  check(Buffer.byteLength(text) <= 1024 * 1024, 'Synthetic provider log exceeds bound');
  // A writer can be midway through its final line. Complete records suffice;
  // never parse or persist a partial event as proof of an operation.
  return text.split('\n').slice(0, -1).filter(Boolean).map((line) => {
    const row = JSON.parse(line);
    check(row && typeof row === 'object' && typeof row.method === 'string', 'Malformed synthetic provider log');
    return row;
  });
}

export class MatrixRunner {
  constructor({ state, save, client, options, modelSelection, reconnect,
    operator = () => connectFixtureOperator(options.root, options.t3Bin),
    sleep = delay, now = Date.now, waitMs = WAIT_MS }) {
    Object.assign(this, { state, save, client, options, modelSelection, reconnect, operator, sleep, now, waitMs });
    this.calls = 0;
    this.rpc = null;
  }

  async call(name, args = {}, client = this.client) {
    check(++this.calls <= MAX_CALLS, 'Matrix MCP call bound reached');
    return client.call(name, args);
  }

  async pace() {
    const wait = (this.state.lastSubmissionAt ?? 0) + 1000 - this.now();
    check(Number.isFinite(wait) && wait <= 60_000, 'Submission clock moved backwards; inspect persisted rate boundary');
    if (wait > 0) await this.sleep(wait);
    this.state.lastSubmissionAt = this.now();
    this.save();
  }

  record(name) {
    if (!this.state.cases[name]) {
      this.state.cases[name] = { title: `c2c-matrix-${name}-${this.state.nonce}`, intents: {} };
      this.save();
    }
    return this.state.cases[name];
  }

  async findLaunch(title) {
    const matches = [];
    let projectCursor;
    for (let projectPage = 0; projectPage < MAX_PAGES; projectPage++) {
      const projects = await this.call('t3_project_list', { limit: 100, ...(projectCursor === undefined ? {} : { cursor: projectCursor }) });
      check(Array.isArray(projects.projects), 'Invalid project list');
      for (const project of projects.projects) {
        let cursor;
        for (let page = 0; page < MAX_PAGES; page++) {
          const result = await this.call('t3_thread_list', { projectId: project.id, includeSubagents: false,
            titleContains: title, limit: 100, ...(cursor === undefined ? {} : { cursor }) });
          check(Array.isArray(result.threads), 'Invalid thread list');
          for (const thread of result.threads) {
            if (thread.title === title) matches.push({ ...thread, projectId: project.id });
          }
          if (result.nextCursor === null) break;
          check(Number.isSafeInteger(result.nextCursor) && result.nextCursor > (cursor ?? -1)
            && page + 1 < MAX_PAGES, 'Thread discovery page bound reached');
          cursor = result.nextCursor;
        }
      }
      if (projects.nextCursor === null) return matches;
      check(Number.isSafeInteger(projects.nextCursor) && projects.nextCursor > (projectCursor ?? -1)
        && projectPage + 1 < MAX_PAGES, 'Project discovery page bound reached');
      projectCursor = projects.nextCursor;
    }
    throw new MatrixError('Project discovery incomplete');
  }

  async thread(name) {
    const record = this.record(name);
    if (record.threadId) return record;
    if (record.launchAttemptedAt) {
      const matches = await this.findLaunch(record.title);
      check(matches.length === 1, 'Ambiguous fixture launch: inspect persisted intent before retrying');
      const found = matches[0];
      check(found.parentThreadId === null && found.providerInstanceId === this.modelSelection.instanceId
        && found.model === MODEL && found.runtimeMode === 'auto', 'Reconciled fixture identity differs');
      record.threadId = found.threadId; record.projectId = found.projectId;
      record.launchOutcome = 'reconciled'; this.save();
      return record;
    }
    record.launchAttemptedAt = new Date(this.now()).toISOString();
    record.launchOutcome = 'uncertain'; this.save();
    await this.pace();
    const result = await this.call('t3_thread_launch', { scratch: true, title: record.title,
      runtimeMode: 'auto', modelSelection: this.modelSelection });
    check(typeof result.threadId === 'string' && typeof result.projectId === 'string', 'Invalid fixture launch result');
    record.threadId = result.threadId; record.projectId = result.projectId;
    record.launchOutcome = 'accepted'; this.save();
    return record;
  }

  async send(name, key, message, mode) {
    const record = await this.thread(name);
    let intent = record.intents[key];
    if (!intent) {
      intent = record.intents[key] = { request: { threadId: record.threadId, message, mode,
        clientRequestId: `c2c-matrix-${name}-${key}-${this.state.nonce}` }, attempts: 0 };
      this.save();
    }
    check(intent.request.threadId === record.threadId && intent.request.message === message
      && intent.request.mode === mode, 'Persisted send payload changed');
    if (intent.receipt) return intent.receipt;
    check(intent.attempts < 3, 'Uncertain send retry bound reached; inspect journal');
    await this.pace();
    intent.attempts++; intent.outcome = 'uncertain'; this.save();
    const receipt = await this.call('t3_thread_send', intent.request);
    check(receipt.threadId === record.threadId && typeof receipt.messageId === 'string'
      && typeof receipt.runId === 'string', 'Invalid fixture send receipt');
    intent.receipt = receipt; intent.outcome = 'accepted'; this.save();
    return receipt;
  }

  async snapshot(name) {
    const record = await this.thread(name);
    let afterPosition;
    let result;
    let size = 0;
    const items = [];
    const identities = new Set();
    for (let page = 0; page < MAX_PAGES; page++) {
      const current = await this.call('t3_thread_read', { threadId: record.threadId, view: 'activity',
        limit: 100, runLimit: 50, maxCharsPerItem: 50_000,
        ...(afterPosition === undefined ? {} : { afterPosition }) });
      size += Buffer.byteLength(JSON.stringify(current));
      check(size <= MAX_BYTES && current.thread?.threadId === record.threadId
        && current.thread.parentThreadId === null && current.thread.model === MODEL
        && Array.isArray(current.items) && Array.isArray(current.recentRuns), 'Invalid or oversized fixture activity');
      result = current;
      for (const item of current.items) {
        const identity = `${item.sourceThreadId}:${item.itemId}`;
        check(!identities.has(identity), 'Duplicate paged activity identity'); identities.add(identity);
        // Synthetic fixture messages/errors are tiny. An unexpected truncation
        // is a compatibility failure, never silent positive recovery evidence.
        check(item.textTruncated === false && item.nextTextOffset == null, 'Synthetic fixture activity is truncated');
        items.push(item);
      }
      if (current.hasMore === false) break;
      check(current.hasMore === true && Number.isSafeInteger(current.nextPosition)
        && current.nextPosition > (afterPosition ?? -1) && page + 1 < MAX_PAGES, 'Activity page bound reached');
      afterPosition = current.nextPosition;
    }
    check(result.hasMore === false, 'Incomplete activity');
    const queuedRunIds = [];
    let cursor;
    for (let page = 0; page < MAX_PAGES; page++) {
      const queue = await this.call('t3_queue_list', { threadId: record.threadId, limit: 100,
        ...(cursor === undefined ? {} : { cursor }) });
      check(Array.isArray(queue.items), 'Invalid external queue read');
      // Discard text immediately; queued content can never supply trigger evidence.
      for (const item of queue.items) {
        check(typeof item.queuedRunId === 'string' && !queuedRunIds.includes(item.queuedRunId), 'Invalid queued run identity');
        queuedRunIds.push(item.queuedRunId);
      }
      if (queue.nextCursor === null) return { ...result, items, complete: true, queueComplete: true, queuedRunIds };
      check(Number.isSafeInteger(queue.nextCursor) && queue.nextCursor > (cursor ?? -1)
        && page + 1 < MAX_PAGES, 'Queue page bound reached');
      cursor = queue.nextCursor;
    }
    throw new MatrixError('Incomplete queue');
  }

  async wait(name, predicate, label) {
    const deadline = this.now() + this.waitMs;
    while (this.now() < deadline) {
      const snapshot = await this.snapshot(name);
      if (predicate(snapshot)) return snapshot;
      await this.sleep(Math.min(1000, Math.max(1, deadline - this.now())));
    }
    throw new MatrixError(`Fixture deadline: ${label}`);
  }

  async ended(name, receipt, status) {
    const snapshot = await this.wait(name, (value) => value.recentRuns.some((run) => run.runId === receipt.runId
      && terminal.has(run.status)) && value.thread.activeRunId === null, `${name} terminal execution`);
    check(snapshot.recentRuns.find((run) => run.runId === receipt.runId).status === status, `${name} unexpected execution outcome`);
    return snapshot;
  }

  proof(name, value) {
    const record = this.record(name);
    record.result = { ...value, observedAt: new Date(this.now()).toISOString(), runnerSha256: hash(fs.readFileSync(SCRIPT)) };
    this.save();
  }

  async errorCase(name, { recover = false, status = 'failed', subagent = false } = {}) {
    const record = this.record(name);
    if (record.result) return;
    const kickoff = await this.send(name, 'kickoff', `C2C_FIXTURE:${name} ${this.state.nonce}`, 'auto');
    check(kickoff.delivery === 'started', `${name} idle auto did not start`);
    // An earlier interrupted matrix may already have accepted its Continue.
    // The pre-recovery observation was durably saved before that submission.
    if (!record.observation) {
      const snapshot = await this.ended(name, kickoff, status);
      const message = snapshot.items.find((item) => item.messageId === kickoff.messageId);
      check(message?.createdBy === 'agent' && message.creationSource === 'mcp'
        && message.sourceThreadId === record.threadId, 'Missing generic agent attribution');
      const observation = recoveryObservation(snapshot, this.modelSelection.instanceId);
      check(observation.eligible === recover, `${name} unexpected recovery eligibility`);
      if (subagent) check(snapshot.items.some((item) => item.type === 'subagent'), `${name} native child is not externally represented`);
      const errors = snapshot.items.filter((item) => item.type === 'error');
      if (status === 'failed') check(errors.some((item) => item.runId === kickoff.runId), `${name} failed root has no error row`);
      check(errors.every((item) => !Object.hasOwn(item, 'failure') && !Object.hasOwn(item, 'nodeId')
        && !Object.hasOwn(item, 'rootNodeId') && !Object.hasOwn(item, 'code')), 'External error shape changed; review recovery evidence contract');
      record.observation = { policy: observation, snapshot: summarizeSnapshot(snapshot) }; this.save();
    }
    if (recover) {
      if (!record.intents.continue) {
        const preflight = recoveryObservation(await this.snapshot(name), this.modelSelection.instanceId);
        check(preflight.eligible && preflight.runId === kickoff.runId
          && JSON.stringify(preflight.errorIds) === JSON.stringify(record.observation.policy.errorIds), 'Recovery evidence changed before Continue');
      }
      const receipt = await this.send(name, 'continue', 'Continue', 'queue');
      check(receipt.delivery === 'started' && receipt.runId !== kickoff.runId, 'Idle queue Continue did not start a distinct execution');
      const completed = await this.ended(name, receipt, 'completed');
      check(completed.items.some((item) => item.runId === receipt.runId && item.type === 'assistant_message'
        && item.text === 'C2C_FIXTURE_RECOVERED'), 'Synthetic recovery response missing');
      check(completed.items.filter((item) => item.messageId === receipt.messageId).length === 1, 'Duplicate recovery message projection');
      if (name === 'availability') {
        await this.pace();
        const replay = await this.call('t3_thread_send', record.intents.continue.request);
        check(replay.messageId === receipt.messageId && replay.runId === receipt.runId, 'Recovery replay created another identity');
        const reconnected = await this.reconnect();
        await this.pace();
        const replay2 = await this.call('t3_thread_send', record.intents.continue.request, reconnected);
        check(replay2.messageId === receipt.messageId && replay2.runId === receipt.runId, 'Reconnect replay changed recovery identity');
        const afterReplay = await this.snapshot(name);
        check(afterReplay.items.filter((item) => item.messageId === receipt.messageId).length === 1
          && afterReplay.recentRuns.length === completed.recentRuns.length, 'Reconnect replay duplicated recovery');
      }
    }
    this.proof(name, { expectedRecovery: recover, observation: record.observation, recovered: recover });
  }

  providerLog() {
    const filename = path.join(this.options.root, 'provider.ndjson');
    const fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      const stat = fs.fstatSync(fd);
      check(stat.isFile() && stat.uid === process.getuid() && stat.nlink === 1
        && !(stat.mode & 0o077) && stat.size <= 1024 * 1024, 'Invalid synthetic provider journal');
      const bytes = Buffer.alloc(1024 * 1024 + 1);
      const size = fs.readSync(fd, bytes, 0, bytes.length, 0);
      check(size <= 1024 * 1024, 'Synthetic provider journal grew past bound');
      return parseProviderLog(bytes.subarray(0, size).toString('utf8'));
    } finally { fs.closeSync(fd); }
  }

  async control(name, action) {
    const record = this.record(name);
    record.controls ??= {};
    if (!record.controls[action]) {
      const matches = this.providerLog().filter((row) => row.method === 'fixture/turn-created' && row.scenario === name);
      check(matches.length === 1, 'Synthetic control target is ambiguous');
      record.controls[action] = { action, threadId: matches[0].threadId, nonce: crypto.randomUUID() }; this.save();
    }
    const control = record.controls[action];
    check(typeof control.threadId === 'string' && control.action === action, 'Invalid persisted fixture control');
    writePrivate(path.join(this.options.root, 'control.json'), control);
  }

  async activeCase() {
    const name = 'hold'; const record = this.record(name);
    if (record.result) return;
    const first = await this.send(name, 'kickoff', `C2C_FIXTURE:hold ${this.state.nonce}`, 'auto');
    check(first.delivery === 'started', 'Held root did not start');
    if (!record.controls?.complete) {
      await this.wait(name, (value) => value.thread.activeRunId === first.runId
        && value.items.some((item) => item.text === 'C2C_FIXTURE_HOLDING'), 'held root started');
      const steered = await this.send(name, 'steer', `C2C_FIXTURE_ACTIVE_STEER ${this.state.nonce}`, 'auto');
      check(steered.delivery === 'steered' && steered.runId === first.runId, 'Active auto did not steer the existing run');
      const queued = await this.send(name, 'queued', 'Continue', 'queue');
      check(queued.delivery === 'queued' && queued.runId !== first.runId, 'Queue mode did not create queued work');
      const held = await this.wait(name, (value) => value.queuedRunIds.includes(queued.runId), 'external queue guard');
      check(held.thread.activeRunId === first.runId && !recoveryObservation(held, this.modelSelection.instanceId).eligible, 'Queue Continue steered the active execution');
      record.activeObservation = summarizeSnapshot(held); this.save();
      await this.control(name, 'complete');
    } else {
      await this.control(name, 'complete'); // Same native target/nonce is idempotent.
    }
    const queued = record.intents.queued?.receipt;
    check(queued, 'Missing persisted queue receipt');
    const ended = await this.ended(name, queued, 'completed');
    check(ended.queuedRunIds.length === 0 && ended.recentRuns.find((run) => run.runId === first.runId)?.status === 'completed', 'Queued work did not drain after active completion');
    const nativeThread = record.controls.complete.threadId;
    const log = this.providerLog().filter((row) => row.threadId === nativeThread);
    check(log.some((row) => row.method === 'turn/steer')
      && !log.some((row) => row.method === 'turn/steer' && row.continuation), 'Queue Continue reached native steer');
    this.proof(name, { activeAutoSteered: true, queueDidNotSteer: true, queueDrained: true,
      active: record.activeObservation, completed: summarizeSnapshot(ended) });
  }

  async retryCase(name, stop) {
    const record = this.record(name);
    if (record.result) return;
    const first = await this.send(name, 'kickoff', `C2C_FIXTURE:${name} ${this.state.nonce}`, 'auto');
    if (!record.retryObservation) {
      const active = await this.wait(name, (value) => value.thread.activeRunId === first.runId
        && value.items.some((item) => item.type === 'error' && item.runId === first.runId), `${name} provider retry`);
      check(!recoveryObservation(active, this.modelSelection.instanceId).eligible, 'An active provider retry was eligible');
      record.retryObservation = summarizeSnapshot(active); this.save();
    }
    await this.control(name, 'fail');
    const failed = await this.ended(name, first, 'failed');
    const initialIds = record.retryObservation.errors.map((item) => item.itemId);
    const updated = failed.items.filter((item) => item.type === 'error' && item.runId === first.runId
      && initialIds.includes(item.itemId) && item.status === 'failed');
    check(updated.length > 0, 'Provider retry did not update a stable external error identity');
    record.failedObservation ??= summarizeSnapshot(failed); this.save();
    if (stop) {
      record.stopCommandId ??= crypto.randomUUID(); this.save();
      if (!record.stopReceipt) {
        this.rpc ??= await this.operator();
        await this.pace(); record.stopOutcome = 'uncertain'; this.save();
        record.stopReceipt = await this.rpc.stop(record.threadId, record.stopCommandId);
        record.stopOutcome = 'accepted'; this.save();
      }
      const stopped = await this.wait(name, (value) => value.items.some((item) => item.type === 'run_interrupt_request'
        && item.sourceThreadId === record.threadId && item.runId === first.runId), 'real Stop marker');
      check(stopped.recentRuns.find((run) => run.runId === first.runId)?.status === 'failed', 'Stop changed the failed-run invariant; review policy');
      check(recoveryObservation(stopped, this.modelSelection.instanceId).reason === 'stopped', 'Stop did not suppress recovery');
      this.proof(name, { providerRetryHeld: true, stableErrorUpdated: true, realStopSuppressesRecovery: true,
        retry: record.retryObservation, failed: record.failedObservation, stopped: summarizeSnapshot(stopped) });
    } else {
      if (!record.intents.continue) check(recoveryObservation(failed, this.modelSelection.instanceId).eligible, 'Updated availability failure was ineligible');
      const recovery = await this.send(name, 'continue', 'Continue', 'queue');
      check(recovery.delivery === 'started', 'Updated failure Continue did not start');
      const completed = await this.ended(name, recovery, 'completed');
      this.proof(name, { providerRetryHeld: true, stableErrorUpdated: true, recovered: true,
        retry: record.retryObservation, failed: record.failedObservation, completed: summarizeSnapshot(completed) });
    }
  }

  async fullAccessCase() {
    const record = this.record('full-access');
    if (record.result) return;
    if (!record.launch) {
      const root = await this.thread('availability');
      record.launch = { threadId: crypto.randomUUID(), commandId: crypto.randomUUID(),
        projectId: root.projectId, modelSelection: this.modelSelection };
      this.save();
    }
    this.rpc ??= await this.operator();
    if (!record.launchReceipt) {
      await this.pace(); record.launchOutcome = 'uncertain'; this.save();
      const launched = await this.rpc.launchFullAccess(record.launch);
      check(launched.threadId === record.launch.threadId, 'Operator fixture launch identity changed');
      record.launchReceipt = { threadId: launched.threadId, resumed: launched.resumed };
      record.launchOutcome = 'accepted'; this.save();
    }
    const before = await this.call('t3_thread_read', { threadId: record.launch.threadId, view: 'activity', limit: 100, runLimit: 50 });
    check(before.thread.runtimeMode === 'full-access' && before.thread.runCount === 0, 'Full-access denial fixture is not idle');
    record.denialRequest ??= { threadId: record.launch.threadId, message: 'C2C_FIXTURE_FORBIDDEN_SCOPE',
      mode: 'auto', clientRequestId: `c2c-matrix-denied-${this.state.nonce}` }; this.save();
    await this.pace();
    let denied = false;
    try { await this.call('t3_thread_send', record.denialRequest); }
    catch (error) { denied = error?.message === 'T3 tool t3_thread_send rejected (runtime_mode_escalation_denied)'; }
    check(denied, 'Read-operate auto credential did not report the expected full-access denial');
    const after = await this.call('t3_thread_read', { threadId: record.launch.threadId, view: 'activity', limit: 100, runLimit: 50 });
    check(after.thread.runCount === 0 && after.items.length === before.items.length, 'Denied send mutated the full-access fixture');
    this.proof('full-access', { denied: true, code: 'runtime_mode_escalation_denied', noRunCreated: true });
  }

  async run() {
    try {
      await this.errorCase('availability', { recover: true });
      await this.errorCase('text-only', { recover: true });
      for (const name of ['code-only', 'auth', 'usage', 'mixed-root']) await this.errorCase(name);
      await this.errorCase('child-failure', { status: 'completed', subagent: true });
      await this.errorCase('mixed', { subagent: true });
      await this.activeCase();
      await this.retryCase('retry', true);
      await this.retryCase('update', false);
      await this.fullAccessCase();
      check(Object.values(this.state.cases).every((record) => record.result), 'Matrix has unfinished cases');
      this.state.completedAt = new Date(this.now()).toISOString(); this.save();
      return { version: VERSION, serverVersion: this.state.serverVersion, root: this.options.root,
        evidencePath: path.join(this.options.stateDir, 'matrix-state.json'),
        cases: Object.fromEntries(Object.entries(this.state.cases).map(([name, record]) => [name, record.result])),
        syntheticProvider: true, realModelOutageTested: false };
    } finally { this.rpc?.close(); }
  }
}

export async function runMatrix(options) {
  const fixture = readFixtureState(options.root, options.t3Bin);
  check(fixtureStatus(options).status === 'running', 'Owned stock-T3 fixture must be running');
  check(fs.realpathSync(fixture.providerBin) === fs.realpathSync(PROVIDER), 'Matrix requires its bundled offline Codex provider');
  check(options.stateDir.startsWith(`${options.root}${path.sep}`) && fs.realpathSync(options.stateDir) === options.stateDir,
    'Probe state must be a canonical private directory inside the owned fixture');
  const optionsForProbe = { 'state-dir': options.stateDir, 't3-home': fixture.t3Home };
  const statePath = path.join(options.stateDir, 'matrix-state.json');
  return withStateLock(path.join(options.stateDir, 'matrix.lock'), async () => {
    const auth = readPrivate(path.join(options.stateDir, 'auth.json'));
    const { client, runtime } = authorizedProbe(optionsForProbe);
    await client.initialize();
    const capabilities = await client.call('orchestrator_capabilities');
    check(capabilities.runtimeMode === 'auto', 'Matrix requires its independent read-operate auto credential');
    const provider = capabilities.providers.find((entry) => entry.driverKind === 'codex'
      && entry.models.some((model) => model.id === MODEL));
    check(provider, 'Synthetic Codex model absent from fixture capabilities');
    const modelSelection = { instanceId: provider.providerInstanceId, model: MODEL };
    const state = fs.existsSync(statePath) ? readPrivate(statePath) : {
      version: VERSION, fixtureOwner: fixture.ownerId, root: options.root, t3Home: fixture.t3Home,
      credentialClientId: auth.clientId, credentialIssuedAt: auth.issuedAt,
      nonce: crypto.randomUUID(), modelSelection, serverVersion: runtime.serverVersion, cases: {},
    };
    check(state.version === VERSION && state.fixtureOwner === fixture.ownerId && state.root === options.root
      && state.t3Home === fixture.t3Home && state.credentialClientId === auth.clientId
      && state.credentialIssuedAt === auth.issuedAt && JSON.stringify(state.modelSelection) === JSON.stringify(modelSelection),
    'Persisted matrix belongs to a different fixture, model or credential generation');
    const save = () => writePrivate(statePath, state);
    save();
    return new MatrixRunner({ state, save, client, options, modelSelection,
      reconnect: async () => {
        const next = authorizedProbe(optionsForProbe).client;
        await next.initialize();
        return next;
      },
    }).run();
  });
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    const result = await runMatrix(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    // Assertion diagnostics, raw MCP errors, HTTP bodies and setup exceptions
    // can contain credentials or transcript text. Report only our fixed labels.
    process.stderr.write(`${error instanceof MatrixError ? error.message : 'Isolated T3 matrix failed; inspect private state and logs'}\n`);
    process.exitCode = 1;
  }
}
