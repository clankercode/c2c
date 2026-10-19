#!/usr/bin/env node
// Development-only installed-T3 fixture. Never discovers or restarts a user's T3.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readPrivate, runtimeState, withStateLock, writePrivate } from './t3-connector-probe.mjs';

const VERSION = 1;
const STATE_NAME = 'setup-state.json';
const OWNER_NAME = 'fixture-owner.json';
const DEFAULT_PROVIDER = fileURLToPath(new URL('./fixtures/t3-codex-provider.mjs', import.meta.url));
const REPOSITORY = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const DEFAULT_START_TIMEOUT = 90_000;
const DEFAULT_STOP_TIMEOUT = 10_000;

class FixtureError extends Error {}
const fail = (message) => { throw new FixtureError(message); };
const contained = (root, filename) => filename === root || filename.startsWith(`${root}${path.sep}`);

export function parseArguments(args) {
  const [command, ...rest] = args;
  if (!['start', 'stop', 'status'].includes(command)) fail('Expected start, stop, or status');
  const options = {};
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index];
    if (!['--root', '--t3-bin', '--provider-bin'].includes(key) || !rest[index + 1]
        || Object.hasOwn(options, key)) fail('Expected unique --root, --t3-bin, and optional --provider-bin options');
    options[key] = rest[index + 1];
  }
  if (!path.isAbsolute(options['--root'] ?? '') || !path.isAbsolute(options['--t3-bin'] ?? '')) {
    fail('--root and --t3-bin must be explicit absolute paths');
  }
  if (options['--provider-bin'] && !path.isAbsolute(options['--provider-bin'])) {
    fail('--provider-bin must be an absolute path');
  }
  return { command, root: path.resolve(options['--root']), t3Bin: options['--t3-bin'],
    providerBin: options['--provider-bin'] ?? DEFAULT_PROVIDER };
}

export function fixtureEnvironment(root, ownerId) {
  // Deliberate allowlist: no real HOME, provider tokens, ACP state, or c2c identity.
  return {
    HOME: path.join(root, 'home'), CODEX_HOME: path.join(root, 'codex-home'),
    XDG_CONFIG_HOME: path.join(root, 'xdg-config'), XDG_DATA_HOME: path.join(root, 'xdg-data'),
    XDG_CACHE_HOME: path.join(root, 'xdg-cache'), PATH: '/usr/local/bin:/usr/bin:/bin', LANG: 'C.UTF-8',
    T3_CONNECTOR_FIXTURE_ROOT: root, T3_CONNECTOR_FIXTURE_OWNER: ownerId,
    C2C_T3_FIXTURE_LOG: path.join(root, 'provider.ndjson'),
    C2C_T3_FIXTURE_CONTROL: path.join(root, 'control.json'),
  };
}

export function fixtureSettings(root, providerBin) {
  return { providerInstances: {
    codex: { driver: 'codex', enabled: true, config: {
      setupMode: 'existing', binaryPath: providerBin, homePath: path.join(root, 'codex-home'),
      shadowHomePath: '', launchArgs: '', customModels: ['c2c-fixture'],
    } },
    // Match the stock driver's IDs, including claudeAgent (not "claude").
    // Most are disabled by default today; make the fixture's intent explicit.
    ...Object.fromEntries(['claudeAgent', 'cursor', 'grok', 'muse', 'pi', 'opencode', 'antigravity']
      .map((driver) => [driver, { driver, enabled: false }])),
  } };
}

export function parseProcessStat(raw) {
  const closing = raw.lastIndexOf(')');
  const fields = raw.slice(closing + 2).trim().split(/\s+/);
  if (closing < 0 || fields.length < 20 || !/^\d+$/.test(fields[19])) fail('Invalid Linux process identity');
  return { status: fields[0], parentPid: Number(fields[1]), groupId: Number(fields[2]),
    sessionId: Number(fields[3]), startTicks: fields[19] };
}

export function sameIncarnation(expected, actual) {
  return Boolean(expected && actual && expected.pid === actual.pid && expected.uid === actual.uid
    && expected.bootId === actual.bootId && expected.startTicks === actual.startTicks);
}

export function sameProcess(expected, actual) {
  return sameIncarnation(expected, actual) && expected?.groupId === actual?.groupId
    && expected?.sessionId === actual?.sessionId && expected?.executableDevice === actual?.executableDevice
    && expected?.executableInode === actual?.executableInode && expected?.executable === actual?.executable;
}

function processProof(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 1) fail('Invalid recorded process PID');
  try {
    const proc = `/proc/${pid}`;
    const owner = fs.statSync(proc);
    const stat = parseProcessStat(fs.readFileSync(`${proc}/stat`, 'utf8'));
    if (stat.status === 'Z' || stat.status === 'X') return null;
    const executable = fs.statSync(`${proc}/exe`);
    const environment = Object.fromEntries(fs.readFileSync(`${proc}/environ`, 'utf8').split('\0')
      .filter(Boolean).map((entry) => { const index = entry.indexOf('='); return [entry.slice(0, index), entry.slice(index + 1)]; }));
    return { pid, uid: owner.uid, ...stat,
      bootId: fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim(),
      executable: fs.readlinkSync(`${proc}/exe`), executableDevice: executable.dev, executableInode: executable.ino,
      cwd: fs.realpathSync(`${proc}/cwd`),
      fixtureRoot: environment.T3_CONNECTOR_FIXTURE_ROOT,
      fixtureOwner: environment.T3_CONNECTOR_FIXTURE_OWNER,
    };
  } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ESRCH') return null;
    throw error;
  }
}

function assertOwnedProcess(state, proof) {
  if (proof?.uid !== process.getuid() || proof.fixtureRoot !== state.root
      || proof.fixtureOwner !== state.ownerId || !contained(state.root, proof.cwd)
      || proof.groupId !== state.process.pid || proof.sessionId !== state.process.pid) {
    fail('Recorded process group no longer proves fixture ownership');
  }
}

function groupMembers(state) {
  const result = [];
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    let stat;
    try { stat = parseProcessStat(fs.readFileSync(`/proc/${entry}/stat`, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') continue; throw error; }
    if (stat.groupId !== state.process.pid || ['Z', 'X'].includes(stat.status)) continue;
    const proof = processProof(Number(entry));
    if (proof) { assertOwnedProcess(state, proof); result.push(proof); }
  }
  return result;
}

function assertPrivateDirectory(directory) {
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077)
      || fs.realpathSync(directory) !== directory) fail('Fixture directory must be canonical, same-user, and mode 0700');
}

function canonicalExecutable(filename) {
  const resolved = fs.realpathSync(filename);
  const stat = fs.statSync(resolved);
  if (!stat.isFile() || ![0, process.getuid()].includes(stat.uid) || (stat.mode & 0o022)) {
    fail('Fixture executables must be regular files owned by root or this user, without group or other writes');
  }
  fs.accessSync(resolved, fs.constants.X_OK);
  return resolved;
}

function statePaths(root) {
  return { statePath: path.join(root, STATE_NAME), ownerPath: path.join(root, OWNER_NAME),
    lockPath: path.join(root, 'lifecycle.lock') };
}

export function readFixtureState(root, t3Bin) {
  assertPrivateDirectory(root);
  const { statePath, ownerPath } = statePaths(root);
  const owner = readPrivate(ownerPath);
  const state = readPrivate(statePath);
  if (state.version !== VERSION || owner.version !== VERSION || state.root !== root
      || owner.root !== root || !state.ownerId || state.ownerId !== owner.ownerId
      || state.t3Bin !== owner.t3Bin || canonicalExecutable(t3Bin) !== state.t3Bin
      || state.t3Home !== path.join(root, 't3') || state.logPath !== path.join(root, 'server.log')) {
    fail('Fixture ownership record does not match the explicit root and T3 executable');
  }
  assertPrivateDirectory(state.t3Home);
  assertPrivateDirectory(path.join(state.t3Home, 'userdata'));
  return state;
}

function summary(state, runtime, status) {
  return { status, root: state.root, t3Home: state.t3Home, logPath: state.logPath,
    providerLogPath: path.join(state.root, 'provider.ndjson'), controlPath: path.join(state.root, 'control.json'),
    setupStatePath: path.join(state.root, STATE_NAME),
    ...(state.process ? { pid: state.process.pid } : {}),
    ...(runtime ? { origin: runtime.origin, serverVersion: runtime.serverVersion } : {}),
  };
}

function runtimeFor(state) {
  const leader = processProof(state.process?.pid);
  if (!leader || !sameProcess(state.process, leader)) fail('Fixture leader incarnation or executable changed');
  assertOwnedProcess(state, leader);
  const runtime = runtimeState(state.t3Home);
  const server = processProof(runtime.pid);
  assertOwnedProcess(state, server);
  return runtime;
}

async function stopOwned(state, save, timeoutMs) {
  if (!state.process) {
    state.status = 'stopped'; save();
    return summary(state, null, 'stopped');
  }
  const leader = processProof(state.process.pid);
  if (leader && !sameProcess(state.process, leader)) fail('Refusing to signal a changed fixture process');
  if (leader) assertOwnedProcess(state, leader);
  const members = groupMembers(state);
  if (!members.length) {
    state.status = 'stopped'; state.stoppedAt = new Date().toISOString(); save();
    return summary(state, null, 'stopped');
  }
  if (!leader) fail('Fixture has surviving children but no recorded leader; manual inspection required');
  state.status = 'stopping'; state.stopMembers = members; save();
  // Revalidate immediately before each group signal; a PID number alone is never authority.
  const signalGroup = (signal) => {
    const current = groupMembers(state);
    for (const member of current) {
      const expected = state.stopMembers.find((entry) => entry.pid === member.pid);
      if (!expected || !sameProcess(expected, member)) fail('Fixture process group changed during shutdown');
    }
    if (!current.length) return;
    try { process.kill(-state.process.pid, signal); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
  };
  signalGroup('SIGTERM');
  const deadline = Date.now() + timeoutMs;
  while (groupMembers(state).length && Date.now() < deadline) await delay(50);
  if (groupMembers(state).length) {
    signalGroup('SIGKILL');
    const killDeadline = Date.now() + Math.min(timeoutMs, 5000);
    while (groupMembers(state).length && Date.now() < killDeadline) await delay(50);
    if (groupMembers(state).length) fail('Fixture process group did not stop within its deadline');
  }
  state.status = 'stopped'; state.stoppedAt = new Date().toISOString(); save();
  return summary(state, null, 'stopped');
}

export async function startFixture({ root, t3Bin, providerBin = DEFAULT_PROVIDER,
  startTimeoutMs = DEFAULT_START_TIMEOUT, stopTimeoutMs = DEFAULT_STOP_TIMEOUT }) {
  if (process.platform !== 'linux') fail('Fixture process ownership requires Linux /proc');
  if (!path.isAbsolute(root) || path.resolve(root) !== root || root === path.parse(root).root
      || contained(REPOSITORY, root) || fs.realpathSync(path.dirname(root)) !== path.dirname(root)) {
    fail('Use a canonical new scratch root outside the repository');
  }
  t3Bin = canonicalExecutable(t3Bin);
  providerBin = canonicalExecutable(providerBin);
  // Exclusive mkdir is the reservation: an existing root is never adopted or overwritten.
  fs.mkdirSync(root, { mode: 0o700 });
  assertPrivateDirectory(root);
  const { ownerPath, statePath, lockPath } = statePaths(root);
  const state = { version: VERSION, root, ownerId: crypto.randomUUID(), t3Bin, providerBin,
    t3Home: path.join(root, 't3'), logPath: path.join(root, 'server.log'),
    desktopBootstrapToken: crypto.randomBytes(32).toString('base64url'),
    status: 'preparing', createdAt: new Date().toISOString() };
  writePrivate(ownerPath, { version: VERSION, root, ownerId: state.ownerId, t3Bin }, false);
  const save = () => writePrivate(statePath, state);
  save();
  return withStateLock(lockPath, async () => {
    const environment = fixtureEnvironment(root, state.ownerId);
    for (const directory of ['home', 'codex-home', 'xdg-config', 'xdg-data', 'xdg-cache', 't3', 't3/userdata']) {
      fs.mkdirSync(path.join(root, directory), { mode: 0o700 });
    }
    writePrivate(path.join(state.t3Home, 'userdata/settings.json'), fixtureSettings(root, providerBin), false);
    const logFd = fs.openSync(state.logPath, 'wx', 0o600);
    let child;
    try {
      state.status = 'launching'; save();
      child = spawn(t3Bin, ['start', '--bootstrap-fd', '3', '--log-level', 'debug'], {
        cwd: root, env: environment, detached: true, stdio: ['ignore', logFd, logFd, 'pipe'],
      });
      let spawnError;
      child.on('error', (error) => { spawnError = error; });
      await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
      const launched = processProof(child.pid);
      if (!launched) fail('Fixture exited before its process identity could be recorded');
      state.process = launched;
      assertOwnedProcess(state, launched);
      state.status = 'starting'; save();
      // The synthetic bootstrap secret is only in this private state and the inherited pipe.
      child.stdio[3].on('error', () => {});
      child.stdio[3].end(`${JSON.stringify({ mode: 'desktop', noBrowser: true, port: 0,
        t3Home: state.t3Home, host: '127.0.0.1', desktopBootstrapToken: state.desktopBootstrapToken,
        shellEnvironmentPrepared: true, tailscaleServeEnabled: false, tailscaleServePort: 443,
      })}\n`);
      child.stdio[3].unref?.();
      const deadline = Date.now() + startTimeoutMs;
      while (Date.now() < deadline) {
        if (spawnError) fail('Installed T3 fixture spawn failed');
        const current = processProof(child.pid);
        if (!current) fail('Installed T3 fixture exited during startup');
        if (!sameIncarnation(launched, current)) fail('Fixture leader incarnation changed during startup');
        assertOwnedProcess(state, current);
        // An installed launcher may exec its bundled runtime; record the observed final executable.
        state.process = current;
        let runtime;
        try { runtime = runtimeFor(state); } catch { /* Runtime state is published asynchronously. */ }
        if (runtime) {
          let response;
          try {
            response = await fetch(`${runtime.origin}/mcp`, {
              redirect: 'error', signal: AbortSignal.timeout(Math.min(1000, Math.max(1, deadline - Date.now()))),
            });
            await response.body?.cancel();
          } catch { /* The listener can precede MCP readiness. */ }
          if (response?.status === 401) {
            state.status = 'running'; state.runtime = { pid: runtime.pid, origin: runtime.origin,
              serverVersion: runtime.serverVersion, startedAt: runtime.startedAt };
            state.readyAt = new Date().toISOString(); save();
            child.unref();
            return summary(state, runtime, 'running');
          }
        }
        save();
        await delay(100);
      }
      fail('Installed T3 fixture startup timed out; inspect private server.log');
    } catch (error) {
      state.startupFailed = true;
      try { await stopOwned(state, save, stopTimeoutMs); }
      catch { state.status = 'cleanup_required'; save(); }
      throw error;
    } finally {
      child?.unref();
      fs.closeSync(logFd);
    }
  });
}

export async function stopFixture({ root, t3Bin, stopTimeoutMs = DEFAULT_STOP_TIMEOUT }) {
  // Validate before the shared lock helper, which can otherwise create its parent.
  readFixtureState(root, t3Bin);
  const { statePath, lockPath } = statePaths(root);
  return withStateLock(lockPath, async () => {
    const state = readFixtureState(root, t3Bin);
    return stopOwned(state, () => writePrivate(statePath, state), stopTimeoutMs);
  });
}

export function fixtureStatus({ root, t3Bin }) {
  const state = readFixtureState(root, t3Bin);
  if (!state.process) return summary(state, null, state.status);
  const leader = processProof(state.process.pid);
  if (!leader) {
    const remaining = groupMembers(state);
    return summary(state, null, remaining.length ? 'cleanup_required' : 'stopped');
  }
  if (!sameProcess(state.process, leader)) fail('Fixture process identity differs from its ownership record');
  return summary(state, runtimeFor(state), state.status);
}

async function main() {
  try {
    const options = parseArguments(process.argv.slice(2));
    const result = options.command === 'start' ? await startFixture(options)
      : options.command === 'stop' ? await stopFixture(options) : fixtureStatus(options);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`${error instanceof FixtureError ? error.message : 'Fixture operation failed; inspect the private root and server.log'}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) await main();
