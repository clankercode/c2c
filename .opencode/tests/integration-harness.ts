/**
 * c2c OpenCode Plugin integration harness.
 *
 * Runs the real plugin against a mock HTTP server (URL in
 * C2C_TEST_MOCK_SERVER_URL). Used by the Python integration test and by
 * operators who want to observe delivery in a tmux pane.
 *
 * Protocol on stdout (line-delimited):
 *   READY              plugin loaded; waiting for messages
 *   DELIVERED: <json>  a delivery call was made (payload = JSON of call body)
 *   DONE               shutting down cleanly
 *
 * Environment inputs:
 *   C2C_MCP_SESSION_ID        broker session to poll (plugin-level)
 *   C2C_MCP_BROKER_ROOT       broker dir (plugin-level)
 *   C2C_TEST_MOCK_SERVER_URL  base URL for the mock OpenCode API
 *   C2C_TEST_HARNESS_TIMEOUT  max runtime in seconds (default 60)
 *   C2C_TEST_TARGET_SESSION   fake opencode session id to target (default "harness-root")
 */

import C2CDelivery from '../plugins/c2c.ts';

const mockUrl = process.env.C2C_TEST_MOCK_SERVER_URL || '';
const targetSession = process.env.C2C_TEST_TARGET_SESSION || 'harness-root';
const timeoutSec = parseInt(process.env.C2C_TEST_HARNESS_TIMEOUT || '60', 10);

function line(msg: string): void {
  process.stdout.write(msg + '\n');
}

async function postJson(path: string, body: unknown): Promise<unknown> {
  if (!mockUrl) return {};
  const res = await fetch(mockUrl + path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  try {
    return await res.json();
  } catch {
    return {};
  }
}

const mockCtx = {
  client: {
    session: {
      promptAsync: async (call: any) => {
        line('DELIVERED: ' + JSON.stringify(call));
        await postJson('/session/prompt_async', call);
        return {};
      },
      list: async () => ({
        data: [{ id: targetSession, parentID: undefined }],
      }),
    },
    app: {
      log: async (call: any) => {
        // Emit logs to stderr so they don't pollute the stdout protocol.
        process.stderr.write('LOG: ' + JSON.stringify(call.body) + '\n');
        return {};
      },
    },
    tui: {
      showToast: async (call: any) => {
        process.stderr.write('TOAST: ' + JSON.stringify(call.body) + '\n');
        return {};
      },
    },
    postSessionIdPermissionsPermissionId: async (call: any) => {
      line('PERMISSION_RESOLVED: ' + JSON.stringify(call));
      await postJson('/session/permission_respond', call);
      return {};
    },
  },
};

async function main(): Promise<void> {
  const hooks = await C2CDelivery(mockCtx as any);
  // Announce that we have an active root session so subsequent fs.watch
  // ticks know where to deliver.
  if (hooks.event) {
    await hooks.event({
      event: {
        type: 'session.created',
        properties: { info: { id: targetSession } },
      } as any,
    });
  }
  line('READY');

  const shutdown = () => {
    line('DONE');
    process.exit(0);
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
  setTimeout(shutdown, timeoutSec * 1000);

  // Keep the event loop alive.
  await new Promise(() => {});
}

main().catch((err) => {
  process.stderr.write('HARNESS ERROR: ' + String(err) + '\n');
  process.exit(1);
});
