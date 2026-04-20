/**
 * c2c OpenCode Plugin — automatic broker message delivery.
 *
 * Watches the local c2c broker inbox and delivers inbound messages to the
 * active OpenCode session via client.session.promptAsync so they appear as
 * proper user turns (not pasted into the prompt buffer via PTY).
 *
 * Config (all optional, with sensible defaults):
 *   C2C_MCP_SESSION_ID      — broker session ID to poll (required for delivery)
 *   C2C_MCP_BROKER_ROOT     — broker root dir (default: auto-detect)
 *   C2C_PLUGIN_POLL_INTERVAL_MS — poll interval in ms (default: 2000)
 *   C2C_PLUGIN_DELIVER_ON_IDLE  — "1" = only deliver on session.idle (default: "0")
 *   C2C_PERMISSION_SUPERVISOR   — alias to DM on permission.updated (default: "coordinator1")
 *
 * Delivery strategy:
 *   - Primary: poll on session.idle events (agent is between tool calls)
 *   - Secondary: background interval poll so messages arrive even between idles
 *
 * The c2c CLI is used to drain inbox atomically (respects POSIX lockf).
 *
 * Installation: place in .opencode/plugins/c2c.ts (project-level) or
 *   ~/.config/opencode/plugins/c2c.ts (global).
 * Also run: c2c setup opencode  (writes env vars needed by the broker MCP tool)
 */

import type { Plugin } from "@opencode-ai/plugin";
import type { Event, EventSessionIdle, EventSessionCreated } from "@opencode-ai/sdk";
import { spawn } from "child_process";
import * as fs from "fs";
import * as path from "path";

// ---------------------------------------------------------------------------
// Sidecar config loader
// ---------------------------------------------------------------------------

/** Read .opencode/c2c-plugin.json relative to the CWD, returning {} on miss. */
function loadSidecarConfig(): Record<string, string> {
  try {
    const sidecar = path.join(process.cwd(), ".opencode", "c2c-plugin.json");
    const raw = fs.readFileSync(sidecar, "utf-8");
    return JSON.parse(raw) as Record<string, string>;
  } catch {
    return {};
  }
}

// ---------------------------------------------------------------------------
// Plugin definition
// ---------------------------------------------------------------------------

const C2CDelivery: Plugin = async (ctx) => {
  // --- Config (env vars > sidecar .opencode/c2c-plugin.json) ---
  const sidecar = loadSidecarConfig();
  const sessionId: string =
    process.env.C2C_MCP_SESSION_ID || process.env.C2C_SESSION_ID || sidecar.session_id || "";
  const brokerRoot: string = process.env.C2C_MCP_BROKER_ROOT || sidecar.broker_root || "";
  const configuredOpenCodeSessionId: string =
    process.env.C2C_OPENCODE_SESSION_ID || sidecar.opencode_session_id || "";
  const pollIntervalMs: number = parseInt(process.env.C2C_PLUGIN_POLL_INTERVAL_MS || "2000", 10);
  const idleOnlyMode: boolean = (process.env.C2C_PLUGIN_DELIVER_ON_IDLE || "0") === "1";
  const permissionSupervisor: string =
    process.env.C2C_PERMISSION_SUPERVISOR || sidecar.permission_supervisor || "coordinator1";

  // Track the active root session (set from session events)
  let activeSessionId: string | null = configuredOpenCodeSessionId || null;
  let backgroundLoopStarted = false;

  // Dedup window for permission notifications: track last 10 seen permission IDs.
  const seenPermissionIds: string[] = [];

  // --- Helpers ---

  async function log(msg: string): Promise<void> {
    try {
      await ctx.client.app.log({
        body: { service: "c2c", level: "debug", message: `c2c: ${msg}` },
        url: "/log",
      } as any);
    } catch {
      // logging failure is non-fatal
    }
  }

  async function toast(msg: string, variant: "info" | "warning" | "error" = "info"): Promise<void> {
    try {
      await ctx.client.tui.showToast({
        url: "/tui/show-toast",
        body: { title: "c2c", message: msg, variant, duration: 3000 },
      } as any);
    } catch {
      // toast failure is non-fatal
    }
  }

  async function runC2c(args: string[]): Promise<string> {
    const repoCli = path.join(process.cwd(), "c2c");
    const command = process.env.C2C_CLI_COMMAND || (fs.existsSync(repoCli) ? repoCli : "c2c");
    const timeoutMs = parseInt(process.env.C2C_PLUGIN_CLI_TIMEOUT_MS || "5000", 10);

    return new Promise((resolve, reject) => {
      let stdout = "";
      let stderr = "";
      let timedOut = false;
      let settled = false;
      const proc = spawn(command, args, {
        cwd: process.cwd(),
        env: process.env,
        shell: false,
      });
      const timer = setTimeout(() => {
        timedOut = true;
        proc.kill("SIGTERM");
      }, timeoutMs);

      proc.stdout?.on("data", (chunk) => {
        stdout += chunk.toString();
      });
      proc.stderr?.on("data", (chunk) => {
        stderr += chunk.toString();
      });
      proc.on("error", (err) => {
        clearTimeout(timer);
        if (settled) return;
        settled = true;
        reject(err);
      });
      proc.on("close", (code) => {
        clearTimeout(timer);
        if (settled) return;
        settled = true;
        if (code === 0) {
          resolve(stdout);
          return;
        }
        const detail = stderr.trim() || `exit code ${code}`;
        reject(new Error(timedOut ? `c2c poll timed out after ${timeoutMs}ms` : detail));
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Spool file — survives promptAsync failures so messages are not lost
  // ---------------------------------------------------------------------------

  type Msg = { from_alias: string; to_alias: string; content: string };
  const spoolPath = path.join(process.cwd(), ".opencode", "c2c-plugin-spool.json");

  function readSpool(): Msg[] {
    try {
      const raw = fs.readFileSync(spoolPath, "utf-8").trim();
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  function writeSpool(msgs: Msg[]): void {
    try {
      if (msgs.length === 0) {
        fs.unlinkSync(spoolPath);
      } else {
        fs.writeFileSync(spoolPath, JSON.stringify(msgs), "utf-8");
      }
    } catch {
      // Spool write failure is non-fatal — best-effort persistence.
    }
  }

  /** Extract Msg[] from the poll-inbox --json envelope (or bare array). */
  function parsePollResult(stdout: string): Msg[] {
    if (!stdout) return [];
    const parsed = JSON.parse(stdout);
    // poll-inbox --json emits {"session_id":...,"messages":[...]} - unwrap it.
    // Bare arrays are accepted too for forward-compat.
    const msgs: unknown = Array.isArray(parsed) ? parsed : (parsed as any).messages ?? [];
    return Array.isArray(msgs) ? (msgs as Msg[]) : [];
  }

  /** Drain inbox using the c2c CLI and return parsed messages. */
  async function drainInbox(): Promise<Msg[]> {
    if (!sessionId) return [];
    try {
      const args: string[] = ["poll-inbox", "--json", "--file-fallback"];
      if (sessionId) args.push("--session-id", sessionId);
      if (brokerRoot) args.push("--broker-root", brokerRoot);
      const stdout = (await runC2c(args)).trim();
      return parsePollResult(stdout);
    } catch (err) {
      await log(`drainInbox error: ${err}`);
      return [];
    }
  }

  /** Format a single broker message as a c2c envelope for injection. */
  function formatEnvelope(msg: Msg): string {
    const from = msg.from_alias || "unknown";
    const to = msg.to_alias || sessionId;
    return `<c2c event="message" from="${from}" alias="${to}" source="broker" action_after="continue">\n${msg.content}\n</c2c>`;
  }

  /** Deliver drained messages to the active session via promptAsync. */
  async function deliverMessages(targetSessionId: string): Promise<void> {
    // Drain spool first (messages from failed previous delivery cycle).
    const spooled = readSpool();
    const fresh = await drainInbox();
    const messages = [...spooled, ...fresh];
    if (messages.length === 0) return;

    // Persist combined set before delivery so nothing is lost on failure.
    writeSpool(messages);

    await log(`delivering ${messages.length} message(s) to session ${targetSessionId}${spooled.length ? ` (${spooled.length} from spool)` : ""}`);

    const failed: Msg[] = [];
    for (const msg of messages) {
      const envelope = formatEnvelope(msg);
      try {
        await ctx.client.session.promptAsync({
          path: { id: targetSessionId },
          body: { parts: [{ type: "text", text: envelope }] },
          url: "/session/{id}/prompt_async",
        } as any);
        await log(`delivered from ${msg.from_alias}`);
      } catch (err) {
        await log(`promptAsync error: ${err}`);
        // Keep in spool — will be retried on next delivery cycle.
        failed.push(msg);
        await toast(`c2c: delivery error from ${msg.from_alias}`, "error");
      }
    }
    // Update spool: clear if all delivered, write failures if any.
    writeSpool(failed);
  }

  /** Try to deliver to the best-known session ID. */
  async function tryDeliver(): Promise<void> {
    const sid = activeSessionId;
    if (!sid) {
      // No session yet — try to discover the current session from the API
      try {
        const sessions = await ctx.client.session.list();
        if (sessions?.data?.length) {
          const root = sessions.data.find((s: any) => !s.parentID) || sessions.data[0];
          if (root?.id) {
            activeSessionId = root.id;
            await deliverMessages(root.id);
          }
        }
      } catch {
        // Not available yet
      }
      return;
    }
    await deliverMessages(sid);
  }

  function startBackgroundLoop(): void {
    if (backgroundLoopStarted || idleOnlyMode) return;
    backgroundLoopStarted = true;
    const tick = async () => {
      await tryDeliver();
    };

    // Use fs.watch on the broker directory for cross-platform file change detection.
    // Watch the directory (not the file) because atomic writes (temp + os.replace)
    // change the inode — fs.watch on a replaced file path can miss events.
    if (brokerRoot) {
      try {
        const inboxName = `${sessionId}.inbox.json`;
        fs.watch(brokerRoot, { persistent: false }, (_eventType, filename) => {
          if (filename === inboxName) {
            tick().catch(() => {});
          }
        });
        void log(`watching ${brokerRoot} for ${inboxName} changes`);
      } catch (err) {
        void log(`fs.watch failed (${err}), falling back to poll every ${pollIntervalMs}ms`);
        setInterval(tick, pollIntervalMs);
      }
    } else {
      // No broker root — fall back to polling
      setInterval(tick, pollIntervalMs);
    }

    // Safety net: poll once on startup and every 30s in case fs.watch misses events
    setTimeout(tick, 1000);
    setInterval(tick, 30_000);
  }

  // --- Guard: no delivery without session ID ---
  if (!sessionId) {
    return {
      lifecycle: {
        start: async () => {
          await log("C2C_MCP_SESSION_ID not set — message delivery disabled");
          await toast("c2c plugin: set C2C_MCP_SESSION_ID to enable delivery", "warning");
        },
      },
    };
  }

  await log(`plugin loaded (session=${sessionId}, interval=${pollIntervalMs}ms, idleOnly=${idleOnlyMode})`);
  startBackgroundLoop();

  // --- Return hooks ---
  return {
    lifecycle: {
      start: async () => {
        await log("starting delivery loop");
        await toast(`c2c: delivery active (session=${sessionId})`);
        startBackgroundLoop();
      },
    },

    event: async ({ event }: { event: Event }) => {
      // Track root session ID from creation events
      if (event.type === "session.created") {
        const e = event as EventSessionCreated;
        const info = (e as any).properties?.info;
        if (info?.id && !info?.parentID) {
          if (configuredOpenCodeSessionId && info.id !== configuredOpenCodeSessionId) return;
          activeSessionId = info.id;
          await log(`tracking root session: ${info.id}`);
        }
        return;
      }

      // Notify supervisor on permission.updated (v1: notification-only, no dialog mutation)
      if (event.type === "permission.updated") {
        const perm = (event as any).properties?.permission ?? (event as any).properties ?? {};
        const permId: string = perm.id || "";
        if (permId) {
          if (seenPermissionIds.includes(permId)) return;
          seenPermissionIds.push(permId);
          if (seenPermissionIds.length > 10) seenPermissionIds.shift();
        }
        const title: string = perm.title || "unknown";
        const type: string = perm.type || "unknown";
        const pattern: string = JSON.stringify(perm.pattern ?? "N/A");
        const sid: string = perm.sessionID || activeSessionId || sessionId || "unknown";
        const msg = [
          `PERMISSION REQUEST (notification) from ${sessionId}:`,
          `  session: ${sid}`,
          `  title: ${title}`,
          `  type: ${type}`,
          `  pattern: ${pattern}`,
          `  id: ${permId || "unknown"}`,
          `  (v1 — respond via TUI dialog)`,
        ].join("\n");
        try {
          await runC2c(["send", permissionSupervisor, msg]);
          await log(`permission notification sent to ${permissionSupervisor}: ${permId}`);
          void toast(`c2c: permission notified → ${permissionSupervisor}`);
        } catch (err) {
          await log(`permission notification error: ${err}`);
        }
        return;
      }

      // Deliver on session.idle — agent has just finished a turn and is ready
      if (event.type === "session.idle") {
        const e = event as EventSessionIdle;
        const idleSessionId: string = (e as any).properties?.sessionID || activeSessionId || "";
        if (!idleSessionId) return;
        if (configuredOpenCodeSessionId && idleSessionId !== configuredOpenCodeSessionId) return;
        // Only deliver for the root session (avoid interfering with sub-agents)
        if (activeSessionId && idleSessionId !== activeSessionId) return;
        activeSessionId = idleSessionId;
        await deliverMessages(idleSessionId);
      }
    },
  };
};

export default C2CDelivery;
