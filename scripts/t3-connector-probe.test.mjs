import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { assertScopes, assertToken, isExclusiveUserGroup, parseRpc, ProbeClient, runtimeState, withStateLock, writePrivate } from './t3-connector-probe.mjs';

test('MCP decoder selects the exact response, including SSE notifications', () => {
  const body = [
    ': keepalive', '',
    'data: {"jsonrpc":"2.0","method":"notifications/message","params":{}}', '',
    'event: message', 'data: {"jsonrpc":"2.0",', 'data: "id":7,"result":{"ok":true}}', '', '',
  ].join('\r\n');
  assert.deepEqual(parseRpc(body, 'text/event-stream', 7), { ok: true });
  assert.deepEqual(parseRpc('{"jsonrpc":"2.0","id":7,"result":null}', 'application/json', 7), null);
});

test('MCP decoder refuses mismatched/duplicate ids and malformed RPC envelopes', () => {
  for (const value of [
    '{"jsonrpc":"2.0","id":8,"result":{}}',
    '{"jsonrpc":"1.0","id":7,"result":{}}',
    '{"jsonrpc":"2.0","id":7}',
    '{"jsonrpc":"2.0","id":7,"error":null,"result":{}}',
  ]) assert.throws(() => parseRpc(value, 'application/json', 7));
  const duplicate = Array(2).fill('data: {"jsonrpc":"2.0","id":7,"result":{}}\n\n').join('');
  assert.throws(() => parseRpc(duplicate, 'text/event-stream', 7));
  assert.throws(() => parseRpc('data: invalid\n\n', 'text/event-stream', 7));
  assert.throws(() => parseRpc('data: {"jsonrpc":"2.0","id":7,"result":{}}\n', 'text/event-stream', 7));
  assert.throws(() => parseRpc('{"jsonrpc":"2.0","id":7,"result":{}}', 'text/plain', 7));
  assert.throws(() => parseRpc('{"jsonrpc":"2.0","id":7,"error":{"code":-1,"message":"private"}}',
    'application/json', 7), { message: 'MCP RPC error -1' });
});

test('pairing scope and token validation reject broader or missing authority', () => {
  const scope = 'orchestration:read orchestration:operate';
  assertToken({ token_type: 'Bearer', access_token: 'fixture', scope });
  for (const scopes of [undefined, '', 'orchestration:read', `${scope} settings:write`,
    `${scope} orchestration:read`]) assert.throws(() => assertScopes(scopes));
  assert.throws(() => assertToken({ token_type: 'Other', access_token: 'fixture', scope }));
  assert.throws(() => assertToken({ token_type: 'Bearer', access_token: '', scope }));
});

test('runtime group writes are allowed only for the verified user-private primary group', () => {
  const user = { username: 'operator', uid: 1000, gid: 1000 };
  const operator = 'operator:x:1000:1000:Operator:/home/operator:/bin/bash';
  assert.equal(isExclusiveUserGroup('operator:x:1000:', operator, user), true);
  assert.equal(isExclusiveUserGroup('operator:x:1000:operator', operator, user), true);
  assert.equal(isExclusiveUserGroup('operator:x:1000:other', operator, user), false);
  assert.equal(isExclusiveUserGroup('shared:x:1000:', operator, user), false);
  assert.equal(isExclusiveUserGroup('operator:x:1000:', `${operator}\nother:x:1001:1000::/:/bin/sh`, user), false);
  assert.equal(isExclusiveUserGroup('operator:x:1000:', '', user), false);
});

test('credential publication never replaces an existing credential', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'c2c-probe-private-'));
  t.after(() => fs.rmSync(directory, { recursive: true }));
  const filename = path.join(directory, 'auth.json');
  const results = await Promise.allSettled([1, 2].map(async (value) => writePrivate(filename, { value }, false)));
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
  assert.deepEqual(JSON.parse(fs.readFileSync(filename, 'utf8')), { value: 1 });
  assert.equal(fs.statSync(filename).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(directory), ['auth.json']);
});

test('fixture lock rejects a concurrent launch and releases after completion', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'c2c-probe-lock-'));
  t.after(() => fs.rmSync(directory, { recursive: true }));
  const filename = path.join(directory, 'fixture.lock');
  let release;
  let launches = 0;
  const first = withStateLock(filename, async () => {
    launches++;
    await new Promise((resolve) => { release = resolve; });
  });
  await assert.rejects(withStateLock(filename, () => { launches++; }), { code: 'EEXIST' });
  assert.equal(launches, 1);
  release();
  await first;
  await withStateLock(filename, () => { launches++; });
  assert.equal(launches, 2);
  assert.equal(fs.existsSync(filename), false);
});

test('runtime validation checks PID incarnation and listener ownership', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'c2c-probe-runtime-'));
  t.after(() => fs.rmSync(directory, { recursive: true }));
  fs.mkdirSync(path.join(directory, 'userdata'), { mode: 0o700 });
  const origin = await fixture(t, (_request, response) => response.end());
  const runtime = { pid: process.pid, origin, port: Number(new URL(origin).port), startedAt: new Date().toISOString() };
  const filename = path.join(directory, 'userdata/server-runtime.json');
  fs.writeFileSync(filename, JSON.stringify(runtime), { mode: 0o600 });
  const proof = runtimeState(directory).proof;
  assert.equal(proof.pid, process.pid);
  assert(proof.listeners.length > 0);
  fs.writeFileSync(filename, JSON.stringify({ ...runtime, startedAt: '2000-01-01T00:00:00.000Z' }));
  assert.throws(() => runtimeState(directory), /incarnation/);
  fs.writeFileSync(filename, JSON.stringify({ ...runtime, port: 1, origin: 'http://127.0.0.1:1' }));
  assert.throws(() => runtimeState(directory), /listening socket/);
  fs.writeFileSync(filename, JSON.stringify({ ...runtime, origin: `http://[::1]:${runtime.port}` }));
  assert.throws(() => runtimeState(directory), /listening socket/, 'IPv4 does not attest an IPv6 endpoint');
  const ipv6Server = http.createServer((_request, response) => response.end());
  await new Promise((resolve, reject) => {
    ipv6Server.once('error', reject);
    ipv6Server.listen({ port: 0, host: '::1', ipv6Only: true }, resolve);
  });
  t.after(() => new Promise((resolve) => ipv6Server.close(resolve)));
  const port = ipv6Server.address().port;
  fs.writeFileSync(filename, JSON.stringify({ ...runtime, port, origin: `http://[::1]:${port}` }));
  assert(runtimeState(directory).proof.listeners.length > 0);
  fs.writeFileSync(filename, JSON.stringify({ ...runtime, port, origin: `http://127.0.0.1:${port}` }));
  assert.throws(() => runtimeState(directory), /listening socket/, 'IPv6 does not attest an IPv4 endpoint');
});

async function fixture(t, handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  }));
  return `http://127.0.0.1:${server.address().port}`;
}

test('client initializes, preserves MCP session, and reads structured tools serially', async (t) => {
  const seen = [];
  const origin = await fixture(t, async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    const message = JSON.parse(body);
    seen.push(message.method);
    assert.equal(request.headers.authorization, 'Bearer fixture-token');
    assert.equal(request.headers['mcp-protocol-version'], '2025-06-18');
    if (message.method !== 'initialize') assert.equal(request.headers['mcp-session-id'], 'fixture-session');
    if (message.method === 'notifications/initialized') { response.writeHead(202).end(); return; }
    const result = message.method === 'initialize'
      ? { protocolVersion: '2025-06-18', capabilities: {} }
      : { structuredContent: { threadId: 'fixture' } };
    response.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': 'fixture-session' });
    response.end(JSON.stringify({ jsonrpc: '2.0', id: message.id, result }));
  });
  const client = new ProbeClient(origin, 'fixture-token');
  await client.initialize();
  assert.deepEqual(await client.call('t3_thread_read', { threadId: 'fixture' }), { threadId: 'fixture' });
  assert.deepEqual(seen, ['initialize', 'notifications/initialized', 'tools/call']);
});

test('client refuses redirects and redacts HTTP/tool failures', async (t) => {
  let count = 0;
  const origin = await fixture(t, async (request, response) => {
    if (count++ === 0) {
      response.writeHead(401).end('private failure body');
      return;
    }
    let body = '';
    for await (const chunk of request) body += chunk;
    const message = JSON.parse(body);
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ jsonrpc: '2.0', id: message.id, result: {
      isError: true, structuredContent: { code: 'capability_denied' },
      content: [{ type: 'text', text: 'private transcript' }],
    } }));
  });
  const client = new ProbeClient(origin, 'fixture-token');
  await assert.rejects(client.call('t3_thread_read'), { message: 'MCP HTTP 401 during tools/call' });
  await assert.rejects(client.call('t3_thread_read'), {
    message: 'T3 tool t3_thread_read rejected (capability_denied)',
  });
  let targetRequests = 0;
  const target = await fixture(t, (_request, response) => { targetRequests++; response.end(); });
  const redirect = await fixture(t, (_request, response) => {
    response.writeHead(307, { location: target }).end();
  });
  await assert.rejects(new ProbeClient(redirect, 'fixture-token').request('initialize', {}));
  assert.equal(targetRequests, 0, 'authenticated requests must not follow redirects');
});
