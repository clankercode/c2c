#!/usr/bin/env node
// Development-only compatibility probe. The shipped connector remains OCaml.
// Uses its own scoped credential; never reads a provider or t3-bridge token.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const MAX_RESPONSE = 8 * 1024 * 1024;
const PROTOCOL = '2025-06-18';
const REQUIRED_TOOLS = [
  'orchestrator_capabilities', 't3_project_list', 't3_thread_list',
  't3_thread_read', 't3_thread_send',
];
const b64url = (bytes) => bytes.toString('base64url');
const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');

export function parseRpc(body, contentType, id) {
  const messages = [];
  if (contentType.includes('text/event-stream')) {
    let data = [];
    for (const line of `${body}\n\n`.split(/\r?\n/)) {
      if (line.startsWith('data:')) data.push(line.slice(5).trimStart());
      if (line === '' && data.length) {
        messages.push(JSON.parse(data.join('\n')));
        data = [];
      }
    }
  } else {
    messages.push(JSON.parse(body));
  }
  const matches = messages.filter((message) => message?.id === id);
  if (matches.length !== 1 || matches[0].jsonrpc !== '2.0') {
    throw new Error('MCP response must contain exactly one matching JSON-RPC id');
  }
  const message = matches[0];
  if (message.error) throw new Error(`MCP RPC error ${message.error.code ?? 'unknown'}`);
  if (!Object.hasOwn(message, 'result')) throw new Error('MCP response has no result');
  return message.result;
}

async function bodyText(response) {
  let length = 0;
  const chunks = [];
  for await (const chunk of response.body ?? []) {
    length += chunk.length;
    if (length > MAX_RESPONSE) throw new Error('HTTP response exceeds probe byte bound');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

function ensurePrivateDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077)) {
    throw new Error('Probe state directory must be owned by this user and mode 0700');
  }
}

function writePrivate(filename, value) {
  ensurePrivateDirectory(path.dirname(filename));
  const temp = `${filename}.${crypto.randomUUID()}.tmp`;
  const fd = fs.openSync(temp, 'wx', 0o600);
  try {
    fs.writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  try {
    fs.renameSync(temp, filename);
    const directory = fs.openSync(path.dirname(filename), 'r');
    try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
}

function readPrivate(filename) {
  const stat = fs.lstatSync(filename);
  if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) || stat.size > MAX_RESPONSE) {
    throw new Error('Probe state file must be owned by this user and mode 0600');
  }
  return JSON.parse(fs.readFileSync(filename, 'utf8'));
}

function runtimeState(t3Home) {
  const filename = path.join(t3Home, 'userdata/server-runtime.json');
  const stat = fs.lstatSync(filename);
  if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o022) || stat.size > 65536) {
    throw new Error('T3 runtime state must be a bounded same-user file, not group/world writable');
  }
  const runtime = JSON.parse(fs.readFileSync(filename, 'utf8'));
  const origin = new URL(runtime.origin);
  if (origin.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(origin.hostname)
      || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash
      || Number(origin.port) !== runtime.port || !Number.isSafeInteger(runtime.pid) || runtime.pid <= 1) {
    throw new Error('Probe requires an explicit live loopback T3 runtime');
  }
  process.kill(runtime.pid, 0);
  const owner = fs.statSync(`/proc/${runtime.pid}`);
  if (owner.uid !== process.getuid()) throw new Error('T3 runtime PID belongs to another user');
  return { ...runtime, origin: origin.origin };
}

export class ProbeClient {
  constructor(origin, token) {
    this.origin = origin;
    this.token = token;
    this.session = null;
    this.sequence = 0;
  }

  async request(method, params, notification = false) {
    const id = notification ? undefined : ++this.sequence;
    const response = await fetch(`${this.origin}/mcp`, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000),
      headers: {
        authorization: `Bearer ${this.token}`, 'content-type': 'application/json',
        accept: 'application/json, text/event-stream', 'mcp-protocol-version': PROTOCOL,
        ...(this.session ? { 'mcp-session-id': this.session } : {}),
      },
      body: JSON.stringify({ jsonrpc: '2.0', ...(notification ? {} : { id }), method, params }),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`MCP HTTP ${response.status} during ${method}`);
    }
    const session = response.headers.get('mcp-session-id');
    if (session) this.session = session;
    if (notification) { await response.body?.cancel(); return; }
    return parseRpc(await bodyText(response), response.headers.get('content-type') ?? '', id);
  }

  async initialize() {
    const result = await this.request('initialize', {
      protocolVersion: PROTOCOL, capabilities: {},
      clientInfo: { name: 'c2c-t3-compatibility-probe', version: '1' },
    });
    assert.equal(result.protocolVersion, PROTOCOL, 'MCP protocol version');
    await this.request('notifications/initialized', {}, true);
    return result;
  }

  async call(name, args = {}) {
    const result = await this.request('tools/call', { name, arguments: args });
    const data = result.structuredContent;
    if (result.isError) {
      // Error messages may include a credential or private transcript; report only a code.
      throw new Error(`T3 tool ${name} rejected (${data?.code ?? data?.error?.code ?? 'tool_error'})`);
    }
    if (data !== undefined) return data;
    const content = result.content?.find((item) => item.type === 'text');
    if (!content) throw new Error(`T3 tool ${name} returned no structured result`);
    return JSON.parse(content.text);
  }
}

async function postJson(origin, endpoint, payload) {
  const response = await fetch(`${origin}${endpoint}`, {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000),
    headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`Pairing HTTP ${response.status} at ${endpoint}`);
  }
  return JSON.parse(await bodyText(response));
}

async function pair(options, runtime, authPath) {
  if (fs.existsSync(authPath)) throw new Error('Probe credential exists; reuse it instead of overwriting');
  if (!path.isAbsolute(options['t3-bin'] ?? '')) throw new Error('--t3-bin must be an absolute executable path');
  const output = execFileSync(options['t3-bin'], [
    'auth', 'pairing', 'create', '--base-dir', options['t3-home'],
    '--scope', 'orchestration:read', '--scope', 'orchestration:operate',
    '--ttl', '10m', '--label', 'c2c-t3-compatibility-probe', '--json',
  ], { encoding: 'utf8', timeout: 30_000, maxBuffer: MAX_RESPONSE, stdio: ['ignore', 'pipe', 'pipe'] });
  const credential = JSON.parse(output.slice(output.indexOf('{')));
  const code = credential.credential ?? credential.token ?? credential.code;
  if (typeof code !== 'string' || !code) throw new Error('Pairing CLI returned no code');
  const redirectUri = 'http://127.0.0.1:53999/callback';
  const registration = await postJson(runtime.origin, '/oauth/mcp/register', {
    client_name: 'c2c-t3-compatibility-probe', redirect_uris: [redirectUri],
    grant_types: ['authorization_code'], response_types: ['code'], token_endpoint_auth_method: 'none',
  });
  const verifier = b64url(crypto.randomBytes(32));
  const state = b64url(crypto.randomBytes(24));
  const decision = await postJson(runtime.origin, '/oauth/mcp/decision', {
    authorization: {
      response_type: 'code', client_id: registration.client_id, redirect_uri: redirectUri,
      code_challenge: b64url(crypto.createHash('sha256').update(verifier).digest()),
      code_challenge_method: 'S256', state, resource: `${runtime.origin}/mcp`,
    },
    decision: { _tag: 'pairing-code', access: 'auto', code },
  });
  const callback = new URL(decision.redirectTo);
  if (callback.origin !== new URL(redirectUri).origin || callback.pathname !== '/callback'
      || callback.searchParams.get('state') !== state || callback.searchParams.has('error')) {
    throw new Error('Pairing callback rejected or failed state validation');
  }
  const authorizationCode = callback.searchParams.get('code');
  if (!authorizationCode) throw new Error('Pairing callback has no authorization code');
  const response = await fetch(`${runtime.origin}/oauth/mcp/token`, {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000),
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', code: authorizationCode, redirect_uri: redirectUri,
      client_id: registration.client_id, code_verifier: verifier,
    }),
  });
  if (!response.ok) { await response.body?.cancel(); throw new Error(`Token HTTP ${response.status}`); }
  const token = JSON.parse(await bodyText(response));
  assert.equal(typeof token.access_token, 'string', 'OAuth access token');
  writePrivate(authPath, {
    origin: runtime.origin, t3Home: fs.realpathSync(options['t3-home']),
    token: token.access_token, clientId: registration.client_id,
    scope: token.scope, issuedAt: new Date().toISOString(), expiresIn: token.expires_in,
  });
  return { paired: true, access: 'auto', scope: token.scope, expiresIn: token.expires_in };
}

async function inspect(client, runtime, evidencePath) {
  const initialization = await client.initialize();
  const inventory = await client.request('tools/list', {});
  for (const name of REQUIRED_TOOLS) {
    assert(inventory.tools.some((tool) => tool.name === name), `required tool ${name}`);
  }
  const capabilities = await client.call('orchestrator_capabilities');
  const projects = [];
  let cursor;
  for (let page = 0; page < 100; page++) {
    const result = await client.call('t3_project_list', { limit: 100, ...(cursor === undefined ? {} : { cursor }) });
    for (const project of result.projects) projects.push(project.id);
    if (result.nextCursor === null) break;
    assert(Number.isSafeInteger(result.nextCursor) && result.nextCursor > (cursor ?? -1), 'project cursor advances');
    cursor = result.nextCursor;
    if (page === 99) throw new Error('Project pagination exceeded probe bound');
  }
  const evidence = {
    observedAt: new Date().toISOString(), hostname: os.hostname(), runtime,
    initialization,
    tools: inventory.tools.map((tool) => ({ name: tool.name, inputSchema: tool.inputSchema })),
    providers: capabilities.providers.map((provider) => ({
      providerInstanceId: provider.providerInstanceId, driverKind: provider.driverKind,
      models: provider.models.map((model) => model.id),
    })),
    projectCount: projects.length,
    authorization: { runtimeMode: capabilities.runtimeMode, interactionMode: capabilities.interactionMode },
  };
  writePrivate(evidencePath, evidence);
  return {
    observedAt: evidence.observedAt, hostname: evidence.hostname, version: runtime.serverVersion,
    protocolVersion: initialization.protocolVersion, toolCount: inventory.tools.length,
    projectCount: projects.length, runtimeMode: capabilities.runtimeMode,
    providerDrivers: evidence.providers.map((provider) => provider.driverKind),
    schemaSha256: digest(JSON.stringify(evidence.tools)),
  };
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  const known = new Set(['t3-home', 't3-bin', 'state-dir']);
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index]?.slice(2);
    if (!rest[index]?.startsWith('--') || !known.has(key) || !rest[index + 1] || options[key]) {
      throw new Error('Expected unique --t3-home, --t3-bin and --state-dir options');
    }
    options[key] = rest[index + 1];
  }
  options['t3-home'] ??= path.join(os.homedir(), '.t3');
  if (!['pair', 'inspect'].includes(command) || !path.isAbsolute(options['state-dir'] ?? '')
      || !path.isAbsolute(options['t3-home'])) {
    throw new Error('Usage: t3-connector-probe.mjs pair|inspect --state-dir ABS [--t3-home ABS] [--t3-bin ABS]');
  }
  return { command, options };
}

export async function main(argv = process.argv.slice(2)) {
  const { command, options } = parseArgs(argv);
  ensurePrivateDirectory(options['state-dir']);
  const runtime = runtimeState(options['t3-home']);
  const authPath = path.join(options['state-dir'], 'auth.json');
  if (command === 'pair') return pair(options, runtime, authPath);
  const auth = readPrivate(authPath);
  if (auth.origin !== runtime.origin || auth.t3Home !== fs.realpathSync(options['t3-home'])) {
    throw new Error('Runtime endpoint/home changed; refusing to send the stored credential');
  }
  return inspect(new ProbeClient(runtime.origin, auth.token), runtime,
    path.join(options['state-dir'], 'inspection.json'));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().then((result) => process.stdout.write(`${JSON.stringify(result)}\n`)).catch((error) => {
    // Never print raw fetch/child-process errors, which can carry auth output.
    process.stderr.write(`${error instanceof assert.AssertionError ? 'Compatibility assertion failed' : 'Probe failed'}: ${
      error?.name === 'AbortError' || error?.name === 'TimeoutError' ? 'request timed out' :
      error?.constructor?.name === 'Error' && !error?.stdout && !error?.stderr ? error.message : 'bounded operation failed'
    }\n`);
    process.exitCode = 1;
  });
}
