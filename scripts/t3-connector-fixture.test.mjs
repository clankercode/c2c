import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  fixtureEnvironment, fixtureSettings, fixtureStatus, parseArguments, parseProcessStat,
  readFixtureState, sameIncarnation, sameProcess, startFixture, stopFixture,
} from './t3-connector-fixture.mjs';
import { readPrivate, writePrivate } from './t3-connector-probe.mjs';

// These tests use a tiny HTTP process, never a real installed T3 or real credentials.
const linux = { skip: process.platform !== 'linux' };

function scratch(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'c2c-t3-fixture-test-'));
  const t3Bin = path.join(directory, 'synthetic-t3.mjs');
  fs.writeFileSync(t3Bin, `#!${process.execPath}
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
assert.deepEqual(process.argv.slice(2), ['start', '--bootstrap-fd', '3', '--log-level', 'debug']);
const bootstrap = JSON.parse(fs.readFileSync(3, 'utf8'));
assert.equal(bootstrap.port, 0);
assert.equal(bootstrap.shellEnvironmentPrepared, true);
assert.equal(bootstrap.host, '127.0.0.1');
assert.equal(bootstrap.t3Home, path.join(process.cwd(), 't3'));
fs.writeFileSync(path.join(process.cwd(), 'observed-environment.json'), JSON.stringify(process.env), { mode: 0o600 });
fs.writeFileSync(path.join(process.cwd(), 'observed-bootstrap.json'), JSON.stringify(bootstrap), { mode: 0o600 });
const server = http.createServer((_request, response) => response.writeHead(401).end());
server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  fs.writeFileSync(path.join(bootstrap.t3Home, 'userdata/server-runtime.json'), JSON.stringify({
    version: 1, pid: process.pid, port, host: '127.0.0.1', origin: 'http://127.0.0.1:' + port,
    startedAt: new Date().toISOString(), serverVersion: 'fixture-1',
  }), { mode: 0o600 });
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
`, { mode: 0o700 });
  const options = { root: path.join(directory, 'isolated'), t3Bin, providerBin: t3Bin,
    startTimeoutMs: 5000, stopTimeoutMs: 2000 };
  // This cleanup runs before scratch-directory deletion, even when an assertion fails.
  t.after(async () => {
    try {
      if (fs.existsSync(path.join(options.root, 'setup-state.json'))) await stopFixture(options);
    } finally { fs.rmSync(directory, { recursive: true, force: true }); }
  });
  return options;
}

test('CLI requires explicit absolute paths and rejects duplicate or unknown options', () => {
  assert.equal(parseArguments(['start', '--root', '/tmp/fixture', '--t3-bin', '/opt/t3']).command, 'start');
  assert.equal(parseArguments(['status', '--root', '/tmp/fixture', '--t3-bin', '/opt/t3',
    '--provider-bin', '/tmp/provider']).providerBin, '/tmp/provider');
  for (const args of [[], ['run'], ['start', '--root', 'relative', '--t3-bin', '/opt/t3'],
    ['start', '--root', '/tmp/fixture'], ['start', '--root', '/tmp/fixture', '--t3-bin', '/opt/t3', '--root', '/tmp/other'],
    ['stop', '--root', '/tmp/fixture', '--t3-bin', '/opt/t3', '--force', 'yes'],
    ['start', '--root', '/tmp/fixture', '--t3-bin', '/opt/t3', '--provider-bin', 'relative']]) {
    assert.throws(() => parseArguments(args));
  }
});

test('environment is constructed independently of parent secrets and identities', () => {
  const environment = fixtureEnvironment('/tmp/isolated', 'owner');
  assert.deepEqual(Object.keys(environment).sort(), [
    'C2C_T3_FIXTURE_CONTROL', 'C2C_T3_FIXTURE_LOG', 'CODEX_HOME', 'HOME', 'LANG', 'PATH',
    'T3_CONNECTOR_FIXTURE_OWNER', 'T3_CONNECTOR_FIXTURE_ROOT', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME',
  ]);
  assert.equal(environment.HOME, '/tmp/isolated/home');
  assert.equal(environment.CODEX_HOME, '/tmp/isolated/codex-home');
  assert.equal(environment.C2C_T3_FIXTURE_LOG, '/tmp/isolated/provider.ndjson');
  assert.equal(environment.C2C_T3_FIXTURE_CONTROL, '/tmp/isolated/control.json');
  assert.equal(environment.PATH, '/usr/local/bin:/usr/bin:/bin');
  for (const key of ['T3CODE_HOME', 'T3CODE_C2C_ENABLED', 'T3_ACP_MCP_NODE', 'OPENAI_API_KEY',
    'ANTHROPIC_API_KEY', 'C2C_MCP_SESSION_ID', 'C2C_MCP_BROKER_ROOT']) assert.equal(environment[key], undefined);
});

test('settings configure only the synthetic Codex binary and synthetic homes', () => {
  const settings = fixtureSettings('/tmp/isolated', '/tmp/provider');
  assert.deepEqual(settings.providerInstances.codex, { driver: 'codex', enabled: true, config: {
    setupMode: 'existing', binaryPath: '/tmp/provider', homePath: '/tmp/isolated/codex-home',
    shadowHomePath: '', launchArgs: '', customModels: ['c2c-fixture'],
  } });
  assert.deepEqual(Object.keys(settings.providerInstances).sort(),
    ['antigravity', 'claudeAgent', 'codex', 'cursor', 'grok', 'muse', 'opencode', 'pi']);
  for (const [driver, instance] of Object.entries(settings.providerInstances)) {
    if (driver !== 'codex') assert.deepEqual(instance, { driver, enabled: false });
  }
});

test('Linux process parsing handles spaces and parentheses and retains exact start ticks', () => {
  const values = ['S', '2', '17', '17', ...Array(15).fill('0'), '9007199254740993', '0'];
  assert.deepEqual(parseProcessStat(`17 (name with ) parentheses) ${values.join(' ')}`), {
    status: 'S', parentPid: 2, groupId: 17, sessionId: 17, startTicks: '9007199254740993',
  });
  assert.throws(() => parseProcessStat('invalid'));
  assert.throws(() => parseProcessStat('17 (short) S 2 17'));
});

test('PID reuse, reboot, ownership, group changes, and executable swaps invalidate proofs', () => {
  const proof = { pid: 17, uid: 1000, bootId: 'boot', startTicks: '123', groupId: 17,
    sessionId: 17, executable: '/opt/t3', executableDevice: 1, executableInode: 2 };
  assert(sameProcess(proof, { ...proof }));
  assert.equal(sameIncarnation(undefined, undefined), false);
  assert.equal(sameProcess(proof, null), false);
  for (const field of ['pid', 'uid', 'bootId', 'startTicks']) {
    assert.equal(sameIncarnation(proof, { ...proof, [field]: 'different' }), false);
  }
  for (const field of ['groupId', 'sessionId', 'executable', 'executableDevice', 'executableInode']) {
    const changed = { ...proof, [field]: 'different' };
    assert.equal(sameIncarnation(proof, changed), true);
    assert.equal(sameProcess(proof, changed), false);
  }
});

test('start, status, and stop own one disposable process and keep bootstrap private', linux, async (t) => {
  const options = scratch(t);
  const started = await startFixture(options);
  assert.equal(started.status, 'running');
  assert.equal(started.serverVersion, 'fixture-1');
  assert.equal(fixtureStatus(options).pid, started.pid);
  const state = readFixtureState(options.root, options.t3Bin);
  assert.equal(state.process.pid, started.pid);
  assert.equal(state.process.groupId, started.pid);
  assert.equal(state.process.sessionId, started.pid);
  assert.equal(state.desktopBootstrapToken.length, 43);
  assert(!JSON.stringify(started).includes(state.desktopBootstrapToken));
  const observed = readPrivate(path.join(options.root, 'observed-bootstrap.json'));
  assert.equal(observed.desktopBootstrapToken, state.desktopBootstrapToken);
  const environment = readPrivate(path.join(options.root, 'observed-environment.json'));
  assert.equal(environment.HOME, path.join(options.root, 'home'));
  assert.equal(environment.C2C_MCP_SESSION_ID, undefined);
  assert.equal(environment.OPENAI_API_KEY, undefined);
  for (const name of ['fixture-owner.json', 'setup-state.json', 'server.log']) {
    assert.equal(fs.statSync(path.join(options.root, name)).mode & 0o777, 0o600);
  }
  assert.equal(fs.statSync(options.root).mode & 0o777, 0o700);
  assert.equal((await stopFixture(options)).status, 'stopped');
  assert.equal(fixtureStatus(options).status, 'stopped');
  assert.equal((await stopFixture(options)).status, 'stopped', 'stopping again is harmless');
  assert(fs.existsSync(path.join(options.root, 'setup-state.json')), 'keep evidence and credentials');
});

test('an existing root is never reused, even after the fixture stopped', linux, async (t) => {
  const options = scratch(t);
  await startFixture(options);
  await stopFixture(options);
  const before = fs.readFileSync(path.join(options.root, 'setup-state.json'), 'utf8');
  await assert.rejects(startFixture(options), { code: 'EEXIST' });
  assert.equal(fs.readFileSync(path.join(options.root, 'setup-state.json'), 'utf8'), before);
});

test('writable executables are refused before reserving a scratch root', linux, async (t) => {
  const options = scratch(t);
  fs.chmodSync(options.t3Bin, 0o722);
  await assert.rejects(startFixture(options), /without group or other writes/);
  assert.equal(fs.existsSync(options.root), false);
  fs.chmodSync(options.t3Bin, 0o700);
});

test('wrong binary and changed incarnation refuse stop without signaling the real fixture', linux, async (t) => {
  const options = scratch(t);
  const started = await startFixture(options);
  await assert.rejects(stopFixture({ ...options, t3Bin: process.execPath }), /ownership record/);
  assert.equal(fixtureStatus(options).status, 'running');
  const statePath = path.join(options.root, 'setup-state.json');
  const original = readPrivate(statePath);
  writePrivate(statePath, { ...original, process: { ...original.process, startTicks: '0' } });
  try {
    assert.throws(() => fixtureStatus(options), /identity/);
    await assert.rejects(stopFixture(options), /changed fixture process/);
    assert.doesNotThrow(() => process.kill(started.pid, 0));
  } finally { writePrivate(statePath, original); }
});

test('a competing or stale lifecycle lock is preserved and no process is signaled', linux, async (t) => {
  const options = scratch(t);
  await startFixture(options);
  const filename = path.join(options.root, 'lifecycle.lock');
  fs.writeFileSync(filename, 'inspect me', { mode: 0o600 });
  try {
    await assert.rejects(stopFixture(options), { code: 'EEXIST' });
    assert.equal(fs.readFileSync(filename, 'utf8'), 'inspect me');
    assert.equal(fixtureStatus(options).status, 'running');
  } finally { fs.unlinkSync(filename); }
});

test('symlinked roots and absent stop roots are rejected without touching a target', linux, async (t) => {
  const options = scratch(t);
  const target = path.join(path.dirname(options.root), 'target');
  fs.mkdirSync(target, { mode: 0o700 });
  fs.symlinkSync(target, options.root);
  await assert.rejects(startFixture(options));
  await assert.rejects(stopFixture(options));
  assert.deepEqual(fs.readdirSync(target), []);
  fs.unlinkSync(options.root);
  await assert.rejects(stopFixture(options), { code: 'ENOENT' });
  assert.equal(fs.existsSync(options.root), false);
});

test('startup failures retain private evidence and stop the owned child', linux, async (t) => {
  const options = scratch(t);
  fs.writeFileSync(options.t3Bin, `#!${process.execPath}\nimport fs from 'node:fs';\nfs.readFileSync(3);\nprocess.exit(7);\n`, { mode: 0o700 });
  await assert.rejects(startFixture(options), /exited/);
  const state = readPrivate(path.join(options.root, 'setup-state.json'));
  assert.equal(state.startupFailed, true);
  assert.equal(state.status, 'stopped');
  assert.equal(fixtureStatus(options).status, 'stopped');
});
