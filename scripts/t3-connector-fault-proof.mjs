#!/usr/bin/env node
// Actual native dispatcher + native MCP client against owned STOCK T3 0.1.1.
// The OCaml harness discards one accepted receipt. JavaScript never sends
// Continue. This is NOT a foreground-service or real-model-outage proof.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { startFixture, stopFixture } from './t3-connector-fixture.mjs';
import { main as probe, authorizedProbe, readPrivate, writePrivate } from './t3-connector-probe.mjs';
import { MatrixRunner } from './t3-connector-matrix.mjs';

const hashFile = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const continuations = (snapshot) => snapshot.items.filter((item) => item.type === 'user_message' && item.text === 'Continue');

export function parseArguments(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    assert(['--root', '--t3-bin', '--c2c-bin', '--fault-bin'].includes(key)
      && !args[key] && path.isAbsolute(argv[i + 1] ?? ''), 'unique absolute options');
    args[key] = argv[i + 1];
  }
  assert.equal(Object.keys(args).length, 4);
  return { root: args['--root'], t3Bin: args['--t3-bin'], c2cBin: args['--c2c-bin'], faultBin: args['--fault-bin'] };
}

async function exercise(options, fixture, evidence) {
  const { root } = options;
  const config = path.join(root, 'native-config');
  const nativeHome = path.join(root, 'native-home');
  for (const dir of [config, nativeHome]) fs.mkdirSync(dir, { mode: 0o700 });
  const env = { HOME: nativeHome, PATH: process.env.PATH, LANG: 'C.UTF-8',
    T3CODE_HOME: fixture.t3Home, C2C_T3_CONFIG_DIR: config, C2C_NO_AUTO_REGISTER: '1' };
  const assertBinariesStable = () => {
    assert.equal(hashFile(options.c2cBin), evidence.c2cSha256, 'c2c changed during the proof');
    assert.equal(hashFile(options.faultBin), evidence.faultHarnessSha256, 'fault harness changed during the proof');
  };
  const pair = (replace = false) => {
    assertBinariesStable();
    const output = execFileSync(options.t3Bin, ['auth', 'pairing', 'create', '--base-dir', fixture.t3Home,
      '--scope', 'orchestration:read', '--scope', 'orchestration:operate', '--ttl', '10m',
      '--label', 'c2c dispatcher fault proof', '--json'], { encoding: 'utf8', timeout: 30_000, stdio: ['ignore', 'pipe', 'pipe'] });
    const code = JSON.parse(output.slice(output.indexOf('{')));
    execFileSync(options.c2cBin, ['t3', 'pair', '--pairing-code', code.credential ?? code.token ?? code.code,
      ...(replace ? ['--replace'] : []), '--json'], { env, cwd: root, timeout: 45_000, stdio: ['ignore', 'pipe', 'pipe'] });
  };
  await probe(['pair', '--state-dir', path.join(root, 'probe'), '--t3-home', fixture.t3Home, '--t3-bin', options.t3Bin]);
  const { client } = authorizedProbe({ 'state-dir': path.join(root, 'probe'), 't3-home': fixture.t3Home });
  await client.initialize();
  const capabilities = await client.call('orchestrator_capabilities');
  const provider = capabilities.providers.find((p) => p.driverKind === 'codex' && p.models.some((m) => m.id === 'c2c-fixture'));
  assert(provider, 'owned offline provider');
  const state = { nonce: crypto.randomUUID(), cases: {} };
  const runner = new MatrixRunner({ state, save: () => writePrivate(path.join(root, 'driver-state.json'), state), client,
    options: { ...options, stateDir: path.join(root, 'probe') },
    modelSelection: { instanceId: provider.providerInstanceId, model: 'c2c-fixture' } });
  const children = new Set();
  const startNative = (action, name, label, stateName = name) => {
    assertBinariesStable();
    const output = path.join(root, `${label}.json`);
    const gate = path.join(root, `${label}-gate`);
    const log = fs.openSync(path.join(root, `${label}.log`), 'wx', 0o600);
    let child;
    try { child = spawn(options.faultBin, [action, state.cases[name].threadId,
      path.join(root, `${stateName}-journal`), output, gate, 'owned-stock-t3-fixture-only'],
    { env, cwd: root, stdio: ['ignore', log, log] }); }
    finally { fs.closeSync(log); }
    children.add(child);
    // Register immediately: a spawn error must reject the operation and still
    // let the outer finally attempt every remaining owned cleanup.
    const completion = once(child, 'exit');
    completion.catch(() => {});
    const timer = setTimeout(() => child.kill('SIGTERM'), 65_000);
    timer.unref();
    const done = async () => {
      try { const [code, signal] = await completion;
        assert(code === 0 && signal === null, `native ${label} completed`);
        return readPrivate(output);
      } finally { clearTimeout(timer); children.delete(child); }
    };
    return { done, gate, child };
  };
  const native = (action, name, label, stateName) => startNative(action, name, label, stateName).done();
  try {
    pair();
    evidence.stage = 'data-response-loss';
    await runner.thread('data');
    const lost = await native('inbound-loss', 'data', 'data-lost');
    assert.equal(lost.step, 'retained'); assert.equal(lost.sendCalls, 1);
    assert.equal(lost.accepted.length, 1); assert.equal(lost.pending[0].attempts, 1);
    const original = lost.accepted[0];
    await runner.wait('data', (s) => s.items.some((i) => i.messageId === original.messageId), 'accepted DATA projection');
    const replay = await native('inbound-retry', 'data', 'data-replayed');
    assert.equal(replay.step, 'submitted'); assert.equal(replay.sendCalls, 1);
    assert.deepEqual(replay.accepted, lost.accepted, 'same OAuth request yields exact same receipt');
    const dataSnapshot = await runner.wait('data', (s) => s.thread.activeRunId === null, 'DATA provider completion');
    assert.equal(dataSnapshot.items.filter((i) => i.type === 'user_message' && i.messageId === original.messageId).length, 1);
    assert.equal(dataSnapshot.items.filter((i) => i.type === 'user_message' && i.text?.includes('C2C_NATIVE_fault_')).length, 1);
    evidence.cases.dataResponseLoss = { sameGeneration: true, separateProcesses: true,
      exactReceiptReplay: true, userMessages: 1, pending: replay.pending.length };

    evidence.stage = 'recovery-response-loss';
    const failed = await runner.send('recovery', 'kickoff', `C2C_FIXTURE:availability ${state.nonce}`, 'auto');
    await runner.ended('recovery', failed, 'failed');
    const recoveryLost = await native('recovery-loss', 'recovery', 'recovery-lost');
    assert.equal(recoveryLost.step, 'retained'); assert.equal(recoveryLost.accepted.length, 1);
    await runner.wait('recovery', (s) => continuations(s).length === 1 && s.thread.activeRunId === null, 'native recovery accepted');
    const held = await native('recovery-retry', 'recovery', 'recovery-held');
    assert.equal(held.step, 'held'); assert.equal(held.sendCalls, 0);
    assert.equal(held.preflightCalls, 1, 'changed activity held by actual recovery preflight');
    assert.equal(held.credentialFenceHeld, false, 'same-credential hold is not the identity fence');
    assert.equal(held.pending[0].uncertain, true); assert.equal(held.pending[0].status, 'held');
    assert.equal(continuations(await runner.snapshot('recovery')).length, 1);
    evidence.cases.recoveryChangedActivity = { continuations: 1, retainedUncertainty: true,
      replayCalls: 0, separateProcesses: true };

    evidence.stage = 'credential-rotation';
    const rotationFailure = await runner.send('rotation', 'kickoff', `C2C_FIXTURE:availability ${state.nonce}`, 'auto');
    await runner.ended('rotation', rotationFailure, 'failed');
    const rotationLost = await native('recovery-loss', 'rotation', 'rotation-lost');
    assert.equal(rotationLost.step, 'retained'); assert.equal(rotationLost.accepted.length, 1);
    await runner.wait('rotation', (s) => continuations(s).length === 1 && s.thread.activeRunId === null, 'pre-rotation accepted Continue');
    // Simulate losing the credential file, retaining the old private bytes for
    // audit. Numeric generation restarts at one; OAuth namespace MUST differ.
    fs.renameSync(path.join(config, 'credential.json'), path.join(config, 'credential-before-loss.json'));
    pair();
    const rotationHeld = await native('recovery-retry', 'rotation', 'rotation-held');
    assert.equal(rotationHeld.credentialGeneration, rotationLost.credentialGeneration, 'lost file reuses numeric generation');
    assert.notEqual(rotationHeld.credentialIdentity, rotationLost.credentialIdentity, 'actual new PKCE/OAuth namespace');
    assert.equal(rotationHeld.pending[0].credential_generation, rotationLost.credentialGeneration);
    assert.equal(rotationHeld.pending[0].credential_identity, rotationLost.credentialIdentity);
    assert.equal(rotationHeld.step, 'held'); assert.equal(rotationHeld.sendCalls, 0);
    assert.equal(rotationHeld.preflightCalls, 0, 'credential fence precedes all recovery preflight reads');
    assert.equal(rotationHeld.credentialFenceHeld, true, 'explicit credential uncertainty fence');
    assert.equal(rotationHeld.pending[0].uncertain, true);
    assert.equal(continuations(await runner.snapshot('rotation')).length, 1);
    evidence.cases.credentialRotation = { reusedNumericGeneration: true, distinctCredentialIdentity: true,
      originalIdentityRetained: true,
      preflightCalls: 0, credentialFenceHeld: true,
      continuations: 1, sendsUnderNewCredential: 0 };

    evidence.stage = 'queue-start-race';
    const raceFailure = await runner.send('race', 'kickoff', `C2C_FIXTURE:availability ${state.nonce}`, 'auto');
    await runner.ended('race', raceFailure, 'failed');
    const race = startNative('recovery-race', 'race', 'race');
    const deadline = Date.now() + 35_000;
    while (!fs.existsSync(`${race.gate}.ready`)) {
      assert(Date.now() < deadline && race.child.exitCode === null, 'real recovery preflight reached gate');
      await delay(50);
    }
    const user = await runner.send('race', 'concurrent-user', `C2C_FIXTURE:hold ${state.nonce}`, 'auto');
    await runner.wait('race', (s) => s.thread.activeRunId === user.runId, 'concurrent active user turn');
    writePrivate(`${race.gate}.release`, { release: true });
    const queued = await race.done();
    assert.equal(queued.step, 'submitted'); assert.equal(queued.sendCalls, 1);
    const raceSnapshot = await runner.wait('race', (s) => s.queuedRunIds.includes(queued.accepted[0].runId), 'Continue queued behind active turn');
    assert.equal(raceSnapshot.thread.activeRunId, user.runId, 'active user run preserved');
    const providerRows = fs.readFileSync(path.join(root, 'provider.ndjson'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
    assert.equal(providerRows.filter((r) => r.method === 'turn/steer' && r.continuation).length, 0);
    evidence.cases.concurrentStart = { injectedAfterFreshPreflight: true, activeUserRunPreserved: true,
      recoveryQueued: true, continueSteerCalls: 0 };
    assertBinariesStable();
    return evidence;
  } finally {
    let cleanupFailure;
    for (const child of children) {
      if (child.exitCode === null && child.signalCode === null) {
        try {
          const stopped = once(child, 'exit'); child.kill('SIGTERM');
          await Promise.race([stopped, delay(5000).then(() => { throw new Error('owned fault harness cleanup timeout'); })]);
        } catch (error) { cleanupFailure ??= error; }
      }
    }
    runner.rpc?.close();
    if (cleanupFailure) throw cleanupFailure;
  }
}

export async function runFaultProof(options) {
  assert(!fs.existsSync(options.root), 'fresh explicit private fixture root');
  for (const binary of [options.t3Bin, options.c2cBin, options.faultBin]) {
    assert(fs.statSync(fs.realpathSync(binary)).isFile()); fs.accessSync(binary, fs.constants.X_OK);
  }
  let fixture; let failure;
  const evidence = { schema: 'c2c-t3-shared-dispatcher-fault-proof-v1', hostname: os.hostname(),
    c2cSha256: hashFile(options.c2cBin), faultHarnessSha256: hashFile(options.faultBin),
    t3Sha256: hashFile(options.t3Bin), realModelOutageTested: false,
    foregroundServiceTested: false, fault: 'discard-one-successful-native-MCP-receipt', cases: {} };
  try {
    fixture = await startFixture(options);
    assert.equal(fixture.serverVersion, '0.1.1');
    evidence.serverVersion = fixture.serverVersion;
    await exercise(options, fixture, evidence);
  } catch (error) { failure = error; }
  if (fixture) {
    try { await stopFixture({ root: options.root, t3Bin: options.t3Bin }); }
    catch (error) { failure ??= error; }
  }
  evidence.status = failure ? 'FAIL' : 'PASS';
  evidence.cleanupCompleted = !failure;
  if (failure) {
    evidence.failureKind = failure.name;
    evidence.failureFrames = String(failure.stack ?? '').split('\n').filter((line) => line.trim().startsWith('at '));
  } else delete evidence.stage;
  if (fs.existsSync(options.root)) writePrivate(path.join(options.root, 'dispatcher-fault-proof.json'), evidence);
  if (failure) throw failure;
  return evidence;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { console.log(JSON.stringify(await runFaultProof(parseArguments(process.argv.slice(2))))); }
  catch { console.error('Dispatcher fault proof failed; inspect the private fixture root.'); process.exitCode = 1; }
}
