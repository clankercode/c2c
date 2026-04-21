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
  kill: (sig?: string) => void;
};

const spawnQueue: Array<{ stdout: string; stderr: string; code: number }> = [];
const spawnCalls: Array<{ command: string; args: string[] }> = [];

function createFakeProc(out: { stdout: string; stderr: string; code: number }): FakeProc {
  const proc = new EventEmitter() as FakeProc;
  proc.stdout = new EventEmitter();
  proc.stderr = new EventEmitter();
  proc.kill = vi.fn();
  setImmediate(() => {
    if (out.stdout) proc.stdout.emit('data', Buffer.from(out.stdout));
    if (out.stderr) proc.stderr.emit('data', Buffer.from(out.stderr));
    proc.emit('close', out.code);
  });
  return proc;
}

vi.mock('child_process', () => ({
  spawn: vi.fn((command: string, args: string[]) => {
    spawnCalls.push({ command, args });
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
import C2CDelivery from '../plugins/c2c';

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
    fakeSpoolState.data = null;
    process.env.C2C_MCP_SESSION_ID = 'test-session';
    process.env.C2C_MCP_BROKER_ROOT = '/tmp/broker';
    // Idle-only mode: suppress the background monitor/poll loop so that
    // spawnMonitor() does not consume spawn queue entries before drainInbox()
    // can use them. These unit tests drive delivery via event callbacks.
    process.env.C2C_PLUGIN_DELIVER_ON_IDLE = '1';
    // Skip cold-boot delay so session.created tests complete without timeout
    process.env.C2C_PLUGIN_COLD_BOOT_DELAY_MS = '0';
  });

  afterEach(() => {
    vi.useRealTimers();
    delete process.env.C2C_MCP_SESSION_ID;
    delete process.env.C2C_MCP_BROKER_ROOT;
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
