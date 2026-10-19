import assert from 'node:assert/strict';
import test from 'node:test';
import { FixtureRpc } from './t3-fixture-operator.mjs';

class SyntheticSocket extends EventTarget {
  sent = [];
  send(text) { this.sent.push(JSON.parse(text)); }
  receive(value) { this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(value) })); }
  close() { this.dispatchEvent(new Event('close')); }
}

test('fixture operator uses Effect RPC framing and matches Exit requestId', async () => {
  const socket = new SyntheticSocket();
  const rpc = new FixtureRpc(socket);
  const result = rpc.stop('own-fixture', 'stable-command');
  const request = socket.sent[0];
  assert.deepEqual(request, {
    _tag: 'Request', id: 'fixture-1', tag: 'orchestration.dispatchCommand',
    payload: { type: 'thread.stop', commandId: 'stable-command', threadId: 'own-fixture', reason: 'c2c isolated compatibility fixture' },
    headers: [],
  });
  assert.throws(() => rpc.resume('own-fixture'), /serialized/);
  socket.receive({ _tag: 'Pong' });
  socket.receive({ _tag: 'Exit', requestId: request.id, exit: { _tag: 'Success', value: { sequence: 9 } } });
  assert.deepEqual(await result, { sequence: 9 });
  rpc.close();
});

test('fixture operator rejects typed failure, protocol defects and connection loss', async () => {
  for (const reply of [
    { _tag: 'Exit', requestId: 'fixture-1', exit: { _tag: 'Failure', cause: [{ _tag: 'Fail', error: { message: 'private' } }] } },
    { _tag: 'Defect', defect: 'private' },
  ]) {
    const socket = new SyntheticSocket();
    const rpc = new FixtureRpc(socket);
    const request = rpc.resume('own-fixture');
    socket.receive(reply);
    await assert.rejects(request, /Fixture RPC (command rejected|protocol failure)/);
    rpc.close();
  }
  const socket = new SyntheticSocket();
  const rpc = new FixtureRpc(socket);
  const request = rpc.stop('own-fixture');
  socket.close();
  await assert.rejects(request, /connection closed/);
});

test('full-access setup requires explicit persisted command and thread identity', async () => {
  const socket = new SyntheticSocket();
  const rpc = new FixtureRpc(socket);
  assert.throws(() => rpc.launchFullAccess({ threadId: 'x' }));
  const request = rpc.launchFullAccess({ threadId: 'own-fixture', projectId: 'own-project',
    modelSelection: { instanceId: 'codex', model: 'c2c-fixture' }, commandId: 'stable-command' });
  assert.equal(socket.sent[0].tag, 'orchestration.launchThread');
  assert.equal(socket.sent[0].payload.runtimeMode, 'full-access');
  assert.equal(socket.sent[0].payload.initialMessage, undefined);
  socket.receive([{ _tag: 'Exit', requestId: 'fixture-1', exit: { _tag: 'Success', value: { threadId: 'own-fixture' } } }]);
  assert.equal((await request).threadId, 'own-fixture');
  rpc.close();
});
