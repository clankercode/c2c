#!/usr/bin/env node
// Live proof of the actual OCaml service against an owned stock-T3 fixture.
// This driver never sends Continue. Only the c2c service can recover a run.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { startFixture, stopFixture, readFixtureState } from './t3-connector-fixture.mjs';
import { main as probe, authorizedProbe, readPrivate, writePrivate } from './t3-connector-probe.mjs';
import { MatrixRunner } from './t3-connector-matrix.mjs';

const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const continuations = (snapshot) => snapshot.items.filter((item) => item.type === 'user_message' && item.text === 'Continue');

export function parseArguments(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    assert(['--root', '--t3-bin', '--c2c-bin'].includes(key) && argv[i + 1] && !options[key], 'unique explicit proof options');
    assert(path.isAbsolute(argv[i + 1]), 'absolute proof paths');
    options[key] = argv[i + 1];
  }
  assert(Object.keys(options).length === 3, 'root, T3 binary, and c2c binary are required');
  return { root: options['--root'], t3Bin: options['--t3-bin'], c2cBin: options['--c2c-bin'] };
}

async function exerciseServiceProof(options, fixture) {
  // A fresh private root prevents accidental replay of launch intents. Evidence
  // from an incomplete run stays on disk and requires a new explicit root.
  const root = options.root;
  const home = path.join(root, 'connector-home');
  const config = path.join(root, 'connector-config');
  const stateDir = path.join(root, 'connector-state');
  const broker = path.join(root, 'broker');
  for (const dir of [home, config, stateDir]) fs.mkdirSync(dir, { mode: 0o700 });
  const env = { HOME: home, PATH: process.env.PATH, LANG: 'C.UTF-8',
    T3CODE_HOME: fixture.t3Home, C2C_T3_CONFIG_DIR: config, C2C_T3_STATE_DIR: stateDir,
    C2C_SESSIONS_BROKER_ROOT: broker, C2C_NO_AUTO_REGISTER: '1', C2C_T3_RECOVERY: '1' };
  const cli = (args) => {
    try { return execFileSync(options.c2cBin, args, { env, cwd: root, encoding: 'utf8', timeout: 45_000, stdio: ['ignore', 'pipe', 'pipe'] }); }
    catch { throw new Error('Native c2c fixture command failed (inspect private service log)'); }
  };
  const proof = { schema: 'c2c-t3-native-service-proof-v1', hostname: os.hostname(),
    c2cPath: fs.realpathSync(options.c2cBin), c2cSha256: sha256(options.c2cBin),
    t3Sha256: sha256(options.t3Bin), serverVersion: fixture.serverVersion,
    syntheticProvider: true, realModelOutageTested: false, cases: {} };
  let service;
  let runner;
  const stopService = async () => {
    if (service && service.exitCode === null && service.signalCode === null) {
      const exited = once(service, 'exit');
      service.kill('SIGTERM');
      await Promise.race([exited, delay(5000).then(() => { throw new Error('Owned c2c service did not stop'); })]);
    }
    service = undefined;
  };
  const startService = () => {
    const log = fs.openSync(path.join(root, 'c2c-service.log'), 'a', 0o600);
    try { service = spawn(options.c2cBin, ['t3', 'service', '--foreground'], { env, cwd: root, stdio: ['ignore', log, log] }); }
    finally { fs.closeSync(log); }
    service.on('error', () => {});
  };
  const until = async (predicate, label, timeout = 120_000) => {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (service && (service.exitCode !== null || service.signalCode !== null)) throw new Error('Owned c2c service exited');
      const result = await predicate();
      if (result) return result;
      await delay(250);
    }
    throw new Error(`Native service proof timeout: ${label}`);
  };
  const status = () => {
    try { return readPrivate(path.join(stateDir, 'service-status.json')); } catch { return null; }
  };
  const sweep = async (after = 0) => until(() => {
    const value = status();
    return value?.completedAt && value.lastSweepAt > after && value;
  }, 'completed sweep');
  try {
    proof.stage = 'pairing';
    await probe(['pair', '--state-dir', path.join(root, 'probe'), '--t3-home', fixture.t3Home, '--t3-bin', options.t3Bin]);
    const { client } = authorizedProbe({ 'state-dir': path.join(root, 'probe'), 't3-home': fixture.t3Home });
    await client.initialize();
    const capabilities = await client.call('orchestrator_capabilities');
    const provider = capabilities.providers.find((p) => p.driverKind === 'codex' && p.models.some((m) => m.id === 'c2c-fixture'));
    assert(provider, 'offline provider fixture');
    const modelSelection = { instanceId: provider.providerInstanceId, model: 'c2c-fixture' };
    const state = { nonce: crypto.randomUUID(), cases: {} };
    runner = new MatrixRunner({ state, save: () => writePrivate(path.join(root, 'driver-state.json'), state), client,
      options: { ...options, stateDir: path.join(root, 'probe') }, modelSelection });
    const pairingOutput = execFileSync(options.t3Bin, ['auth', 'pairing', 'create', '--base-dir', fixture.t3Home,
      '--scope', 'orchestration:read', '--scope', 'orchestration:operate', '--ttl', '10m', '--label', 'c2c native service proof', '--json'],
    { encoding: 'utf8', timeout: 30_000, stdio: ['ignore', 'pipe', 'pipe'] });
    const pairing = JSON.parse(pairingOutput.slice(pairingOutput.indexOf('{')));
    cli(['t3', 'pair', '--pairing-code', pairing.credential ?? pairing.token ?? pairing.code, '--json']);
    proof.stage = 'provider-scenarios';
    const positives = ['availability', 'text-only'];
    const negatives = ['auth', 'usage', 'code-only', 'child-failure', 'mixed', 'mixed-root'];
    for (const name of [...positives, ...negatives, 'retry', 'update', 'hold']) {
      const sent = await runner.send(name, 'kickoff', `C2C_FIXTURE:${name} ${state.nonce}`, 'auto');
      if (['retry', 'update', 'hold'].includes(name)) {
        await runner.wait(name, (s) => s.thread.activeRunId === sent.runId, 'active fixture');
      } else await runner.ended(name, sent, name === 'child-failure' ? 'completed' : 'failed');
    }
    await runner.thread('idle');
    await runner.interruptWhileActive();
    negatives.push('interrupt');
    const snoozed = await runner.send('snoozed', 'kickoff', `C2C_FIXTURE:availability ${state.nonce}`, 'auto');
    await runner.ended('snoozed', snoozed, 'failed');
    runner.rpc ??= await runner.operator();
    await runner.rpc.lifecycle(state.cases.snoozed.threadId, 'snooze');
    negatives.push('snoozed');
    await runner.fullAccessCase();
    await runner.control('update', 'fail');
    await runner.wait('update', (s) => s.thread.status === 'failed', 'updated terminal failure');
    positives.push('update');
    proof.stage = 'sender-binding';
    const bind = JSON.parse(cli(['host', 'bind', '--environment-id', 'native-proof', '--thread-id', 'sender',
      '--workspace', root, '--owner-id', state.nonce, '--owner-pid', String(process.pid), '--alias', 'proof-sender', '--broker-root', broker]));
    const binding = bind.binding ?? bind;
    const senderArgs = ['--environment-id', 'native-proof', '--thread-id', 'sender', '--broker-root', broker, '--generation', binding.generation];
    proof.stage = 'first-service-sweep';
    startService();
    const first = await sweep();
    assert.equal(first.intervalSeconds, 60, 'production default cadence');
    assert(first.nextSweepAt >= first.completedAt + 60, 'next sweep scheduled after completion');
    for (const name of positives) {
      const snapshot = await runner.wait(name, (s) => continuations(s).length === 1 && s.thread.status === 'completed', 'service recovery');
      assert.equal(continuations(snapshot)[0].createdBy, 'agent');
    }
    for (const name of negatives) assert.equal(continuations(await runner.snapshot(name)).length, 0, `${name} must not recover`);
    assert.equal(continuations(await runner.snapshot('retry')).length, 0, 'active retry must not recover');
    proof.cases.recovery = { positives, negatives, activeRetryHeld: true, immutableContinue: true };
    proof.stage = 'direct-delivery';
    const mappings = readPrivate(path.join(stateDir, 'state.json')).mappings;
    const registrations = () => JSON.parse(cli(['list', '--cross-repo', '--all', '--json']));
    const beforeRegistrations = registrations();
    const mappingFor = (name) => mappings.find((m) => m.thread_id === state.cases[name].threadId || m.threadId === state.cases[name].threadId);
    const extra = await runner.send('second-sweep', 'kickoff', `C2C_FIXTURE:availability ${state.nonce}`, 'auto');
    await runner.ended('second-sweep', extra, 'failed');
    positives.push('second-sweep');
    const deliveries = [];
    for (const name of ['idle', 'hold']) {
      const mapping = mappingFor(name);
      assert(mapping, 'enrolled root mapping');
      const nonce = `C2C_NATIVE_${name}_${state.nonce}`;
      cli(['host', 'send', ...senderArgs, '--to', mapping.alias, '--content', nonce]);
      deliveries.push({ name, nonce });
    }
    const second = await sweep(first.lastSweepAt);
    assert(second.lastSweepAt >= first.completedAt + 59.9, 'real sixty-second sweep spacing');
    for (const { name, nonce } of deliveries) {
      const snapshot = await runner.wait(name, (s) => s.items.some((i) => i.type === 'user_message' && i.text?.includes(nonce)), 'broker delivery');
      const messages = snapshot.items.filter((i) => i.type === 'user_message' && i.text?.includes(nonce));
      assert.equal(messages.length, 1, 'single projection');
      assert.equal(messages[0].createdBy, 'agent');
      assert.equal(messages[0].creationSource, 'mcp');
      assert(messages[0].text.includes("c2c send --cross-repo 'proof-sender'"), 'shared-broker reply recipe');
      assert(messages[0].text.includes('BEGIN C2C DATA'), 'peer DATA boundary');
      const expectedMethod = name === 'idle' ? 'turn/start' : 'turn/steer';
      const nonceHash = crypto.createHash('sha256').update(nonce).digest('hex');
      await until(() => fs.readFileSync(path.join(root, 'provider.ndjson'), 'utf8').trim().split('\n')
        .filter(Boolean).map((line) => JSON.parse(line))
        .some((row) => row.method === expectedMethod && row.proofNonceHashes?.includes(nonceHash)), 'provider receives nonce');
      if (name === 'hold') assert.equal(snapshot.thread.activeRunId, state.cases.hold.intents.kickoff.receipt.runId,
        'active delivery preserves the active run');
    }
    await runner.wait('second-sweep', (s) => continuations(s).length === 1 && s.thread.status === 'completed', 'shared sweep recovery');
    proof.cases.direct = { idle: true, active: true, attribution: 'agent/mcp', sharedBrokerFooter: true, providerNonceHashesMatched: true };
    proof.stage = 'doctor';
    const heartbeat = JSON.parse(cli(['t3', 'service', 'doctor', '--json'])).monitor;
    assert.equal(heartbeat.running, true, 'doctor observes live owner generation');
    assert.equal(heartbeat.lastSweepAt, second.lastSweepAt);
    proof.cases.cadence = { first: first.lastSweepAt, second: second.lastSweepAt, interval: 60 };
    const after = await runner.snapshot('availability');
    assert.equal(continuations(after).length, 1, 'later sweep dedupe');
    proof.stage = 'service-restart';
    await stopService();
    startService();
    await sweep(second.lastSweepAt);
    for (const name of positives) assert.equal(continuations(await runner.snapshot(name)).length, 1, 'restart dedupe');
    const afterMappings = readPrivate(path.join(stateDir, 'state.json')).mappings;
    for (const mapping of mappings) assert(afterMappings.some((after) =>
      after.thread_id === mapping.thread_id && after.alias === mapping.alias), 'persisted aliases survive restart');
    const afterRegistrations = registrations();
    const registrationKeys = (rows) => rows.filter((row) => row.alias.startsWith('t3-'))
      .map((row) => [row.alias, row.session_id]).sort();
    const priorAliases = new Set(beforeRegistrations.map((row) => row.alias));
    assert.deepEqual(registrationKeys(afterRegistrations.filter((row) => priorAliases.has(row.alias))),
      registrationKeys(beforeRegistrations), 'same broker routes republished');
    assert(registrationKeys(afterRegistrations).length > 0, 'live root routes republished');
    const restartNonce = `C2C_NATIVE_restart_${state.nonce}`;
    cli(['host', 'send', ...senderArgs, '--to', mappingFor('idle').alias, '--content', restartNonce]);
    await sweep(status().lastSweepAt);
    await runner.wait('idle', (s) => s.items.some((i) => i.type === 'user_message' && i.text?.includes(restartNonce)),
      'delivery through pre-restart alias');
    proof.cases.restart = { aliasesStable: true, brokerRoutesStable: true, oldAliasDelivery: true, duplicateContinuations: 0 };
    await stopService();
    // Disable before introducing a new eligible failure; no test code submits a
    // continuation or edits the connector journal to manufacture this result.
    proof.stage = 'disable';
    cli(['t3', 'service', 'recovery', 'disable']);
    delete env.C2C_T3_RECOVERY;
    const disabled = await runner.send('disabled', 'kickoff', `C2C_FIXTURE:availability ${state.nonce}`, 'auto');
    await runner.ended('disabled', disabled, 'failed');
    const beforeDisabledSweep = status().lastSweepAt;
    cli(['t3', 'service', '--once']);
    const disabledSweep = status();
    assert(disabledSweep.lastSweepAt > beforeDisabledSweep && disabledSweep.completedAt, 'fresh disabled sweep completed');
    assert.equal(disabledSweep.healthy, true, 'disabled sweep reached healthy discovery');
    assert.equal(disabledSweep.recoveryEnabled, false, 'durable disable applied to service');
    assert(readPrivate(path.join(stateDir, 'state.json')).mappings.some((m) =>
      m.thread_id === state.cases.disabled.threadId && !m.tombstone), 'disabled target enrolled');
    assert.equal(continuations(await runner.snapshot('disabled')).length, 0, 'durable disable');
    proof.cases.disable = true;
    proof.stage = 'retirement-and-repair';
    const retired = mappingFor('idle');
    const retiredRegistration = afterRegistrations.find((row) => row.alias === retired.alias);
    const retiredNonce = `C2C_NATIVE_retired_${state.nonce}`;
    cli(['host', 'send', ...senderArgs, '--to', retired.alias, '--content', retiredNonce]);
    await runner.rpc.lifecycle(state.cases.idle.threadId, 'archive');
    cli(['t3', 'service', '--once']);
    assert(readPrivate(path.join(stateDir, 'state.json')).mappings.some((m) =>
      m.thread_id === state.cases.idle.threadId && m.tombstone), 'retirement retains tombstone');
    assert(!registrations().some((row) => row.alias === retired.alias), 'retirement stops advertising');
    const pendingMail = JSON.parse(fs.readFileSync(path.join(broker, `${retiredRegistration.session_id}.inbox.json`), 'utf8'));
    assert(pendingMail.some((message) => message.content === retiredNonce), 'retirement preserves queued mail');
    const credentialHash = sha256(path.join(config, 'credential.json'));
    const stateHash = sha256(path.join(stateDir, 'state.json'));
    fs.chmodSync(config, 0o755);
    cli(['t3', 'service', 'repair', '--json']);
    assert.equal(fs.statSync(config).mode & 0o777, 0o700, 'repair private permissions');
    assert.equal(sha256(path.join(config, 'credential.json')), credentialHash, 'repair preserves credential');
    assert.equal(sha256(path.join(stateDir, 'state.json')), stateHash, 'repair preserves journal and tombstones');
    proof.cases.retirementAndRepair = { tombstone: true, pendingMailPreserved: true, credentialPreserved: true };
    const holds = readPrivate(path.join(stateDir, 'state.json')).holds;
    assert(holds.some((hold) => hold.thread_id === state.cases['full-access'].launch.threadId), 'permission-ineligible root has durable hold');
    proof.cases.permissionHold = true;
    const journal = readPrivate(path.join(stateDir, 'state.json'));
    const submissions = journal.acked.map((entry) => entry.result?.submitted_at).filter(Number.isFinite).sort((a, b) => a - b);
    assert(submissions.length >= 7, 'recovery and inbound submission receipts');
    const gaps = submissions.slice(1).map((time, index) => time - submissions[index]);
    assert(gaps.every((gap) => gap >= 0.99), 'shared process-wide one-second dispatch cap');
    const providerRows = fs.readFileSync(path.join(root, 'provider.ndjson'), 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
    const serviceReceipts = providerRows.filter((row) =>
      (row.method === 'turn/start' || row.method === 'turn/steer')
      && (row.continuation || row.proofNonceHashes?.length));
    const receivedAt = serviceReceipts.map((row) => row.timestamp).sort((a, b) => a - b);
    const receiptGaps = receivedAt.slice(1).map((time, index) => time - receivedAt[index]);
    assert(receivedAt.length >= 7, 'independent provider submission evidence');
    assert(receiptGaps.every((gap) => gap >= 1000), 'provider-observed one-second spacing');
    proof.cases.rateLimit = { submitted: submissions.length, minimumSpacingSeconds: Math.min(...gaps),
      providerReceipts: receivedAt.length, providerMinimumSpacingMs: Math.min(...receiptGaps) };
    proof.journal = { pending: journal.journal.length, acked: journal.acked.length };
    proof.completedAt = new Date().toISOString();
    return proof;
  } catch (error) {
    proof.status = 'FAIL';
    proof.failureKind = error.name;
    proof.failureFrames = String(error.stack ?? '').split('\n').filter((line) => line.trim().startsWith('at '));
    writePrivate(path.join(root, 'native-service-proof.json'), proof);
    throw error;
  } finally {
    await stopService();
    runner?.rpc?.close();
  }
}

export async function runServiceProof(options) {
  assert(!fs.existsSync(options.root), 'proof root must be fresh');
  // Validate the executables before creating or launching anything.
  for (const file of [options.t3Bin, options.c2cBin]) {
    assert(fs.statSync(fs.realpathSync(file)).isFile(), 'proof executable must be a regular file');
    fs.accessSync(file, fs.constants.X_OK);
  }
  let fixture;
  let proof;
  let failure;
  try {
    fixture = await startFixture(options);
    proof = await exerciseServiceProof(options, fixture);
  } catch (error) { failure = error; }
  // Always attempt fixture cleanup even when the service cleanup failed.
  if (fixture) {
    try { await stopFixture({ root: options.root, t3Bin: options.t3Bin }); }
    catch (error) { failure ??= error; }
  }
  if (failure) {
    const output = path.join(options.root, 'native-service-proof.json');
    try { proof ??= readPrivate(output); } catch { /* Setup failed before a proof existed. */ }
    if (fs.existsSync(options.root)) writePrivate(output, { ...proof, status: 'FAIL',
      failureKind: failure.name, failureFrames: String(failure.stack ?? '').split('\n').filter((line) => line.trim().startsWith('at ')) });
    throw failure;
  }
  proof.status = 'PASS';
  proof.cleanupCompleted = true;
  delete proof.stage;
  writePrivate(path.join(options.root, 'native-service-proof.json'), proof);
  return proof;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { console.log(JSON.stringify(await runServiceProof(parseArguments(process.argv.slice(2))))); }
  catch { console.error('Native service proof failed; inspect the private fixture root and service log.'); process.exitCode = 1; }
}
