// Development-only operator for the freshly isolated T3 home. Production c2c
// uses external MCP with read/operate only; this synthetic setup credential is
// needed to exercise actual Stop and create a full-access denial fixture.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { readFixtureState, fixtureStatus } from './t3-connector-fixture.mjs';
import { runtimeState } from './t3-connector-probe.mjs';

const MAX_BYTES = 8 * 1024 * 1024;

async function readJson(response) {
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`Fixture setup HTTP ${response.status}`);
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body ?? []) {
    size += chunk.length;
    if (size > MAX_BYTES) throw new Error('Fixture setup response exceeds bound');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

export class FixtureRpc {
  #pending = new Map();
  #sequence = 0;
  constructor(socket, validate = () => {}) {
    this.socket = socket;
    this.validate = validate;
    socket.binaryType = 'arraybuffer';
    socket.addEventListener('message', (event) => {
      try {
        const text = typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString('utf8');
        if (Buffer.byteLength(text) > MAX_BYTES) throw new Error('Oversized fixture RPC frame');
        const decoded = JSON.parse(text);
        for (const message of Array.isArray(decoded) ? decoded : [decoded]) {
          if (message._tag === 'Pong') continue;
          if (message._tag === 'Defect' || message._tag === 'ClientProtocolError') {
            throw new Error('Fixture RPC protocol failure');
          }
          const pending = this.#pending.get(message.requestId);
          if (!pending) continue;
          if (message._tag !== 'Exit' || !['Success', 'Failure'].includes(message.exit?._tag)) {
            throw new Error('Unexpected fixture unary RPC response');
          }
          this.#pending.delete(message.requestId);
          clearTimeout(pending.timeout);
          if (message.exit._tag === 'Success') pending.resolve(message.exit.value);
          else {
            const detail = JSON.stringify(message.exit?.cause ?? '');
            const label = detail.includes('not interruptible') ? 'Fixture RPC run not interruptible'
              : detail.includes('previously rejected') ? 'Fixture RPC command previously rejected'
              : 'Fixture RPC command rejected';
            pending.reject(new Error(label));
          }
        }
      } catch {
        this.#fail('Fixture RPC protocol failure');
      }
    });
    socket.addEventListener('error', () => this.#fail('Fixture RPC connection failed'));
    socket.addEventListener('close', () => this.#fail('Fixture RPC connection closed'));
  }

  #fail(message) {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error(message));
    }
    this.#pending.clear();
  }

  #request(tag, payload) {
    this.validate();
    if (this.#pending.size) throw new Error('Fixture RPC calls must be serialized');
    const id = `fixture-${++this.#sequence}`;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error('Fixture RPC request timed out'));
        this.socket.close();
      }, 30_000);
      this.#pending.set(id, { resolve, reject, timeout });
      try {
        this.socket.send(JSON.stringify({ _tag: 'Request', id, tag, payload, headers: [] }));
      } catch {
        this.#fail('Fixture RPC submission failed');
      }
    });
  }

  stop({ threadId, runId, commandId }) {
    assert(threadId && runId && commandId, 'persisted interrupt identity');
    // Stock T3 0.1.0 has no thread.stop. run.interrupt is the Stop command and
    // requires the target run; a rejected command id stays rejected forever.
    return this.#request('orchestration.dispatchCommand', {
      type: 'run.interrupt', commandId, threadId, runId,
      reason: 'c2c isolated compatibility fixture',
    });
  }

  resume(threadId, commandId = crypto.randomUUID()) {
    return this.#request('orchestration.dispatchCommand', { type: 'queue.resume', commandId, threadId });
  }

  launchFullAccess({ threadId, projectId, modelSelection, commandId }) {
    assert(threadId && projectId && modelSelection && commandId, 'persisted fixture launch identity');
    return this.#request('orchestration.launchThread', {
      commandId, threadId, projectId, title: 'c2c full-access denial fixture', generateTitle: false,
      modelSelection, runtimeMode: 'full-access', interactionMode: 'default', workspaceStrategy: { type: 'root' },
    });
  }

  lifecycle(threadId, action) {
    assert(['snooze', 'settle', 'archive'].includes(action), 'bounded fixture lifecycle action');
    return this.#request('orchestration.dispatchCommand', {
      type: `thread.${action}`, commandId: crypto.randomUUID(), threadId,
      ...(action === 'snooze' ? { snoozedUntil: new Date(Date.now() + 600_000).toISOString() } : {}),
    });
  }

  close() { this.#fail('Fixture RPC closed'); this.socket.close(); }
}

export async function connectFixtureOperator(root, t3Bin) {
  const state = readFixtureState(root, t3Bin);
  assert.equal(fixtureStatus({ root, t3Bin }).status, 'running', 'owned fixture is running');
  const runtime = runtimeState(state.t3Home);
  assert.equal(runtime.origin, state.runtime.origin, 'owned fixture endpoint');
  const validate = () => assert.deepEqual(runtimeState(state.t3Home).proof, runtime.proof, 'unchanged fixture runtime');
  validate();
  const token = await readJson(await fetch(`${runtime.origin}/oauth/token`, {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000),
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange', subject_token: state.desktopBootstrapToken,
      subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap',
      requested_token_type: 'urn:ietf:params:oauth:token-type:access_token',
    }),
  }));
  assert(typeof token.access_token === 'string' && token.access_token.length > 0, 'synthetic setup token');
  validate();
  const ticket = await readJson(await fetch(`${runtime.origin}/api/auth/websocket-ticket`, {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000),
    headers: { authorization: `Bearer ${token.access_token}`, 'x-t3-orchestration-protocol': '2' },
  }));
  assert(typeof ticket.ticket === 'string' && ticket.ticket.length > 0, 'fixture WebSocket ticket');
  validate();
  const socket = new WebSocket(`${runtime.origin.replace('http:', 'ws:')}/ws?orchestrationProtocol=2&wsTicket=${encodeURIComponent(ticket.ticket)}`);
  const rpc = new FixtureRpc(socket, validate);
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { socket.close(); reject(new Error('Fixture WebSocket upgrade timed out')); }, 30_000);
    const finish = (error) => { clearTimeout(timeout); error ? reject(error) : resolve(); };
    socket.addEventListener('open', () => finish(), { once: true });
    socket.addEventListener('error', () => finish(new Error('Fixture WebSocket upgrade failed')), { once: true });
    socket.addEventListener('close', () => finish(new Error('Fixture WebSocket closed during upgrade')), { once: true });
  });
  return rpc;
}
