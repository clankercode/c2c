#!/usr/bin/env node
// Uses only its own c2c probe credential and its own disposable scratch thread.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { authorizedProbe, readPrivate, withStateLock, writePrivate } from './t3-connector-probe.mjs';

const [stateDir, t3Home] = process.argv.slice(2);
if (!path.isAbsolute(stateDir ?? '') || !path.isAbsolute(t3Home ?? '')) {
  process.stderr.write('Usage: t3-connector-live-contract.mjs ABS_PROBE_STATE_DIR ABS_T3_HOME\n');
  process.exit(2);
}

const statePath = path.join(stateDir, 'fixture.json');
const options = { 'state-dir': stateDir, 't3-home': t3Home };
let state;
const save = () => writePrivate(statePath, state);

async function read(client) {
  return client.call('t3_thread_read', {
    threadId: state.threadId, view: 'activity', limit: 100, runLimit: 50, maxCharsPerItem: 5000,
  });
}

async function waitFor(client, predicate, label) {
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    const snapshot = await read(client);
    if (predicate(snapshot)) return snapshot;
    await delay(1000);
  }
  throw new Error(`Fixture timeout: ${label}`);
}

async function submit(client, name, message, mode) {
  const key = `${name}Intent`;
  if (!state[key]) {
    state[key] = { threadId: state.threadId, message, mode, clientRequestId: `c2c-probe-${name}-${state.nonce}` };
    save();
  }
  assert.equal(state[key].message, message, 'immutable fixture payload');
  if (state[`${name}Receipt`]) return state[`${name}Receipt`];
  // Space all fixture submissions too; this is not the service's rate limiter.
  const wait = (state.lastSubmissionAt ?? 0) + 1000 - Date.now();
  if (wait > 0) await delay(wait);
  state.lastSubmissionAt = Date.now();
  state[`${name}Outcome`] = 'uncertain';
  save();
  const result = await client.call('t3_thread_send', state[key]);
  state[`${name}Receipt`] = result;
  state[`${name}Outcome`] = 'accepted';
  save();
  return result;
}

async function run() {
  const { client, runtime } = authorizedProbe(options);
  await client.initialize();
  const capabilities = await client.call('orchestrator_capabilities');
  assert.equal(capabilities.runtimeMode, 'auto');
  if (!state.threadId) {
    if (state.launchAttempted) throw new Error('Ambiguous fixture launch; inspect state before retrying');
    state.launchAttempted = true;
    save();
    const provider = capabilities.providers.find((entry) => entry.driverKind === 'codex' && entry.models.length);
    assert(provider, 'configured Codex model fixture');
    const created = await client.call('t3_thread_launch', {
      scratch: true, title: `c2c-compatibility-fixture-${state.nonce}`,
      runtimeMode: 'auto', modelSelection: { instanceId: provider.providerInstanceId, model: provider.models[0].id },
    });
    state.threadId = created.threadId;
    state.projectId = created.projectId;
    state.modelSelection = created.modelSelection;
    save();
  }
  const initial = await read(client);
  assert.equal(initial.thread.threadId, state.threadId);
  assert.equal(initial.thread.parentThreadId, null, 'root fixture');
  assert.equal(initial.thread.runtimeMode, 'auto');
  assert.equal(initial.thread.archived, false);
  const listed = await client.call('t3_thread_list', { projectId: state.projectId, includeSubagents: false, limit: 100 });
  assert(listed.threads.some((thread) => thread.threadId === state.threadId), 'root appears in external discovery');
  state.checks.rootDiscovery = true;
  save();

  const idleMessage = `This is an operator-authorized c2c compatibility fixture. Do not run tools or change files. Reply exactly C2C-PROBE-${state.nonce}.`;
  const receipt = await submit(client, 'idle', idleMessage, 'auto');
  assert(['started', 'queued'].includes(receipt.delivery), 'idle auto send accepted');
  const snapshot = await waitFor(client, (value) => value.items.some((item) => item.messageId === receipt.messageId), 'accepted message projection');
  const item = snapshot.items.find((entry) => entry.messageId === receipt.messageId);
  assert.equal(item.createdBy, 'agent', 'generic agent attribution');
  assert.equal(item.creationSource, 'mcp');
  assert.equal(item.sourceThreadId, state.threadId);
  state.checks.agentAttribution = true;
  const replay = await client.call('t3_thread_send', state.idleIntent);
  assert.equal(replay.messageId, receipt.messageId, 'same-session idempotency');
  const { client: reconnected } = authorizedProbe(options);
  await reconnected.initialize();
  const reconnectReplay = await reconnected.call('t3_thread_send', state.idleIntent);
  assert.equal(reconnectReplay.messageId, receipt.messageId, 'transport reconnect idempotency');
  state.checks.transportReplay = true;
  save();

  const terminal = await waitFor(client,
    (value) => value.recentRuns.some((run) => run.runId === receipt.runId
      && ['completed', 'failed', 'interrupted', 'cancelled'].includes(run.status)), 'terminal fixture execution');
  const run = terminal.recentRuns.find((entry) => entry.runId === receipt.runId);
  const errors = terminal.items.filter((entry) => entry.type === 'error' && entry.runId === receipt.runId);
  state.execution = {
    status: run.status, errorCount: errors.length,
    errorShape: errors[0] ? Object.keys(errors[0]).sort() : [],
    // Only classifications/hashes: never retain a provider's raw private error.
    errorHashes: errors.map((entry) => crypto.createHash('sha256').update(entry.text ?? '').digest('hex')),
  };
  state.checks.modelCompleted = run.status === 'completed';
  const finalSnapshot = await read(client);
  assert.equal(finalSnapshot.items.filter((entry) => entry.messageId === receipt.messageId).length, 1, 'one projected message');
  save();
  return {
    host: runtime.origin, serverVersion: runtime.serverVersion,
    threadId: state.threadId, projectId: state.projectId, checks: state.checks,
    execution: state.execution,
  };
}

withStateLock(path.join(stateDir, 'fixture.lock'), async () => {
  state = fs.existsSync(statePath) ? readPrivate(statePath) : { nonce: crypto.randomUUID(), checks: {} };
  return run();
}).then((result) => process.stdout.write(`${JSON.stringify(result)}\n`)).catch((error) => {
  process.stderr.write(error instanceof assert.AssertionError ? 'Live contract assertion failed\n' :
    error?.constructor?.name === 'Error' ? `${error.message}\n` : 'Live contract probe failed\n');
  process.exitCode = 1;
});
