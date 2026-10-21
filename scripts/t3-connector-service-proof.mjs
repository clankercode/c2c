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

export async function runServiceProof(options) {
  // A fresh private root prevents accidental replay of launch intents. Evidence
  // from an incomplete run stays on disk and requires a new explicit root.
  assert(!fs.existsSync(options.root), 'proof root must be fresh');
  const fixture = await startFixture(options);
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
    const mappingFor = (name) => mappings.find((m) => m.thread_id === state.cases[name].threadId || m.threadId === state.cases[name].threadId);
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
    }
    proof.cases.direct = { idle: true, active: true, attribution: 'agent/mcp', sharedBrokerFooter: true };
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
    proof.cases.restart = { aliasesStable: true, duplicateContinuations: 0 };
    await stopService();
    // Disable before introducing a new eligible failure; no test code submits a
    // continuation or edits the connector journal to manufacture this result.
    proof.stage = 'disable';
    cli(['t3', 'service', 'recovery', 'disable']);
    delete env.C2C_T3_RECOVERY;
    const disabled = await runner.send('disabled', 'kickoff', `C2C_FIXTURE:availability ${state.nonce}`, 'auto');
    await runner.ended('disabled', disabled, 'failed');
    cli(['t3', 'service', '--once']);
    assert.equal(continuations(await runner.snapshot('disabled')).length, 0, 'durable disable');
    proof.cases.disable = true;
    const journal = readPrivate(path.join(stateDir, 'state.json'));
    proof.journal = { pending: journal.journal.length, acked: journal.acked.length };
    proof.completedAt = new Date().toISOString();
    proof.status = 'PASS';
    delete proof.stage;
    writePrivate(path.join(root, 'native-service-proof.json'), proof);
    return proof;
  } catch (error) {
    proof.status = 'FAIL';
    proof.failureKind = error.name;
    writePrivate(path.join(root, 'native-service-proof.json'), proof);
    throw error;
  } finally {
    await stopService();
    runner?.rpc?.close();
    await stopFixture({ root, t3Bin: options.t3Bin });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { console.log(JSON.stringify(await runServiceProof(parseArguments(process.argv.slice(2))))); }
  catch { console.error('Native service proof failed; inspect the private fixture root and service log.'); process.exitCode = 1; }
}
