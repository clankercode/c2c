import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';
import { parseRpc, ProbeClient } from './t3-connector-probe.mjs';

test('MCP decoder selects the exact response, including SSE notifications', () => {
  const body = [
    ': keepalive', '',
    'data: {"jsonrpc":"2.0","method":"notifications/message","params":{}}', '',
    'event: message', 'data: {"jsonrpc":"2.0",', 'data: "id":7,"result":{"ok":true}}', '',
  ].join('\r\n');
  assert.deepEqual(parseRpc(body, 'text/event-stream', 7), { ok: true });
  assert.deepEqual(parseRpc('{"jsonrpc":"2.0","id":7,"result":null}', 'application/json', 7), null);
});

test('MCP decoder refuses mismatched/duplicate ids and malformed RPC envelopes', () => {
  for (const value of [
    '{"jsonrpc":"2.0","id":8,"result":{}}',
    '{"jsonrpc":"1.0","id":7,"result":{}}',
    '{"jsonrpc":"2.0","id":7}',
  ]) assert.throws(() => parseRpc(value, 'application/json', 7));
  const duplicate = Array(2).fill('data: {"jsonrpc":"2.0","id":7,"result":{}}\n\n').join('');
  assert.throws(() => parseRpc(duplicate, 'text/event-stream', 7));
  assert.throws(() => parseRpc('data: invalid\n\n', 'text/event-stream', 7));
  assert.throws(() => parseRpc('{"jsonrpc":"2.0","id":7,"error":{"code":-1,"message":"private"}}',
    'application/json', 7), { message: 'MCP RPC error -1' });
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
