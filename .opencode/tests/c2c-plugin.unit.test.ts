/**
 * Unit tests for the c2c OpenCode plugin.
 *
 * The plugin imports `child_process` and `fs` at the top level, so we mock
 * those modules before importing the plugin. Tests drive delivery through
 * synthetic session events rather than timers.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { EventEmitter } from 'events';

// ---------------------------------------------------------------------------
// Module mocks (hoisted by vi.mock)
// ---------------------------------------------------------------------------

type FakeProc = EventEmitter & {
  stdout: EventEmitter;
  stderr: EventEmitter;
  stdin: { end: ReturnType<typeof vi.fn>; write: ReturnType<typeof vi.fn> };
  kill: (sig?: string) => void;
};

const spawnQueue: Array<{ stdout: string; stderr: string; code: number }> = [];
const spawnCalls: Array<{ command: string; args: string[] }> = [];
const stateWriterLines: string[] = [];

function createFakeProc(out: { stdout: string; stderr: string; code: number }): FakeProc {
  const proc = new EventEmitter() as FakeProc;
  proc.stdout = new EventEmitter();
  proc.stderr = new EventEmitter();
  proc.stdin = {
    end: vi.fn((chunk?: string) => {
      if (typeof chunk === 'string') stateWriterLines.push(chunk);
      return true;
    }),
    write: vi.fn((chunk: string) => {
      stateWriterLines.push(chunk);
      return true;
    }),
  };
  proc.kill = vi.fn();
  setImmediate(() => {
    if (out.stdout) proc.stdout.emit('data', Buffer.from(out.stdout));
    if (out.stderr) proc.stderr.emit('data', Buffer.from(out.stderr));
    proc.emit('close', out.code);
  });
  return proc;
}

function createPersistentProc(): FakeProc {
  const proc = new EventEmitter() as FakeProc;
  proc.stdout = new EventEmitter();
  proc.stderr = new EventEmitter();
  proc.stdin = {
    end: vi.fn((chunk?: string) => {
      if (typeof chunk === 'string') stateWriterLines.push(chunk);
      return true;
    }),
    write: vi.fn((chunk: string) => {
      stateWriterLines.push(chunk);
      return true;
    }),
  };
  proc.kill = vi.fn();
  return proc;
}

vi.mock('child_process', () => ({
  spawn: vi.fn((command: string, args: string[]) => {
    spawnCalls.push({ command, args });
    if (args[0] === 'oc-plugin' && args[1] === 'stream-write-statefile') {
      return createPersistentProc();
    }
    const next = spawnQueue.shift() ?? { stdout: '{"messages":[]}', stderr: '', code: 0 };
    return createFakeProc(next);
  }),
}));

const fakeSpoolState: { data: string | null } = { data: null };

vi.mock('fs', async (importOriginal) => {
  const orig = await importOriginal<typeof import('fs')>();
  return {
    ...orig,
    default: orig,
    watch: vi.fn(() => ({ close: vi.fn() })),
    readFileSync: vi.fn((p: any, enc?: any) => {
      const ps = String(p);
      if (ps.endsWith('c2c-plugin-spool.json')) {
        if (fakeSpoolState.data === null) throw new Error('ENOENT');
        return fakeSpoolState.data;
      }
      if (ps.endsWith('c2c-plugin.json')) {
        throw new Error('ENOENT');
      }
      return orig.readFileSync(p, enc);
    }),
    writeFileSync: vi.fn((p: any, content: any) => {
      const ps = String(p);
      if (ps.endsWith('c2c-plugin-spool.json')) {
        fakeSpoolState.data = String(content);
      }
    }),
    unlinkSync: vi.fn((p: any) => {
      const ps = String(p);
      if (ps.endsWith('c2c-plugin-spool.json')) {
        fakeSpoolState.data = null;
      }
    }),
    existsSync: vi.fn(() => false),
  };
});

// Import AFTER mocks are registered.
import C2CDelivery, { summarizePermission } from '../plugins/c2c';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

function makeCtx() {
  return {
    client: {
      session: {
        promptAsync: vi.fn().mockResolvedValue({}),
        list: vi.fn().mockResolvedValue({ data: [] }),
      },
      app: { log: vi.fn().mockResolvedValue({}) },
      tui: { showToast: vi.fn().mockResolvedValue({}) },
      postSessionIdPermissionsPermissionId: vi.fn().mockResolvedValue({}),
      question: {
        reply: vi.fn().mockResolvedValue({}),
        reject: vi.fn().mockResolvedValue({}),
      },
    },
  };
}

function queueSpawn(payload: { messages: Array<{ from_alias: string; to_alias: string; content: string }> }): void {
  spawnQueue.push({ stdout: JSON.stringify(payload), stderr: '', code: 0 });
}

async function fireEvent(hooks: any, event: any): Promise<void> {
  if (hooks.event) await hooks.event({ event });
}

function sessionCreated(id: string, parentID?: string) {
  return {
    type: 'session.created',
    properties: { info: { id, parentID } },
  };
}

function sessionIdle(sessionID: string) {
  return {
    type: 'session.idle',
    properties: { sessionID },
  };
}

function stateEvents() {
  return stateWriterLines.map((line) => JSON.parse(line.trim()));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('c2c plugin unit tests', () => {
  beforeEach(() => {
    // Only fake setTimeout/setInterval/setImmediate-on-timers. Keep real
    // setImmediate and microtasks so the mocked spawn can flush its close
    // events via the event loop.
    vi.useFakeTimers({ toFake: ['setTimeout', 'setInterval'] });
    spawnQueue.length = 0;
    spawnCalls.length = 0;
    stateWriterLines.length = 0;
    fakeSpoolState.data = null;
    process.env.C2C_MCP_SESSION_ID = 'test-session';
    process.env.C2C_MCP_BROKER_ROOT = '/tmp/broker';
    process.env.C2C_PERMISSION_SUPERVISOR = 'coordinator1';
    // Idle-only mode: suppress the background monitor/poll loop so that
    // spawnMonitor() does not consume spawn queue entries before drainInbox()
    // can use them. These unit tests drive delivery via event callbacks.
    process.env.C2C_PLUGIN_DELIVER_ON_IDLE = '1';
    // Skip cold-boot delay so session.created tests complete without timeout
    process.env.C2C_PLUGIN_COLD_BOOT_DELAY_MS = '0';
    // Isolate from shell environment: clear any C2C_KICKOFF_PROMPT_PATH and
    // C2C_AUTO_KICKOFF that would cause the plugin to read the host instance's
    // kickoff file instead of treating the test as kickoff-incapable.
    delete process.env.C2C_KICKOFF_PROMPT_PATH;
    delete process.env.C2C_AUTO_KICKOFF;
    delete process.env.C2C_OPENCODE_SESSION_ID;
  });

  afterEach(() => {
    vi.useRealTimers();
    delete process.env.C2C_MCP_SESSION_ID;
    delete process.env.C2C_MCP_BROKER_ROOT;
    delete process.env.C2C_PERMISSION_SUPERVISOR;
    delete process.env.C2C_PLUGIN_DELIVER_ON_IDLE;
    delete process.env.C2C_PLUGIN_COLD_BOOT_DELAY_MS;
  });

  it('formats message as correct c2c envelope', async () => {
    queueSpawn({
      messages: [{ from_alias: 'alice', to_alias: 'bob', content: 'hello world' }],
    });
    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));
    await fireEvent(hooks, sessionIdle('root-session'));

    expect(ctx.client.session.promptAsync).toHaveBeenCalledTimes(1);
    const call = ctx.client.session.promptAsync.mock.calls[0]![0];
    expect(call.path.id).toBe('root-session');
    const text = call.body.parts[0].text;
    expect(text).toContain('<c2c event="message"');
    expect(text).toContain('from="alice"');
    expect(text).toContain('alias="bob"');
    expect(text).toContain('hello world');
    expect(text).toContain('</c2c>');
  });

  it('emits a startup state.snapshot and uses persistent writer command', async () => {
    const ctx = makeCtx();
    await C2CDelivery(ctx as any);

    const streamSpawn = spawnCalls.find((c) =>
      c.args[0] === 'oc-plugin' && c.args[1] === 'stream-write-statefile'
    );
    expect(streamSpawn).toBeDefined();

    const events = stateEvents();
    expect(events).toHaveLength(1);
    expect(events[0].event).toBe('state.snapshot');
    expect(events[0].state.c2c_session_id).toBe('test-session');
    expect(events[0].state.opencode_pid).toBeTypeOf('number');
    expect(events[0].state.c2c_alias).toBeNull();
    expect(events[0].state.agent.turn_count).toBe(0);
    expect(events[0].state.agent.step_count).toBe(0);
    expect(events[0].state.agent.last_step).toBeNull();
    expect(events[0].state.prompt.has_text).toBeNull();
  });

  it('emits state.patch for root session.created and session.idle', async () => {
    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);

    await fireEvent(hooks, sessionCreated('root-session'));
    await fireEvent(hooks, sessionIdle('root-session'));

    const events = stateEvents();
    expect(events.map((e) => e.event)).toEqual([
      'state.snapshot',
      'state.patch',
      'state.patch',
    ]);
    expect(events[1].patch.root_opencode_session_id).toBe('root-session');
    expect(events[1].patch.agent.step_count).toBe(1);
    expect(events[1].patch.agent.last_step.event_type).toBe('session.created');
    expect(events[2].patch.agent.is_idle).toBe(true);
    expect(events[2].patch.agent.turn_count).toBe(1);
    expect(events[2].patch.agent.step_count).toBe(2);
    expect(events[2].patch.tui_focus.ty).toBe('prompt');
  });

  it('bootstraps root state from first session.idle when session.created was missed', async () => {
    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);

    await fireEvent(hooks, sessionIdle('late-root'));

    const events = stateEvents();
    expect(events).toHaveLength(2);
    expect(events[1].event).toBe('state.patch');
    expect(events[1].patch.root_opencode_session_id).toBe('late-root');
    expect(events[1].patch.agent.turn_count).toBe(1);
    expect(events[1].patch.agent.step_count).toBe(1);
    expect(events[1].patch.agent.last_step.details.session_id).toBe('late-root');
  });

  it('bootstraps root session from HTTP session.list on plugin start (resume scenario)', async () => {
    const ctx = makeCtx();
    (ctx.client.session.list as any).mockResolvedValue({
      data: [{ id: 'ses-resumed', time: { updated: 1000, created: 900 } }],
    });
    await C2CDelivery(ctx as any);
    // pump microtasks so void bootstrapRootSession() resolves
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    const events = stateEvents();
    expect(events.length).toBeGreaterThanOrEqual(2);
    const patch = events.find((e) => e.event === 'state.patch');
    expect(patch).toBeDefined();
    expect(patch!.patch.root_opencode_session_id).toBe('ses-resumed');
  });

  it('does not let non-root permission events mutate published root state', async () => {
    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);

    await fireEvent(hooks, sessionCreated('root-session'));
    const beforeCount = stateEvents().length;
    await fireEvent(hooks, {
      type: 'permission.asked',
      properties: {
        id: 'perm-sub',
        sessionID: 'sub-session',
        title: 'bash',
        type: 'bash',
        pattern: 'echo hi',
      },
    });
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    expect(stateEvents()).toHaveLength(beforeCount);
  });

  it('emits permission focus patch for root permission event', async () => {
    spawnQueue.push({ stdout: '', stderr: '', code: 0 });

    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));
    await fireEvent(hooks, {
      type: 'permission.asked',
      properties: {
        id: 'perm-root',
        sessionID: 'root-session',
        title: 'bash',
        type: 'bash',
        pattern: 'echo hi',
      },
    });
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    const events = stateEvents();
    const permissionPatch = events.at(-1)!;
    expect(permissionPatch.event).toBe('state.patch');
    expect(permissionPatch.patch.agent.is_idle).toBe(false);
    expect(permissionPatch.patch.tui_focus.ty).toBe('permission');
    expect(permissionPatch.patch.tui_focus.details).toEqual({
      id: 'perm-root',
      title: 'bash',
      type: 'bash',
    });
  });

  it('spools messages on promptAsync failure then retries on next delivery', async () => {
    queueSpawn({
      messages: [{ from_alias: 'alice', to_alias: 'bob', content: 'msg1' }],
    });
    const ctx = makeCtx();
    ctx.client.session.promptAsync.mockRejectedValueOnce(new Error('transient'));

    const hooks = await C2CDelivery(ctx as any);
    // Fire session.idle directly — idle handler sets activeSessionId on first fire
    // so session.created is not required. Avoids double-delivery (session.created
    // also calls deliverMessages, which would consume the spooled message before we
    // can assert on intermediate spool state).
    await fireEvent(hooks, sessionIdle('root'));

    // First delivery failed — message should be spooled.
    expect(fakeSpoolState.data).not.toBeNull();
    const spooled = JSON.parse(fakeSpoolState.data!);
    expect(spooled).toHaveLength(1);
    expect(spooled[0].content).toBe('msg1');

    // Queue empty inbox for the retry round; spool should supply the message.
    queueSpawn({ messages: [] });
    await fireEvent(hooks, sessionIdle('root'));

    expect(ctx.client.session.promptAsync).toHaveBeenCalledTimes(2);
    // After successful retry, spool should be empty.
    expect(fakeSpoolState.data).toBeNull();
  });

  it('does not call promptAsync when inbox is empty', async () => {
    queueSpawn({ messages: [] });
    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root'));
    await fireEvent(hooks, sessionIdle('root'));
    expect(ctx.client.session.promptAsync).not.toHaveBeenCalled();
  });

  it('tracks root session from session.created event', async () => {
    queueSpawn({
      messages: [{ from_alias: 'alice', to_alias: 'bob', content: 'hi' }],
    });
    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('the-root'));
    await fireEvent(hooks, sessionIdle('the-root'));

    expect(ctx.client.session.promptAsync).toHaveBeenCalledTimes(1);
    expect(ctx.client.session.promptAsync.mock.calls[0]![0].path.id).toBe('the-root');
  });

  it('skips sub-sessions (parentID set) as root', async () => {
    queueSpawn({
      messages: [{ from_alias: 'alice', to_alias: 'bob', content: 'hi' }],
    });
    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);
    // Sub-session should NOT be tracked as root.
    await fireEvent(hooks, sessionCreated('sub-session', 'root'));
    // An idle for the sub-session while no root is tracked will attempt
    // to deliver to the sub (since activeSessionId is still null, idle
    // uses the idle session id). Then sessionCreated for a real root
    // is tracked, and its idle should deliver to THAT root.
    await fireEvent(hooks, sessionCreated('real-root'));
    // Drain the queue by having the promptAsync mock return success —
    // we just verify tracking worked.
    await fireEvent(hooks, sessionIdle('real-root'));
    expect(ctx.client.session.promptAsync).toHaveBeenCalled();
    const lastCall = ctx.client.session.promptAsync.mock.calls.at(-1)!;
    expect(lastCall[0].path.id).toBe('real-root');
  });

  it('permission.asked event: DMs supervisor, resolves via HTTP on approve-once', async () => {
    // sessionCreated cold-boot drain
    queueSpawn({ messages: [] });
    // supervisor liveness query (selectSupervisors first-alive strategy)
    spawnQueue.push({
      stdout: JSON.stringify({ sessions: [{ alias: 'coordinator1', alive: true, last_seen: Date.now() / 1000 }] }),
      stderr: '', code: 0,
    });
    // send DM to supervisor
    spawnQueue.push({ stdout: '', stderr: '', code: 0 });
    // sessionIdle drain returns the supervisor's permission reply
    queueSpawn({
      messages: [{ from_alias: 'coordinator1', to_alias: 'oc-coder1', content: 'permission:perm-xyz:approve-once' }],
    });

    const ctx = makeCtx();
    process.env.C2C_PERMISSION_TIMEOUT_MS = '10000';
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));

    await fireEvent(hooks, {
      type: 'permission.asked',
      properties: {
        id: 'perm-xyz',
        sessionID: 'root-session',
        title: 'bash',
        type: 'bash',
        pattern: 'echo hi',
      },
    });

    // Pump microtasks so the fire-and-forget async runs through selectSupervisors + send DM.
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    // Supervisor reply lands on the next session.idle drain.
    await fireEvent(hooks, sessionIdle('root-session'));
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    expect(ctx.client.postSessionIdPermissionsPermissionId).toHaveBeenCalledTimes(1);
    const call = ctx.client.postSessionIdPermissionsPermissionId.mock.calls[0]![0];
    expect(call.path.id).toBe('root-session');
    expect(call.path.permissionID).toBe('perm-xyz');
    expect(call.body.response).toBe('once');

    // DM to supervisor includes the permission ID.
    const sendCall = spawnCalls.find((c) => c.args[0] === 'send');
    expect(sendCall).toBeDefined();
    expect(sendCall!.args[1]).toBe('coordinator1');
    expect(sendCall!.args[2]).toContain('perm-xyz');

    delete process.env.C2C_PERMISSION_TIMEOUT_MS;
  });

  it('permission.asked: on timeout, auto-rejects via HTTP and DMs supervisor', async () => {
    // sessionCreated cold-boot drain
    queueSpawn({ messages: [] });
    // DM to supervisor on ask
    spawnQueue.push({ stdout: '', stderr: '', code: 0 });
    // DM to supervisor on timeout notification
    spawnQueue.push({ stdout: '', stderr: '', code: 0 });

    const ctx = makeCtx();
    process.env.C2C_PERMISSION_TIMEOUT_MS = '200';
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));

    await fireEvent(hooks, {
      type: 'permission.asked',
      properties: { id: 'perm-timeout', sessionID: 'root-session', title: 'bash', type: 'bash', pattern: 'echo hi' },
    });

    // Let the fire-and-forget async get past selectSupervisors + DM send,
    // then advance timers past the timeout window.
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));
    await vi.advanceTimersByTimeAsync(250);
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    expect(ctx.client.postSessionIdPermissionsPermissionId).toHaveBeenCalledTimes(1);
    const call = ctx.client.postSessionIdPermissionsPermissionId.mock.calls[0]![0];
    expect(call.path.permissionID).toBe('perm-timeout');
    expect(call.body.response).toBe('reject');

    // There should be TWO sends to coordinator1: the initial ask, then the timeout notice.
    const sends = spawnCalls.filter((c) => c.args[0] === 'send' && c.args[1] === 'coordinator1');
    expect(sends.length).toBeGreaterThanOrEqual(2);
    expect(sends.at(-1)!.args[2]).toContain('timed out');
    expect(sends.at(-1)!.args[2]).toContain('auto-rejected');

    delete process.env.C2C_PERMISSION_TIMEOUT_MS;
  });

  it('permission.asked: late reply after timeout is NACK\'d back to sender', async () => {
    queueSpawn({ messages: [] }); // sessionCreated cold-boot
    spawnQueue.push({ // liveness
      stdout: JSON.stringify({ sessions: [{ alias: 'coordinator1', alive: true, last_seen: Date.now() / 1000 }] }),
      stderr: '', code: 0,
    });
    spawnQueue.push({ stdout: '', stderr: '', code: 0 }); // initial DM
    spawnQueue.push({ stdout: '', stderr: '', code: 0 }); // timeout DM
    // sessionIdle drain delivers a late reply
    queueSpawn({
      messages: [{ from_alias: 'coordinator1', to_alias: 'oc-coder1', content: 'permission:perm-late:approve-once' }],
    });
    spawnQueue.push({ stdout: '', stderr: '', code: 0 }); // NACK send

    const ctx = makeCtx();
    process.env.C2C_PERMISSION_TIMEOUT_MS = '200';
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));

    await fireEvent(hooks, {
      type: 'permission.asked',
      properties: { id: 'perm-late', sessionID: 'root-session', title: 'bash', type: 'bash', pattern: 'echo hi' },
    });
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));
    await vi.advanceTimersByTimeAsync(250);
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    // Now the supervisor's (too-late) reply arrives on the next idle drain.
    await fireEvent(hooks, sessionIdle('root-session'));
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    // NACK message back to coordinator1 announcing the reply arrived late.
    const nackSend = spawnCalls.find((c) =>
      c.args[0] === 'send' && c.args[1] === 'coordinator1' &&
      typeof c.args[2] === 'string' && c.args[2].includes('arrived') && c.args[2].includes('after the timeout')
    );
    expect(nackSend).toBeDefined();
    expect(nackSend!.args[2]).toContain('perm-late');

    // The late reply MUST NOT trigger a second HTTP resolve call.
    expect(ctx.client.postSessionIdPermissionsPermissionId).toHaveBeenCalledTimes(1);

    delete process.env.C2C_PERMISSION_TIMEOUT_MS;
  });

  it('question.asked: DMs supervisor and forwards answer via HTTP', async () => {
    // cold-boot drain
    queueSpawn({ messages: [] });
    // supervisor liveness query
    spawnQueue.push({
      stdout: JSON.stringify({ sessions: [{ alias: 'coordinator1', alive: true, last_seen: Date.now() / 1000 }] }),
      stderr: '', code: 0,
    });
    // send DM to supervisor
    spawnQueue.push({ stdout: '', stderr: '', code: 0 });
    // session.idle drain returns the supervisor's question answer
    queueSpawn({
      messages: [{ from_alias: 'coordinator1', to_alias: 'test-session', content: 'question:q-abc:answer:yes please' }],
    });

    const ctx = makeCtx();
    process.env.C2C_PERMISSION_TIMEOUT_MS = '10000';
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));

    await fireEvent(hooks, {
      type: 'question.asked',
      properties: {
        id: 'q-abc',
        sessionID: 'root-session',
        questions: [{ question: 'Proceed?', header: 'Confirm', options: [{ value: 'yes please' }, { value: 'no' }] }],
      },
    });

    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    // Supervisor reply arrives on next idle drain.
    await fireEvent(hooks, sessionIdle('root-session'));
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    // HTTP question.reply must have been called with the answer.
    expect(ctx.client.question.reply).toHaveBeenCalledTimes(1);
    const replyCall = ctx.client.question.reply.mock.calls[0]![0];
    expect(replyCall.path.id).toBe('q-abc');
    expect(replyCall.body.answers[0][0]).toBe('yes please');
    expect(ctx.client.question.reject).not.toHaveBeenCalled();

    // DM to supervisor mentions the question id.
    const sendCall = spawnCalls.find((c) => c.args[0] === 'send');
    expect(sendCall).toBeDefined();
    expect(sendCall!.args[2]).toContain('q-abc');
    expect(sendCall!.args[2]).toContain('Confirm');

    delete process.env.C2C_PERMISSION_TIMEOUT_MS;
  });

  it('question.asked: snapshots pendingQuestion when opened and clears it after reply', async () => {
    queueSpawn({ messages: [] });
    spawnQueue.push({
      stdout: JSON.stringify({ sessions: [{ alias: 'coordinator1', alive: true, last_seen: Date.now() / 1000 }] }),
      stderr: '', code: 0,
    });
    spawnQueue.push({ stdout: '', stderr: '', code: 0 });
    queueSpawn({
      messages: [{ from_alias: 'coordinator1', to_alias: 'test-session', content: 'question:q-state:answer:yes please' }],
    });

    const ctx = makeCtx();
    process.env.C2C_PERMISSION_TIMEOUT_MS = '10000';
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));

    await fireEvent(hooks, {
      type: 'question.asked',
      properties: {
        id: 'q-state',
        sessionID: 'root-session',
        questions: [{ question: 'Proceed?', header: 'Confirm', options: [{ value: 'yes please' }, { value: 'no' }] }],
      },
    });
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    const openedSnapshot = stateEvents().find((e) =>
      e.event === 'state.snapshot' && e.state?.pendingQuestion?.id === 'q-state'
    );
    expect(openedSnapshot).toBeDefined();
    expect(openedSnapshot!.state.pendingQuestion).toEqual({
      id: 'q-state',
      text: 'Proceed?',
      header: 'Confirm',
      options: ['yes please', 'no'],
    });

    await fireEvent(hooks, sessionIdle('root-session'));
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    const snapshots = stateEvents().filter((e) => e.event === 'state.snapshot');
    expect(snapshots.at(-1)!.state.pendingQuestion).toBeNull();

    delete process.env.C2C_PERMISSION_TIMEOUT_MS;
  });

  it('question.asked: auto-rejects via HTTP on timeout', async () => {
    queueSpawn({ messages: [] }); // cold-boot
    spawnQueue.push({ // liveness query
      stdout: JSON.stringify({ sessions: [{ alias: 'coordinator1', alive: true, last_seen: Date.now() / 1000 }] }),
      stderr: '', code: 0,
    });
    spawnQueue.push({ stdout: '', stderr: '', code: 0 }); // DM send

    const ctx = makeCtx();
    process.env.C2C_PERMISSION_TIMEOUT_MS = '100'; // short timeout for test
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));

    await fireEvent(hooks, {
      type: 'question.asked',
      properties: {
        id: 'q-timeout',
        sessionID: 'root-session',
        questions: [{ question: 'Do it?', header: 'Confirm', options: [] }],
      },
    });

    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));
    // Advance fake timers past the 100ms question timeout.
    vi.advanceTimersByTime(500);
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    expect(ctx.client.question.reject).toHaveBeenCalledTimes(1);
    const rejectCall = ctx.client.question.reject.mock.calls[0]![0];
    expect(rejectCall.path.id).toBe('q-timeout');

    delete process.env.C2C_PERMISSION_TIMEOUT_MS;
  });

  it('question.asked: deduplicates repeated event for same id', async () => {
    queueSpawn({ messages: [] }); // cold-boot
    spawnQueue.push({ // liveness query (only once — dedup prevents second DM)
      stdout: JSON.stringify({ sessions: [{ alias: 'coordinator1', alive: true, last_seen: Date.now() / 1000 }] }),
      stderr: '', code: 0,
    });
    spawnQueue.push({ stdout: '', stderr: '', code: 0 }); // DM send (only once)

    const ctx = makeCtx();
    process.env.C2C_PERMISSION_TIMEOUT_MS = '10000';
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));

    const evt = {
      type: 'question.asked',
      properties: { id: 'q-dedup', sessionID: 'root-session', questions: [] },
    };
    await fireEvent(hooks, evt);
    await fireEvent(hooks, evt); // duplicate
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    // Only one DM send spawned, not two.
    const sendCalls = spawnCalls.filter((c) => c.args[0] === 'send');
    expect(sendCalls.length).toBe(1);

    delete process.env.C2C_PERMISSION_TIMEOUT_MS;
  });

  it('question.asked: sets pendingQuestion in state snapshot', async () => {
    queueSpawn({ messages: [] }); // cold-boot
    spawnQueue.push({ // liveness query
      stdout: JSON.stringify({ sessions: [{ alias: 'coordinator1', alive: true, last_seen: Date.now() / 1000 }] }),
      stderr: '', code: 0,
    });
    spawnQueue.push({ stdout: '', stderr: '', code: 0 }); // DM send

    const ctx = makeCtx();
    process.env.C2C_PERMISSION_TIMEOUT_MS = '10000';
    const hooks = await C2CDelivery(ctx as any);
    await fireEvent(hooks, sessionCreated('root-session'));

    const snapshotsBefore = stateEvents().filter((e: any) => e.event === 'state.snapshot').length;

    await fireEvent(hooks, {
      type: 'question.asked',
      properties: {
        id: 'q-pq-test',
        sessionID: 'root-session',
        questions: [{ question: 'Allow this?', header: 'Permission', options: [{ value: 'yes' }] }],
      },
    });
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    const allSnapshots = stateEvents().filter((e: any) => e.event === 'state.snapshot');
    const newSnapshots = allSnapshots.slice(snapshotsBefore);
    expect(newSnapshots.length).toBeGreaterThan(0);
    const pq = newSnapshots[newSnapshots.length - 1].state?.pendingQuestion;
    expect(pq).toBeTruthy();
    expect(pq?.id).toBe('q-pq-test');
    expect(pq?.text).toBe('Allow this?');
    expect(pq?.header).toBe('Permission');

    delete process.env.C2C_PERMISSION_TIMEOUT_MS;
  });

  // ---------------------------------------------------------------------------
  // bootstrapRootSession cross-contamination regression (#58 reopen)
  // Two concurrent --auto instances must NOT steal each other's session.
  // ---------------------------------------------------------------------------

  it('#58 cross-contamination: C2C_AUTO_KICKOFF=1 skips bootstrap even when session.list returns sessions', async () => {
    process.env.C2C_AUTO_KICKOFF = '1';
    const ctx = makeCtx();
    (ctx.client.session.list as any).mockResolvedValue({
      data: [{ id: 'ses-other-instance', time: { updated: 9999, created: 8000 } }],
    });
    await C2CDelivery(ctx as any);
    // pump microtasks so void bootstrapRootSession() fully resolves
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    // No root should have been adopted — the session belongs to a sibling instance
    const events = stateEvents();
    const rootPatch = events.find(
      (e) => e.event === 'state.patch' && e.patch?.root_opencode_session_id,
    );
    expect(rootPatch).toBeUndefined();
    delete process.env.C2C_AUTO_KICKOFF;
  });

  it('#58 cross-contamination: exact configuredOpenCodeSessionId required — no fallback to roots[0]', async () => {
    process.env.C2C_OPENCODE_SESSION_ID = 'ses-mine';
    const ctx = makeCtx();
    // session.list returns two sessions, neither matches 'ses-mine'
    (ctx.client.session.list as any).mockResolvedValue({
      data: [
        { id: 'ses-theirs-1', time: { updated: 9999, created: 8000 } },
        { id: 'ses-theirs-2', time: { updated: 8000, created: 7000 } },
      ],
    });
    await C2CDelivery(ctx as any);
    for (let i = 0; i < 40; i++) await new Promise((r) => setImmediate(r));

    const events = stateEvents();
    const rootPatch = events.find(
      (e) => e.event === 'state.patch' && e.patch?.root_opencode_session_id,
    );
    expect(rootPatch).toBeUndefined();
    delete process.env.C2C_OPENCODE_SESSION_ID;
  });

  it('disables delivery when C2C_MCP_SESSION_ID not set', async () => {
    delete process.env.C2C_MCP_SESSION_ID;
    const ctx = makeCtx();
    const hooks = await C2CDelivery(ctx as any);
    // Guard mode returns lifecycle.start but no event handler.
    expect(hooks.event).toBeUndefined();
    // Calling start logs and toasts but never calls promptAsync.
    if (hooks.lifecycle?.start) {
      await hooks.lifecycle.start({} as any);
    }
    expect(ctx.client.session.promptAsync).not.toHaveBeenCalled();
    expect(ctx.client.tui.showToast).toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// summarizePermission — pure function tests (no plugin context needed)
// ---------------------------------------------------------------------------

describe('summarizePermission', () => {
  it('formats bash permission with pattern', () => {
    expect(summarizePermission({ type: 'bash', pattern: 'git push origin master' }))
      .toBe('bash: `git push origin master`');
  });

  it('prefers metadata.command over pattern', () => {
    expect(summarizePermission({
      type: 'bash',
      pattern: 'echo hi',
      metadata: { command: 'git push origin master' },
    })).toBe('bash: `git push origin master`');
  });

  it('falls back to metadata.input when command absent', () => {
    expect(summarizePermission({
      type: 'bash',
      metadata: { input: 'npm run build' },
    })).toBe('bash: `npm run build`');
  });

  it('formats file permission with pattern', () => {
    expect(summarizePermission({ type: 'file', pattern: '/etc/passwd' }))
      .toBe('file: /etc/passwd');
  });

  it('formats fs (alias) permission', () => {
    expect(summarizePermission({ type: 'fs', pattern: '/home/user/.ssh/id_rsa' }))
      .toBe('file: /home/user/.ssh/id_rsa');
  });

  it('formats network permission', () => {
    expect(summarizePermission({ type: 'network', pattern: 'api.example.com' }))
      .toBe('network: api.example.com');
  });

  it('handles pattern as string array', () => {
    expect(summarizePermission({ type: 'bash', pattern: ['git', 'push'] }))
      .toBe('bash: `git push`');
  });

  it('uses title when pattern is absent and title is not "unknown"', () => {
    expect(summarizePermission({ type: 'bash', title: 'deploy script' }))
      .toBe('bash: `deploy script`');
  });

  it('ignores title "unknown" and returns fallback', () => {
    expect(summarizePermission({ type: 'bash', title: 'unknown' }))
      .toBe('bash: (unknown command)');
  });

  it('handles completely empty permission object', () => {
    expect(summarizePermission({})).toBe('unknown');
  });

  it('handles unknown type with action', () => {
    expect(summarizePermission({ type: 'write', pattern: '/tmp/file.txt' }))
      .toBe('write: /tmp/file.txt');
  });

  it('handles unknown type with no action', () => {
    expect(summarizePermission({ type: 'write' })).toBe('write');
  });
});
