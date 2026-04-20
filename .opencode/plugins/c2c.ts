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
 *   C2C_PLUGIN_POLL_INTERVAL_MS — safety-net poll interval in ms (default: 30000; primary wake is c2c monitor)
 *   C2C_PLUGIN_DELIVER_ON_IDLE  — "1" = only deliver on session.idle (default: "0")
 *   C2C_PERMISSION_SUPERVISOR   — alias to DM on permission.ask (default: "coordinator1")
 *   C2C_PERMISSION_TIMEOUT_MS   — ms to await supervisor reply before falling back to dialog (default: 120000)
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
  const pollIntervalMs: number = parseInt(process.env.C2C_PLUGIN_POLL_INTERVAL_MS || "30000", 10);
  const idleOnlyMode: boolean = (process.env.C2C_PLUGIN_DELIVER_ON_IDLE || "0") === "1";
  const permissionSupervisor: string =
    process.env.C2C_PERMISSION_SUPERVISOR || sidecar.permission_supervisor || "coordinator1";
  const permissionTimeoutMs: number = parseInt(
    process.env.C2C_PERMISSION_TIMEOUT_MS || "120000", 10
  );

  // Track the active root session (set from session events)
  let activeSessionId: string | null = configuredOpenCodeSessionId || null;
  let backgroundLoopStarted = false;

  // Dedup window for permission notifications: track last 10 seen permission IDs.
  const seenPermissionIds: string[] = [];
  // Pending async permission approvals (v2): permId → resolve function.
  const pendingPermissions = new Map<string, (reply: string) => void>();

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

  /** Extract a structured permission reply from message content, or null. */
  function extractPermissionReply(content: string): { permId: string; decision: string } | null {
    const m = content.match(/\bpermission:([a-zA-Z0-9_-]+):(approve-once|approve-always|reject)\b/);
    return m ? { permId: m[1], decision: m[2] } : null;
  }

  /** Await a supervisor permission reply; resolves with decision string or "timeout". */
  function waitForPermissionReply(permId: string, timeoutMs: number): Promise<string> {
    return new Promise((resolve) => {
      pendingPermissions.set(permId, resolve);
      setTimeout(() => {
        if (pendingPermissions.has(permId)) {
          pendingPermissions.delete(permId);
          resolve("timeout");
        }
      }, timeoutMs);
    });
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
      // Intercept structured permission replies before normal delivery.
      const permReply = extractPermissionReply(msg.content);
      if (permReply && pendingPermissions.has(permReply.permId)) {
        const resolve = pendingPermissions.get(permReply.permId)!;
        pendingPermissions.delete(permReply.permId);
        resolve(permReply.decision);
        await log(`permission reply from ${msg.from_alias}: ${permReply.permId} → ${permReply.decision}`);
        continue;
      }
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

    // Debounce: skip tryDeliver if a delivery cycle is already in flight.
    let deliveryInFlight = false;
    const tick = async () => {
      if (deliveryInFlight) return;
      deliveryInFlight = true;
      try { await tryDeliver(); } finally { deliveryInFlight = false; }
    };

    // Spawn `c2c monitor` and trigger delivery only on 📬 (inbox-write) events.
    // 💬 (peer DM to others), 📤 (drain), 🗑️ (sweep) are noise — skip them.
    function spawnMonitor(): void {
      const repoCli = path.join(process.cwd(), "c2c");
      const command = process.env.C2C_CLI_COMMAND || (fs.existsSync(repoCli) ? repoCli : "c2c");
      const args = ["monitor"];
      if (sessionId) args.push("--alias", sessionId);
      const proc = spawn(command, args, { cwd: process.cwd(), env: process.env, shell: false });
      let buf = "";
      proc.stdout?.on("data", (chunk: Buffer) => {
        buf += chunk.toString();
        let nl: number;
        while ((nl = buf.indexOf("\n")) !== -1) {
          const line = buf.slice(0, nl).trim();
          buf = buf.slice(nl + 1);
          if (line && line.includes("📬")) tick().catch(() => {});
        }
      });
      proc.on("close", () => { void log("c2c monitor exited, restarting in 5s"); setTimeout(spawnMonitor, 5000); });
      proc.on("error", () => { setTimeout(spawnMonitor, 10_000); });
    }

    spawnMonitor();
    void log(`c2c monitor spawned (alias=${sessionId})`);

    // Safety net: poll once on startup and every pollIntervalMs in case monitor misses events
    setTimeout(tick, 1000);
    setInterval(tick, pollIntervalMs);
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
        // Drain any messages that queued while the session was offline (cold-boot gap).
        await tryDeliver();
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
          // Skip v1 notification if v2 permission.ask hook is awaiting this ID.
          if (pendingPermissions.has(permId)) return;
          seenPermissionIds.push(permId);
          if (seenPermissionIds.length > 10) seenPermissionIds.shift();
        }
        const title: string = perm.title || "unknown";
        const type: string = perm.type || "unknown";
        const pattern: string = JSON.stringify(perm.pattern ?? "N/A");
        const sid: string = perm.sessionID || activeSessionId || sessionId || "unknown";
        const msg = [
          `PERMISSION REQUEST (v1 notification) from ${sessionId}:`,
          `  session: ${sid}`,
          `  title: ${title}`,
          `  type: ${type}`,
          `  pattern: ${pattern}`,
          `  id: ${permId || "unknown"}`,
          `  (v1 fallback — respond via TUI dialog)`,
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

    hooks: {
      "permission.ask": async (input: any, output: { status: "ask" | "deny" | "allow" }) => {
        const permId: string = input.id || "";
        const title: string = input.title || "unknown";
        const type: string = input.type || "unknown";
        const pattern: string = JSON.stringify(input.pattern ?? "N/A");
        const sid: string = input.sessionID || activeSessionId || sessionId || "unknown";
        const timeoutSec = Math.round(permissionTimeoutMs / 1000);
        const msg = [
          `PERMISSION REQUEST (async) from ${sessionId}:`,
          `  session: ${sid}`,
          `  title: ${title}`,
          `  type: ${type}`,
          `  pattern: ${pattern}`,
          `  id: ${permId || "unknown"}`,
          `Reply within ${timeoutSec}s with one of:`,
          `  c2c send ${sessionId} "permission:${permId}:approve-once"`,
          `  c2c send ${sessionId} "permission:${permId}:approve-always"`,
          `  c2c send ${sessionId} "permission:${permId}:reject"`,
          `(timeout → falls back to TUI dialog)`,
        ].join("\n");
        try {
          await runC2c(["send", permissionSupervisor, msg]);
          await log(`permission.ask sent to ${permissionSupervisor}: ${permId}`);
          void toast(`c2c: awaiting permission approval from ${permissionSupervisor}…`);
        } catch (err) {
          await log(`permission.ask notify error: ${err}`);
          return; // notify failed — fall through to dialog
        }
        if (!permId) return; // no ID to track, fall through to dialog
        const reply = await waitForPermissionReply(permId, permissionTimeoutMs);
        if (reply === "approve-once" || reply === "approve-always") {
          output.status = "allow";
          await log(`permission approved by ${permissionSupervisor}: ${permId} (${reply})`);
          void toast(`c2c: permission approved (${reply})`);
        } else if (reply === "reject") {
          output.status = "deny";
          await log(`permission rejected by ${permissionSupervisor}: ${permId}`);
          void toast(`c2c: permission rejected`, "warning");
        } else {
          // timeout — leave output.status as "ask" (default) to show TUI dialog
          await log(`permission timeout (${timeoutSec}s): ${permId} — showing dialog`);
          void toast(`c2c: permission timeout — showing dialog`, "warning");
        }
      },
    },
  };
};

export default C2CDelivery;
