import assert from 'node:assert/strict';
import test from 'node:test';
import {
  MatrixRunner, availabilityText, parseArguments, parseProviderLog,
  recoveryObservation, restartCredentialDecision, summarizeSnapshot,
} from './t3-connector-matrix.mjs';

// Pure fixtures and injected MCP/clock seams only. These tests never start T3,
// use credentials, communicate over a socket, or wait on wall-clock timers.
const provider = 'codex-fixture';
function snapshot() {
  return {
    thread: { threadId: 'owned-thread', parentThreadId: null, archived: false,
      settled: false, snoozed: false, runtimeMode: 'auto', providerInstanceId: provider,
      model: 'c2c-fixture', activeRunId: null, pendingRequestCount: 0, runCount: 1, status: 'failed' },
    recentRuns: [{ runId: 'failed-run', ordinal: 1, status: 'failed',
      startedAt: '2026-10-19T00:00:00.000Z', completedAt: '2026-10-19T00:00:01.000Z' }],
    items: [{ itemId: 'error-1', runId: 'failed-run', type: 'error', visibility: 'local',
      sourceThreadId: 'owned-thread', status: 'failed', position: 1,
      text: 'Model c2c-fixture is temporarily unavailable.', textTruncated: false, nextTextOffset: null }],
    nextPosition: 1, hasMore: false, complete: true, queueComplete: true, queuedRunIds: [],
  };
}

function runner(client) {
  let clock = 10_000;
  const saved = [];
  const sleeps = [];
  const state = { nonce: 'fixture-nonce', cases: { availability: { threadId: 'owned-thread',
    projectId: 'owned-project', title: 'owned-title', intents: {} } } };
  const instance = new MatrixRunner({ state, save: () => saved.push(structuredClone(state)), client,
    options: { root: '/tmp/owned-fixture', stateDir: '/tmp/owned-fixture/probe' },
    modelSelection: { instanceId: provider, model: 'c2c-fixture' },
    reconnect: async () => client, now: () => clock,
    sleep: async (ms) => { sleeps.push(ms); clock += ms; }, waitMs: 2500 });
  return { instance, state, saved, sleeps, now: () => clock };
}

test('matrix requires explicit absolute owned-fixture paths', () => {
  assert.deepEqual(parseArguments(['--root', '/tmp/fixture', '--t3-bin', '/opt/t3', '--state-dir', '/tmp/fixture/probe']),
    { root: '/tmp/fixture', t3Bin: '/opt/t3', stateDir: '/tmp/fixture/probe' });
  for (const args of [[], ['--root', '/tmp/fixture'], ['--root', '/tmp/fixture', '--t3-bin', '/opt/t3', '--state-dir', 'relative'],
    ['--root', '/tmp/fixture', '--t3-bin', '/opt/t3', '--state-dir', '/tmp/fixture/probe', '--root', '/tmp/second'],
    ['--root', '/tmp/fixture', '--t3-bin', '/opt/t3', '--state-dir', '/tmp/fixture/probe', '--force', 'yes']]) {
    assert.throws(() => parseArguments(args));
  }
});

test('availability fixture evidence is text-only and excludes access, quota and unrelated errors', () => {
  for (const text of ['Model X is temporarily unavailable.', 'MODEL X IS NOT AVAILABLE', 'The model x is unavailable; please try again.']) {
    assert.equal(availabilityText(text), true, text);
  }
  for (const text of [null, '', 'serverOverloaded', 'Upstream capacity exhausted.', 'flexUnavailable',
    'Usage limit exceeded. Try again later.', 'Model x is unavailable for your subscription.',
    'Model x is unavailable: authentication failed.', 'Model x not found.', 'Network connection lost.',
    'Context window exceeded.', 'Model x is unavailable: invalid API key.']) {
    assert.equal(availabilityText(text), false, text);
  }
});

test('recovery requires complete current failed-root evidence and observable lifecycle guards', () => {
  assert.deepEqual(recoveryObservation(snapshot(), provider), {
    eligible: true, reason: 'availability', runId: 'failed-run', errorIds: ['error-1'],
  });
  for (const mutate of [
    (value) => { value.complete = false; },
    (value) => { value.queueComplete = false; },
    (value) => { value.thread.runCount = 51; },
    (value) => { value.thread.parentThreadId = 'root'; },
    (value) => { value.thread.archived = true; },
    (value) => { value.thread.settled = true; },
    (value) => { value.thread.snoozed = true; },
    (value) => { value.thread.pendingRequestCount = 1; },
    (value) => { value.thread.activeRunId = 'failed-run'; },
    (value) => { value.thread.runtimeMode = 'full-access'; },
    (value) => { value.thread.providerInstanceId = 'other-provider'; },
    (value) => { value.queuedRunIds = ['queued-run']; },
    (value) => { value.items[0].textTruncated = true; },
    (value) => { value.items[0].status = 'running'; },
    (value) => { value.items[0].visibility = 'inherited'; },
    (value) => { value.items[0].sourceThreadId = 'other-thread'; },
    (value) => { value.items[0].type = 'user_message'; },
  ]) {
    const value = snapshot(); mutate(value);
    assert.equal(recoveryObservation(value, provider).eligible, false);
  }
  const stopped = snapshot();
  stopped.items.push({ type: 'run_interrupt_request', visibility: 'local', sourceThreadId: 'owned-thread', runId: 'failed-run' });
  assert.equal(recoveryObservation(stopped, provider).reason, 'stopped');
});

test('healthy native-child roots and mixed error evidence never recover', () => {
  const healthy = snapshot();
  healthy.recentRuns[0].status = 'completed';
  assert.equal(recoveryObservation(healthy, provider).reason, 'not-failed');
  const mixed = snapshot();
  mixed.items.push({ ...mixed.items[0], itemId: 'auth-error', text: 'Authentication failed: invalid API key.' });
  assert.equal(recoveryObservation(mixed, provider).reason, 'non-availability-or-mixed');
  const newer = snapshot();
  newer.recentRuns.push({ ...newer.recentRuns[0], runId: 'new-run', ordinal: 2, status: 'completed',
    completedAt: '2026-10-19T00:00:02.000Z' });
  newer.thread.runCount++;
  assert.equal(recoveryObservation(newer, provider).reason, 'not-failed');
});

test('evidence summaries retain IDs and hashes without transcript bodies', () => {
  const value = snapshot();
  value.items[0].text = 'private-error-sentinel';
  value.items.push({ type: 'assistant_message', text: 'private-assistant-sentinel' });
  const summary = summarizeSnapshot(value);
  const json = JSON.stringify(summary);
  assert(!json.includes('private-error-sentinel'));
  assert(!json.includes('private-assistant-sentinel'));
  assert.equal(summary.errors[0].itemId, 'error-1');
  assert.match(summary.errors[0].textSha256, /^[a-f0-9]{64}$/);
});

test('provider log parser ignores an incomplete final write and rejects malformed complete events', () => {
  assert.deepEqual(parseProviderLog('{"method":"turn/start","threadId":"native"}\n{"method":'),
    [{ method: 'turn/start', threadId: 'native' }]);
  assert.throws(() => parseProviderLog('not-json\n'));
  assert.throws(() => parseProviderLog('{"method":7}\n'));
  assert.throws(() => parseProviderLog(' '.repeat(1024 * 1024 + 1)));
});

test('ambiguous sends persist before submission and resume using the original request identity', async () => {
  const requests = [];
  const harness = runner({ call: async (name, request) => {
    assert.equal(name, 't3_thread_send');
    assert.equal(harness.saved.at(-1).cases.availability.intents.continue.outcome, 'uncertain');
    requests.push(structuredClone(request));
    if (requests.length === 1) throw new Error('synthetic response loss');
    return { threadId: request.threadId, messageId: 'one-message', runId: 'one-run', delivery: 'started' };
  } });
  await assert.rejects(harness.instance.send('availability', 'continue', 'Continue', 'queue'), /response loss/);
  const first = await harness.instance.send('availability', 'continue', 'Continue', 'queue');
  const replay = await harness.instance.send('availability', 'continue', 'Continue', 'queue');
  assert.deepEqual(requests[0], requests[1]);
  assert.equal(first.messageId, replay.messageId);
  assert.equal(requests.length, 2, 'accepted journal entries avoid a new submission');
  assert.deepEqual(harness.sleeps, [1000]);
  await assert.rejects(harness.instance.send('availability', 'continue', 'different', 'queue'), /payload changed/);
});

test('lost responses have a persistent attempt bound and never generate a new request ID', async () => {
  const requests = [];
  const harness = runner({ call: async (_name, request) => {
    requests.push(request.clientRequestId); throw new Error('synthetic response loss');
  } });
  for (let attempt = 0; attempt < 3; attempt++) {
    await assert.rejects(harness.instance.send('availability', 'continue', 'Continue', 'queue'), /response loss/);
  }
  await assert.rejects(harness.instance.send('availability', 'continue', 'Continue', 'queue'), /retry bound/);
  assert.equal(new Set(requests).size, 1);
  assert.equal(requests.length, 3);
});

test('activity pagination merges distinct IDs and queue evidence discards queued text', async () => {
  const calls = [];
  const first = snapshot();
  first.hasMore = true; first.nextPosition = 1;
  const second = snapshot();
  second.items = [{ ...second.items[0], itemId: 'error-2', position: 2 }]; second.nextPosition = 2;
  const harness = runner({ call: async (name, request) => {
    calls.push({ name, request });
    if (name === 't3_queue_list') return { items: [{ queuedRunId: 'queued', text: 'never retain this queue body' }], nextCursor: null };
    return request.afterPosition === undefined ? first : second;
  } });
  const result = await harness.instance.snapshot('availability');
  assert.deepEqual(result.items.map((item) => item.itemId), ['error-1', 'error-2']);
  assert.deepEqual(result.queuedRunIds, ['queued']);
  assert(!JSON.stringify(result).includes('never retain this queue body'));
  assert.equal(calls[1].request.afterPosition, 1);
  assert.equal(calls[2].name, 't3_queue_list');
});

test('duplicate or truncated activity fails closed instead of proving completeness', async () => {
  const value = snapshot(); value.hasMore = true;
  const duplicate = runner({ call: async () => value });
  await assert.rejects(duplicate.instance.snapshot('availability'), /Duplicate paged activity identity/);
  const truncated = snapshot(); truncated.items[0].textTruncated = true;
  const harness = runner({ call: async () => truncated });
  await assert.rejects(harness.instance.snapshot('availability'), /truncated/);
});

test('live waits and persisted rate boundaries are bounded using an injected clock', async () => {
  const harness = runner({ call: async () => { throw new Error('unexpected MCP call'); } });
  let reads = 0;
  harness.instance.snapshot = async () => { reads++; return snapshot(); };
  await assert.rejects(harness.instance.wait('availability', () => false, 'synthetic deadline'), /Fixture deadline/);
  assert.equal(reads, 3);
  assert.equal(harness.now(), 12_500);
  harness.state.lastSubmissionAt = harness.now() + 60_000;
  await assert.rejects(harness.instance.pace(), /clock moved backwards/);
});

test('restart holds uncertain sends until the same credential generation is revalidated', () => {
  assert.deepEqual(restartCredentialDecision({ incarnationMatches: true, tokenAccepted: true }),
    { useStoredCredential: true, uncertainSends: 'resume-same-generation' });
  assert.deepEqual(restartCredentialDecision({ incarnationMatches: false, tokenAccepted: true }),
    { useStoredCredential: false, uncertainSends: 'hold', next: 'revalidate-same-generation' });
  assert.deepEqual(restartCredentialDecision({ incarnationMatches: false, tokenAccepted: false }),
    { useStoredCredential: false, uncertainSends: 'hold', next: 'explicit-repair' });
  assert.throws(() => restartCredentialDecision({ incarnationMatches: false, tokenAccepted: 'yes' }));
});
