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
 *   C2C_PERMISSION_TIMEOUT_MS   — ms to await supervisor reply before auto-rejecting (default: 600000 = 10 min). On timeout the plugin auto-rejects via HTTP (fail-closed) and will notify any late-arriving reply that the request has already been rejected.
 *
 * Delivery strategy:
 *   - Primary: poll on session.idle events (agent is between tool calls)
 *   - Secondary: background interval poll so messages arrive even between idles
 *
 * The c2c CLI is used to drain inbox atomically (respects POSIX lockf).
 *
 * Installation: place in .opencode/plugins/c2c.ts (project-level) or
 *   ~/.config/opencode/plugins/c2c.ts (global).
 * Also run: c2c install opencode  (writes env vars needed by the broker MCP tool)
 */

import type { Plugin } from "@opencode-ai/plugin";
import type { Event, EventSessionIdle, EventSessionCreated } from "@opencode-ai/sdk";
import { spawn } from "child_process";
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

// ---------------------------------------------------------------------------
// Sidecar config loader
// ---------------------------------------------------------------------------

/** Read .opencode/c2c-plugin.json relative to the CWD, returning {} on miss. */
function loadSidecarConfig(): Record<string, unknown> {
  try {
    const sidecar = path.join(process.cwd(), ".opencode", "c2c-plugin.json");
    const raw = fs.readFileSync(sidecar, "utf-8");
    return JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return {};
  }
}

/** Read .c2c/repo.json relative to the CWD, returning {} on miss. */
function loadRepoConfig(): Record<string, unknown> {
  try {
    const repo = path.join(process.cwd(), ".c2c", "repo.json");
    const raw = fs.readFileSync(repo, "utf-8");
    return JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return {};
  }
}

/** Resolve supervisor aliases from env > sidecar > repo.json > default. */
function resolvePermissionSupervisors(sidecar: Record<string, unknown>): string[] {
  // C2C_PERMISSION_SUPERVISOR: single alias override (highest priority)
  const envSingle = process.env.C2C_PERMISSION_SUPERVISOR;
  if (envSingle) return [envSingle];
  // C2C_SUPERVISORS: comma-separated list override
  const envList = process.env.C2C_SUPERVISORS;
  if (envList) return envList.split(",").map((s) => s.trim()).filter(Boolean);
  // Sidecar: supervisors array (c2c init --supervisor writes here)
  const sidecarSups = sidecar.supervisors;
  if (Array.isArray(sidecarSups) && sidecarSups.length > 0) {
    const names = sidecarSups.filter((s): s is string => typeof s === "string");
    if (names.length > 0) return names;
  }
  // Repo config: supervisors array (c2c repo set supervisor writes here)
  const repo = loadRepoConfig();
  const repoSups = repo.supervisors ?? repo.permission_supervisors;
  if (Array.isArray(repoSups) && repoSups.length > 0) {
    const names = repoSups.filter((s): s is string => typeof s === "string");
    if (names.length > 0) return names;
  }
  // Sidecar: permission_supervisor (legacy single value)
  const sidecarLegacy = sidecar.permission_supervisor;
  if (typeof sidecarLegacy === "string" && sidecarLegacy) return [sidecarLegacy];
  // Default
  return ["coordinator1"];
}

// ---------------------------------------------------------------------------
// Permission summary (module-level for testability)
// ---------------------------------------------------------------------------

/**
 * Produce a human-readable one-line summary of a permission request so
 * supervisors can make an informed approve/reject decision.
 *
 * Priority for the action value:
 *   metadata.command > metadata.input > metadata.cmd > pattern (joined) > title > type
 */
export function summarizePermission(perm: Record<string, unknown>): string {
  const type = typeof perm.type === "string" && perm.type ? perm.type : "unknown";
  const title = typeof perm.title === "string" ? perm.title : "";
  const meta = (typeof perm.metadata === "object" && perm.metadata !== null)
    ? (perm.metadata as Record<string, unknown>)
    : {};

  const rawPattern = perm.pattern;
  const patternStr: string = Array.isArray(rawPattern)
    ? rawPattern.join(" ")
    : typeof rawPattern === "string" ? rawPattern : "";

  const metaAction: string = [meta.command, meta.input, meta.cmd]
    .filter((v): v is string => typeof v === "string" && v.length > 0)[0] ?? "";

  const action = metaAction || patternStr || (title && title !== "unknown" ? title : "") || "";

  switch (type) {
    case "bash":
      return action ? `bash: \`${action}\`` : "bash: (unknown command)";
    case "file":
    case "fs":
      return action ? `file: ${action}` : "file access (unknown path)";
    case "network":
      return action ? `network: ${action}` : "network access (unknown target)";
    default:
      return action ? `${type}: ${action}` : type;
  }
}

// ---------------------------------------------------------------------------
// Plugin definition
// ---------------------------------------------------------------------------

const C2CDelivery: Plugin = async (ctx) => {
  // If running as the global plugin and a project-level plugin exists in the
  // current directory, defer to it — avoids double-loading when both are active.
  const projectPluginPath = path.join(process.cwd(), ".opencode", "plugins", "c2c.ts");
  const thisPluginPath = new URL(import.meta.url).pathname;
  const isGlobalPlugin = thisPluginPath.includes("/.config/opencode/plugins/");
  if (isGlobalPlugin && fs.existsSync(projectPluginPath)) {
    return {}; // project-level plugin will handle delivery
  }

  // Boot banner — log pid + sha256 prefix of this file so stale bun compile
  // cache issues are instantly visible: if sha doesn't match `sha256sum c2c.ts`
  // the running code is NOT the file on disk.
  //
  // Also rotates the log if it exceeds C2C_PLUGIN_DEBUG_MAX_LINES (default 500)
  // so stale entries from dead sessions don't pile up and confuse future readers.
  try {
    const { createHash } = await import("crypto");
    const src = fs.readFileSync(thisPluginPath, "utf-8");
    const sha = createHash("sha256").update(src).digest("hex").slice(0, 8);
    const ts = new Date().toISOString();
    const logPath = path.join(process.cwd(), ".opencode", "c2c-debug.log");
    const maxLines = parseInt(process.env.C2C_PLUGIN_DEBUG_MAX_LINES || "500", 10);
    try {
      if (fs.existsSync(logPath)) {
        const lineCount = fs.readFileSync(logPath, "utf-8").split("\n").length;
        if (lineCount > maxLines) {
          const backup = logPath + ".1";
          fs.renameSync(logPath, backup);
          // Fresh log starts with a rotation notice so context is clear.
          fs.writeFileSync(logPath,
            `[${ts}] pid=${process.pid} --- log rotated (was ${lineCount} lines > ${maxLines}) prev: ${backup} ---\n`
          );
        }
      }
    } catch { /* rotation failure is non-fatal */ }
    fs.appendFileSync(
      logPath,
      `[${ts}] pid=${process.pid} === c2c plugin boot sha=${sha} path=${thisPluginPath} ===\n`
    );
  } catch { /* non-fatal */ }

  // --- Config (env vars > sidecar .opencode/c2c-plugin.json) ---
  const sidecar = loadSidecarConfig();
  const sessionId: string =
    process.env.C2C_MCP_SESSION_ID || process.env.C2C_SESSION_ID || sidecar.session_id || "";
  const brokerRoot: string = process.env.C2C_MCP_BROKER_ROOT || sidecar.broker_root || "";
  const configuredOpenCodeSessionId: string =
    process.env.C2C_OPENCODE_SESSION_ID || sidecar.opencode_session_id || "";
  const pollIntervalMs: number = parseInt(process.env.C2C_PLUGIN_POLL_INTERVAL_MS || "30000", 10);
  const idleOnlyMode: boolean = (process.env.C2C_PLUGIN_DELIVER_ON_IDLE || "0") === "1";
  const permissionSupervisors: string[] = resolvePermissionSupervisors(sidecar);
  const supervisorStrategy: string =
    (sidecar.supervisor_strategy as string) ||
    (loadRepoConfig().supervisor_strategy as string) ||
    "first-alive";
  let supervisorIndex = 0;

  // Liveness cache: keyed by alias, expires after 30s
  const livenessCache = new Map<string, { alive: boolean; lastSeenAge: number; cachedAt: number }>();
  const livenessCacheTtlMs = 30_000;
  const staleThresholdS = parseInt(process.env.C2C_SUPERVISOR_STALE_THRESHOLD_S || "300", 10);

  async function querySupervisorLiveness(): Promise<Map<string, { alive: boolean; lastSeenAge: number }>> {
    const now = Date.now();
    // Return cache if fresh
    const allCached = permissionSupervisors.every(alias => {
      const entry = livenessCache.get(alias);
      return entry && (now - entry.cachedAt) < livenessCacheTtlMs;
    });
    if (allCached) {
      return new Map(permissionSupervisors.map(alias => {
        const e = livenessCache.get(alias)!;
        return [alias, { alive: e.alive, lastSeenAge: e.lastSeenAge }];
      }));
    }
    try {
      const raw = await runC2c(["list", "--json"]);
      const parsed = JSON.parse(raw);
      const sessions: any[] = Array.isArray(parsed) ? parsed : (parsed.sessions ?? parsed.registrations ?? []);
      const result = new Map<string, { alive: boolean; lastSeenAge: number }>();
      for (const alias of permissionSupervisors) {
        const entry = sessions.find((s: any) => s.alias === alias || s.session_id === alias);
        if (!entry) {
          result.set(alias, { alive: false, lastSeenAge: Infinity });
        } else {
          const lastSeenAge = entry.last_seen ? now / 1000 - entry.last_seen : Infinity;
          result.set(alias, { alive: entry.alive === true, lastSeenAge });
        }
        // Update cache
        const liveness = result.get(alias)!;
        livenessCache.set(alias, { ...liveness, cachedAt: now });
      }
      return result;
    } catch {
      // c2c list failed — assume all alive (graceful degradation)
      return new Map(permissionSupervisors.map(alias => [alias, { alive: true, lastSeenAge: 0 }]));
    }
  }

  /** Returns supervisor(s) to notify for this request. */
  const selectSupervisors = async (): Promise<string[]> => {
    if (supervisorStrategy === "broadcast") return permissionSupervisors;
    if (supervisorStrategy === "round-robin") {
      return [permissionSupervisors[supervisorIndex++ % permissionSupervisors.length]];
    }
    // first-alive: query broker liveness, pick first live+fresh supervisor
    const liveness = await querySupervisorLiveness();
    const live = permissionSupervisors.filter(alias => {
      const s = liveness.get(alias);
      return s && s.alive && s.lastSeenAge < staleThresholdS;
    });
    if (live.length > 0) return [live[0]];
    // Fallback: broadcast to all (none are live/fresh)
    await log(`supervisor liveness: no live supervisor — broadcasting to all ${permissionSupervisors.length}`);
    return permissionSupervisors;
  };
  const permissionTimeoutMs: number = parseInt(
    process.env.C2C_PERMISSION_TIMEOUT_MS || "600000", 10
  );
  const pluginStartTimeMs = Date.now();

  // Track the active root session (set from session events)
  let activeSessionId: string | null = configuredOpenCodeSessionId || null;
  let backgroundLoopStarted = false;
  let pendingToastShown = false; // debounce the "messages waiting" toast

  // Dedup window for permission notifications: track last 10 seen permission IDs.
  const seenPermissionIds: string[] = [];
  // Pending async permission approvals (v2): permId → resolve function.
  const pendingPermissions = new Map<string, (reply: string) => void>();
  // Dedup window for question.asked events.
  const seenQuestionIds: string[] = [];
  // Pending question replies: questionId → resolve({answer, rejected}).
  const pendingQuestions = new Map<string, (reply: {answer: string | null; rejected: boolean}) => void>();
  // Permissions that already timed-out and were auto-rejected. Kept around so
  // we can DM a "too late" notice to a supervisor whose reply arrives after
  // the window closed. Map: permId → {sid, supervisors, timedOutAtMs}.
  const timedOutPermissions = new Map<string, {
    sid: string;
    supervisors: string[];
    timedOutAtMs: number;
  }>();
  // Cleanup window for timed-out entries; after this many ms we forget.
  const timedOutMemoryMs: number = 30 * 60 * 1000; // 30 min

  // --- Helpers ---

  type TuiFocusType = "permission" | "question" | "prompt" | "menu" | "unknown";
  type LastStep = {
    event_type: string;
    at: string;
    details: Record<string, unknown> | null;
  };
  type PluginState = {
    c2c_session_id: string;
    c2c_alias: string | null;
    root_opencode_session_id: string | null;
    opencode_pid: number;
    plugin_started_at: string;
    state_last_updated_at: string;
    agent: {
      is_idle: boolean | null;
      turn_count: number;
      step_count: number;
      last_step: LastStep | null;
      provider_id: string | null;
      model_id: string | null;
    };
    tui_focus: {
      ty: TuiFocusType;
      details: Record<string, unknown> | null;
    };
    prompt: {
      has_text: boolean | null;
    };
    pendingQuestion: {
      id: string;
      text: string;
      header: string;
      options: string[];
    } | null;
    context_usage: {
      tokens_input: number;
      tokens_output: number;
      tokens_cache_read: number;
      cost_usd: number;
      completed_turns: number;
    };
  };
  type StateSnapshotEnvelope = {
    event: "state.snapshot";
    ts: string;
    state: PluginState;
  };
  type StatePatchEnvelope = {
    event: "state.patch";
    ts: string;
    patch: Record<string, unknown>;
  };

  const pluginStartedAt = new Date(pluginStartTimeMs).toISOString();
  const pluginState: PluginState = {
    c2c_session_id: sessionId,
    c2c_alias: typeof sidecar.alias === "string" && sidecar.alias.trim() ? sidecar.alias.trim() : null,
    root_opencode_session_id: configuredOpenCodeSessionId || null,
    opencode_pid: process.pid,
    plugin_started_at: pluginStartedAt,
    state_last_updated_at: pluginStartedAt,
    agent: {
      is_idle: null,
      turn_count: 0,
      step_count: 0,
      last_step: null,
      provider_id: null,
      model_id: null,
    },
    tui_focus: {
      ty: "unknown",
      details: null,
    },
    prompt: {
      has_text: null,
    },
    pendingQuestion: null,
    context_usage: {
      tokens_input: 0,
      tokens_output: 0,
      tokens_cache_read: 0,
      cost_usd: 0,
      completed_turns: 0,
    },
  };
  let stateWriterProc: ReturnType<typeof spawn> | null = null;
  let stateWriterAvailable = false;

  function firstString(...values: unknown[]): string {
    for (const value of values) {
      if (typeof value === "string" && value.trim()) return value.trim();
    }
    return "";
  }

  function detectPromptHasText(event: Event): boolean | null {
    const props = (event as any).properties ?? {};
    const candidates = [
      props.text,
      props.prompt,
      props.input,
      props.value,
      props.query,
      props.info?.text,
      props.info?.prompt,
      props.info?.input,
    ];
    for (const candidate of candidates) {
      if (typeof candidate === "string") return candidate.trim().length > 0;
    }
    const parts = props.body?.parts ?? props.parts;
    if (Array.isArray(parts)) {
      const text = parts
        .filter((part: any) => part?.type === "text" && typeof part?.text === "string")
        .map((part: any) => part.text)
        .join("\n")
        .trim();
      return text.length > 0;
    }
    if (event.type === "session.idle" || event.type === "session.created") return false;
    return null;
  }

  function compactSessionDetails(sessionID: string | null): Record<string, unknown> | null {
    return sessionID ? { session_id: sessionID } : null;
  }

  function compactPermissionDetails(event: Event): Record<string, unknown> | null {
    const props = (event as any).properties ?? {};
    const id = firstString(props.id, props.permissionID, props.permissionId) || null;
    const title = firstString(props.title) || null;
    const type = firstString(props.type) || null;
    return { id, title, type };
  }

  function makeLastStep(eventType: string, details: Record<string, unknown> | null): LastStep {
    return {
      event_type: eventType,
      at: new Date().toISOString(),
      details,
    };
  }

  function cloneState(): PluginState {
    return {
      ...pluginState,
      agent: {
        ...pluginState.agent,
        last_step: pluginState.agent.last_step
          ? {
              ...pluginState.agent.last_step,
              details: pluginState.agent.last_step.details
                ? { ...pluginState.agent.last_step.details }
                : null,
            }
          : null,
      },
      tui_focus: {
        ...pluginState.tui_focus,
        details: pluginState.tui_focus.details ? { ...pluginState.tui_focus.details } : null,
      },
      prompt: {
        ...pluginState.prompt,
      },
    };
  }

  function writeStateLine(payload: StateSnapshotEnvelope | StatePatchEnvelope): void {
    if (!stateWriterAvailable || !stateWriterProc?.stdin) return;
    try {
      stateWriterProc.stdin.write(JSON.stringify(payload) + "\n");
    } catch {
      stateWriterAvailable = false;
      stateWriterProc = null;
      setTimeout(() => void spawnStateWriter(), 10_000);
    }
  }

  function writeStateSnapshot(): void {
    const ts = new Date().toISOString();
    pluginState.state_last_updated_at = ts;
    writeStateLine({ event: "state.snapshot", ts, state: cloneState() });
  }

  function writeStatePatch(patch: Record<string, unknown>): void {
    const ts = new Date().toISOString();
    pluginState.state_last_updated_at = ts;
    writeStateLine({
      event: "state.patch",
      ts,
      patch: {
        ...patch,
        state_last_updated_at: ts,
      },
    });
  }

  async function spawnStateWriter(): Promise<void> {
    const command = process.env.C2C_CLI_COMMAND || "c2c";
    try {
      const proc = spawn(command, ["oc-plugin", "stream-write-statefile"], {
        cwd: process.cwd(),
        env: process.env,
        shell: false,
      });
      stateWriterProc = proc;
      stateWriterAvailable = true;
      proc.on("error", (err) => {
        stateWriterAvailable = false;
        stateWriterProc = null;
        void log(`state writer error: ${err}`);
      });
      proc.on("close", (code) => {
        stateWriterAvailable = false;
        if (stateWriterProc === proc) {
          stateWriterProc = null;
          void log(`state writer exited: code=${code} — reconnecting in 10s`);
          setTimeout(() => void spawnStateWriter(), 10_000);
        }
      });
      writeStateSnapshot();
    } catch {
      stateWriterAvailable = false;
      stateWriterProc = null;
      await log("state writer spawn failed — reconnecting in 30s");
      setTimeout(() => void spawnStateWriter(), 30_000);
    }
  }

  /**
   * Detect conflicting alive OpenCode instances. Throws FATAL if another
   * c2c-managed OpenCode process (same broker) is alive and would compete
   * for the same session pool — preventing the cross-contamination bug where
   * bootstrapRootSession() adopts a peer's session.
   * See finding: 2026-04-21T09-00-00Z-coordinator1-oc-focus-test-session-cross-contamination.md
   */
  async function checkConflictingInstances(): Promise<void> {
    const home = process.env.HOME || "";
    const instancesDir = path.join(home, ".local", "share", "c2c", "instances");
    let entries: string[];
    try { entries = fs.readdirSync(instancesDir); } catch { return; }

    for (const name of entries) {
      if (name === sessionId) continue;
      let theirState: any;
      let theirConfig: any;
      try {
        const stateRaw = fs.readFileSync(path.join(instancesDir, name, "oc-plugin-state.json"), "utf-8");
        const parsed = JSON.parse(stateRaw);
        theirState = parsed.state ?? parsed;
      } catch { continue; }
      try {
        theirConfig = JSON.parse(fs.readFileSync(path.join(instancesDir, name, "config.json"), "utf-8"));
      } catch { theirConfig = {}; }

      const theirPid: number | undefined = theirState.opencode_pid;
      if (!theirPid) continue;
      if (!fs.existsSync(`/proc/${theirPid}`)) continue; // dead process

      const theirBrokerRoot: string = theirConfig.broker_root ?? theirState.broker_root ?? "";
      if (brokerRoot && theirBrokerRoot && theirBrokerRoot !== brokerRoot) continue; // different project

      const theirAlias: string = theirState.c2c_session_id ?? name;
      const theirRootOcSession: string = theirState.root_opencode_session_id ?? "";

      const conflict = !configuredOpenCodeSessionId   // auto-kickoff: any alive peer is a conflict
        || (configuredOpenCodeSessionId && theirRootOcSession === configuredOpenCodeSessionId); // resume: exact session clash

      if (conflict) {
        const msg = `FATAL: conflicting c2c opencode instance '${theirAlias}' (pid ${theirPid}) owns session ${theirRootOcSession || "unknown"}. Stop it first: c2c stop ${theirAlias}`;
        await log(msg);
        throw new Error(msg);
      }
    }
  }

  /** On resume (session.created missed), bootstrap root from HTTP session list. */
  async function bootstrapRootSession(): Promise<void> {
    if (pluginState.root_opencode_session_id) return;
    try {
      const result = await (ctx.client.session as any).list();
      const sessions: any[] = Array.isArray(result?.data) ? result.data
        : Array.isArray(result) ? result : [];
      const roots = sessions
        .filter((s: any) => !s.parentID && s.id)
        .sort((a: any, b: any) => (b.time?.updated ?? 0) - (a.time?.updated ?? 0));
      const candidate = configuredOpenCodeSessionId
        ? roots.find((s: any) => s.id === configuredOpenCodeSessionId)  // exact match only; no fallback to roots[0]
        : (process.env.C2C_AUTO_KICKOFF === "1" ? undefined : roots[0]); // auto-kickoff: never adopt stale session, let session.create() fire
      if (!candidate?.id) {
        if (roots.length > 0) {
          const skipped = roots.map((s: any) => s.id).join(", ");
          const reason = configuredOpenCodeSessionId ? "configured-id-mismatch" : "auto-kickoff";
          await log(`SKIP-ADOPT: would have adopted [${skipped}]; reason=${reason}; see finding 2026-04-21T09-00-00Z-coordinator1-oc-focus-test-session-cross-contamination.md`);
        }
        return;
      }
      pluginState.root_opencode_session_id = candidate.id;
      if (!activeSessionId) activeSessionId = candidate.id;
      await log(`bootstrapped root session from HTTP list: ${candidate.id}`);
      writeStatePatch({ root_opencode_session_id: candidate.id });
    } catch (err) {
      await log(`bootstrapRootSession: non-fatal error: ${err}`);
    }
  }

  function eventSessionId(event: Event): string | null {
    const props = (event as any).properties ?? {};
    const info = props.info ?? {};
    return firstString(info.id, props.sessionID, props.sessionId, activeSessionId) || null;
  }

  function shouldAdoptRootFromIdle(event: Event): string | null {
    if (pluginState.root_opencode_session_id) return null;
    if (event.type !== "session.idle") return null;
    const sessionID = eventSessionId(event);
    if (!sessionID) return null;
    if (configuredOpenCodeSessionId && sessionID !== configuredOpenCodeSessionId) return null;
    return sessionID;
  }

  function belongsToTrackedRoot(event: Event): boolean {
    const sessionID = eventSessionId(event);
    if (!sessionID) return false;
    return sessionID === pluginState.root_opencode_session_id;
  }

  function maybeTrackProviderAndModel(event: Event): void {
    const props = (event as any).properties ?? {};
    const info = props.info ?? {};
    const provider = firstString(info.provider, props.provider) || null;
    const model = firstString(info.model, props.model) || null;
    if (provider) pluginState.agent.provider_id = provider;
    if (model) pluginState.agent.model_id = model;
  }

  function applyRootSessionCreated(event: Event): void {
    const info = (event as any).properties?.info;
    if (!info?.id || info?.parentID) return;
    if (configuredOpenCodeSessionId && info.id !== configuredOpenCodeSessionId) return;
    // Reset kickoff flag so the new root session always receives the kickoff prompt.
    // Without this, if a second root session is created mid-run (e.g. agent ran a
    // command that triggered session.created), kickoffDelivered stays true and the
    // new session starts blank — root cause of #58 TUI divergence.
    kickoffDelivered = false;
    pluginState.root_opencode_session_id = info.id;
    pluginState.agent.step_count += 1;
    pluginState.agent.last_step = makeLastStep("session.created", compactSessionDetails(info.id));
    pluginState.tui_focus = { ty: "prompt", details: null };
    pluginState.prompt.has_text = false;
    writeStatePatch({
      root_opencode_session_id: info.id,
      agent: {
        step_count: pluginState.agent.step_count,
        last_step: pluginState.agent.last_step,
      },
      tui_focus: pluginState.tui_focus,
      prompt: pluginState.prompt,
    });
  }

  function applyIdleState(event: Event): void {
    const adopted = shouldAdoptRootFromIdle(event);
    if (adopted) pluginState.root_opencode_session_id = adopted;
    if (!belongsToTrackedRoot(event)) return;

    const sessionID = eventSessionId(event);
    pluginState.agent.is_idle = true;
    pluginState.agent.turn_count += 1;
    pluginState.agent.step_count += 1;
    pluginState.agent.last_step = makeLastStep("session.idle", compactSessionDetails(sessionID));
    pluginState.tui_focus = { ty: "prompt", details: null };
    pluginState.prompt.has_text = false;
    writeStatePatch({
      root_opencode_session_id: pluginState.root_opencode_session_id,
      agent: {
        is_idle: true,
        turn_count: pluginState.agent.turn_count,
        step_count: pluginState.agent.step_count,
        last_step: pluginState.agent.last_step,
      },
      tui_focus: pluginState.tui_focus,
      prompt: pluginState.prompt,
    });
  }

  function applyPermissionState(event: Event): void {
    const props = (event as any).properties ?? {};
    const sessionID = firstString(props.sessionID, props.sessionId, activeSessionId) || null;
    if (!pluginState.root_opencode_session_id && sessionID && event.type === "permission.asked") {
      if (!configuredOpenCodeSessionId || configuredOpenCodeSessionId === sessionID) {
        pluginState.root_opencode_session_id = sessionID;
      }
    }
    if (!sessionID || sessionID !== pluginState.root_opencode_session_id) return;

    pluginState.agent.is_idle = false;
    pluginState.agent.step_count += 1;
    pluginState.agent.last_step = makeLastStep(event.type, compactPermissionDetails(event));
    pluginState.tui_focus = {
      ty: "permission",
      details: compactPermissionDetails(event),
    };
    writeStatePatch({
      root_opencode_session_id: pluginState.root_opencode_session_id,
      agent: {
        is_idle: false,
        step_count: pluginState.agent.step_count,
        last_step: pluginState.agent.last_step,
      },
      tui_focus: pluginState.tui_focus,
    });
  }

  function updatePluginState(event: Event): void {
    maybeTrackProviderAndModel(event);

    if (event.type === "session.created") {
      applyRootSessionCreated(event);
      return;
    }

    if (event.type === "session.idle") {
      applyIdleState(event);
      return;
    }

    if (event.type === "permission.asked" || event.type === "permission.updated") {
      applyPermissionState(event);
      return;
    }

    if (event.type === "message.updated") {
      const info = (event as any).properties?.info;
      if (info?.role === "assistant" && typeof info?.time?.completed === "number") {
        const tokens = info.tokens ?? {};
        const prev = pluginState.context_usage;
        const next = {
          tokens_input: tokens.input ?? 0,
          tokens_output: tokens.output ?? 0,
          tokens_cache_read: tokens.cache?.read ?? 0,
          cost_usd: prev.cost_usd + (typeof info.cost === "number" ? info.cost : 0),
          completed_turns: prev.completed_turns + 1,
        };
        pluginState.context_usage = next;
        writeStatePatch({ context_usage: next });
      }
      return;
    }

    const promptHasText = detectPromptHasText(event);
    if (promptHasText !== null) pluginState.prompt.has_text = promptHasText;
  }

  // Debug log to disk — survives even if OpenCode log API is broken.
  // On by default; silence with C2C_PLUGIN_DEBUG=0.
  const pluginDebug = (process.env.C2C_PLUGIN_DEBUG || "1") !== "0";
  const debugLogPath = path.join(process.cwd(), ".opencode", "c2c-debug.log");
  const pluginPid = process.pid;

  function debugLog(msg: string): void {
    if (!pluginDebug) return;
    try {
      const ts = new Date().toISOString();
      fs.appendFileSync(debugLogPath, `[${ts}] [pid=${pluginPid}] ${msg}\n`);
    } catch { /* non-fatal */ }
  }

  async function log(msg: string): Promise<void> {
    debugLog(msg);
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
    const command = process.env.C2C_CLI_COMMAND || "c2c";
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
    try {
      const stdout = (await runC2c(["poll-inbox", "--json"])).trim();
      const msgs = parsePollResult(stdout);
      await log(`drainInbox: got ${msgs.length} message(s)`);
      return msgs;
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

  /** Extract a question reply: `question:<id>:answer:<text>` or `question:<id>:reject`. */
  function extractQuestionReply(content: string): { qId: string; answer: string | null; rejected: boolean } | null {
    const rejectM = content.match(/\bquestion:([a-zA-Z0-9_-]+):reject\b/);
    if (rejectM) return { qId: rejectM[1], answer: null, rejected: true };
    const answerM = content.match(/\bquestion:([a-zA-Z0-9_-]+):answer:(.+)/s);
    if (answerM) return { qId: answerM[1], answer: answerM[2].trim(), rejected: false };
    return null;
  }

  /** Await a supervisor question reply; resolves with answer text or null (rejected/timeout). */
  function waitForQuestionReply(qId: string, timeoutMs: number): Promise<{answer: string | null; rejected: boolean}> {
    return new Promise((resolve) => {
      pendingQuestions.set(qId, resolve);
      setTimeout(() => {
        if (pendingQuestions.has(qId)) {
          pendingQuestions.delete(qId);
          resolve({ answer: null, rejected: false }); // timeout → reject with no noise
        }
      }, timeoutMs);
    });
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
    await log(`deliverMessages: targetSessionId=${JSON.stringify(targetSessionId)}`);
    // Drain spool first (messages from failed previous delivery cycle).
    const spooled = readSpool();
    const fresh = await drainInbox();
    const messages = [...spooled, ...fresh];
    await log(`deliverMessages: spooled=${spooled.length} fresh=${fresh.length} total=${messages.length}`);
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
      // Intercept question replies before normal delivery.
      const qReply = extractQuestionReply(msg.content);
      if (qReply && pendingQuestions.has(qReply.qId)) {
        const resolve = pendingQuestions.get(qReply.qId)!;
        pendingQuestions.delete(qReply.qId);
        resolve({ answer: qReply.answer, rejected: qReply.rejected });
        await log(`question reply from ${msg.from_alias}: ${qReply.qId} → ${qReply.rejected ? "reject" : `"${qReply.answer}"`}`);
        continue;
      }
      // Late reply: request already timed-out and was auto-rejected. Let the
      // supervisor know so they aren't left wondering why their decision had
      // no effect.
      if (permReply && timedOutPermissions.has(permReply.permId)) {
        const entry = timedOutPermissions.get(permReply.permId)!;
        const lateBySec = Math.round((Date.now() - entry.timedOutAtMs) / 1000);
        const notice = `permission ${permReply.permId}: your reply \"${permReply.decision}\" arrived ${lateBySec}s after the timeout — request was already auto-rejected. Bump C2C_PERMISSION_TIMEOUT_MS on the requester to widen the window.`;
        try {
          await runC2c(["send", msg.from_alias || "coordinator1", notice]);
          await log(`late permission reply → ${msg.from_alias}: ${permReply.permId} (${lateBySec}s late)`);
        } catch (err) {
          await log(`late permission reply DM error: ${err}`);
        }
        continue;
      }
      const envelope = formatEnvelope(msg);
      const callArgs = {
        path: { id: targetSessionId },
        body: { parts: [{ type: "text", text: envelope }] },
        url: "/session/{id}/prompt_async",
      };
      await log(`promptAsync CALL: path.id=${targetSessionId} body.text.slice(0,400)=${envelope.slice(0, 400)}`);
      try {
        const result = await (ctx.client.session as any).promptAsync(callArgs);
        await log(`promptAsync RESULT: ${JSON.stringify(result).slice(0, 300)}`);
        await log(`delivered from ${msg.from_alias}`);
      } catch (err) {
        await log(`promptAsync THREW: ${err}`);
        // Keep in spool — will be retried on next delivery cycle.
        failed.push(msg);
        await toast(`c2c: delivery error from ${msg.from_alias}`, "error");
      }
    }
    // Update spool: clear if all delivered, write failures if any.
    writeSpool(failed);
    // Reset toast debounce so a future batch of messages shows a fresh toast.
    if (failed.length === 0) pendingToastShown = false;
  }

  // ---------------------------------------------------------------------------
  // Kickoff prompt — one-shot getting-started message written by c2c start --auto
  // ---------------------------------------------------------------------------

  // Per-instance kickoff path set by `c2c start` (#64). Falls back to shared path
  // for manual installs that don't use c2c start.
  const kickoffPromptPath =
    process.env.C2C_KICKOFF_PROMPT_PATH ||
    path.join(process.cwd(), ".opencode", "kickoff-prompt.txt");
  const autoKickoff = (process.env.C2C_AUTO_KICKOFF || "0") !== "0";
  let kickoffDelivered = false;

  /** Deliver kickoff prompt file then delete it. No-op if absent or already delivered. */
  async function deliverKickoffPrompt(targetSessionId: string): Promise<void> {
    if (kickoffDelivered) return;
    let text: string;
    try {
      text = fs.readFileSync(kickoffPromptPath, "utf-8").trim();
    } catch {
      kickoffDelivered = true; // file absent — mark done
      return;
    }
    if (!text) { kickoffDelivered = true; return; }
    await log(`kickoff: delivering prompt (${text.length} chars) to ${targetSessionId}`);
    const callArgs = {
      path: { id: targetSessionId },
      body: { parts: [{ type: "text", text }] },
      url: "/session/{id}/prompt_async",
    };
    try {
      await (ctx.client.session as any).promptAsync(callArgs);
      kickoffDelivered = true;
      await log("kickoff: delivered");
      try { fs.unlinkSync(kickoffPromptPath); } catch { /* best-effort */ }
    } catch (err) {
      await log(`kickoff: promptAsync error: ${err}`);
      // leave file in place and kickoffDelivered=false — retry on next idle
    }
  }

  /** Try to deliver to the best-known session ID. */
  async function tryDeliver(): Promise<void> {
    const sid = activeSessionId;
    await log(`tryDeliver: activeSessionId=${JSON.stringify(sid)}`);
    if (!sid) {
      // No session yet — wait for session.created event to set activeSessionId.
      // Do NOT use session.list() fallback: it returns ALL historical sessions
      // across all OpenCode instances and would deliver to the wrong session.
      await log("tryDeliver: no session yet — waiting for session.created");
      // If there are spooled messages, show a one-time toast so the user knows
      // to type something to receive them (promptAsync requires an active session).
      if (!pendingToastShown) {
        const pending = readSpool();
        if (pending.length > 0) {
          pendingToastShown = true;
          await toast(`${pending.length} c2c message(s) waiting — start a session to receive`, "info");
        }
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
    let activeMonitorProc: ReturnType<typeof spawn> | null = null;
    let monitorStopped = false;

    function spawnMonitor(): void {
      if (monitorStopped) return;
      const command = process.env.C2C_CLI_COMMAND || "c2c";
      const args = ["monitor"];
      if (sessionId) args.push("--alias", sessionId);
      const proc = spawn(command, args, { cwd: process.cwd(), env: process.env, shell: false });
      activeMonitorProc = proc;
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
      proc.on("close", () => {
        if (activeMonitorProc === proc) activeMonitorProc = null;
        if (!monitorStopped) {
          void log("c2c monitor exited, restarting in 5s");
          setTimeout(spawnMonitor, 5000);
        }
      });
      proc.on("error", () => { if (!monitorStopped) setTimeout(spawnMonitor, 10_000); });
    }

    // Kill monitor on graceful exit so it doesn't outlive opencode.
    process.on("exit", () => {
      monitorStopped = true;
      try { activeMonitorProc?.kill("SIGTERM"); } catch { /* ignore */ }
    });

    spawnMonitor();
    void log(`c2c monitor spawned (alias=${sessionId})`);

    // Safety net: poll once on startup and every pollIntervalMs in case monitor misses events
    setTimeout(tick, 1000);
    setInterval(tick, pollIntervalMs);
  }

  // --- Guard: no delivery without session ID ---
  if (!sessionId) {
    await log("C2C_MCP_SESSION_ID not set — message delivery disabled");
    void toast("c2c plugin: set C2C_MCP_SESSION_ID to enable delivery", "warning");
    return {};
  }

  // Introspect available API methods to diagnose promptAsync availability.
  const sessionMethods = Object.keys(ctx.client.session as any).join(",");
  const appMethods = Object.keys(ctx.client.app as any).join(",");
  // Log a sha256 of the plugin file itself so stale bun JIT cache is immediately detectable.
  const pluginFilePath = new URL(import.meta.url).pathname;
  let pluginHash = "?";
  try { pluginHash = crypto.createHash("sha256").update(fs.readFileSync(pluginFilePath)).digest("hex").slice(0, 12); } catch { /**/ }
  await log(`plugin loaded (session=${sessionId}, interval=${pollIntervalMs}ms, idleOnly=${idleOnlyMode}, sha256=${pluginHash})`);
  await log(`API introspect: session methods=[${sessionMethods}] app methods=[${appMethods}]`);
  await spawnStateWriter();
  await checkConflictingInstances();
  void bootstrapRootSession();
  startBackgroundLoop();

  // Auto-kickoff (#64): when C2C_AUTO_KICKOFF=1 and no session materializes
  // within a grace window, proactively create a session via session.create()
  // and deliver the kickoff prompt. Unblocks tmux-launched --auto flows where
  // session.created never fires on its own.
  if (process.env.C2C_AUTO_KICKOFF === "1") {
    const graceMs = parseInt(process.env.C2C_AUTO_KICKOFF_GRACE_MS || "8000", 10);
    setTimeout(async () => {
      if (activeSessionId) {
        await log(`auto-kickoff: session already adopted (${activeSessionId}), skip`);
        return;
      }
      if (!fs.existsSync(kickoffPromptPath)) {
        await log(`auto-kickoff: no kickoff-prompt.txt, skip`);
        return;
      }
      try {
        await log(`auto-kickoff: grace elapsed (${graceMs}ms), calling session.create`);
        const res: any = await (ctx.client.session as any).create({ body: { title: "c2c kickoff" } });
        const sid: string | undefined = res?.data?.id ?? res?.id;
        if (!sid) { await log(`auto-kickoff: session.create returned no id: ${JSON.stringify(res).slice(0,200)}`); return; }
        activeSessionId = sid;
        pluginState.root_opencode_session_id = sid;
        writeStatePatch({ root_opencode_session_id: sid });
        await log(`auto-kickoff: created session ${sid} — delivering kickoff prompt`);
        // Drive the TUI to focus the new session. The TuiPlugin SDK surface
        // has no event bus (confirmed in @opencode-ai/plugin tui.d.ts), so we
        // instead POST tui.session.select to the running opencode's HTTP API.
        // The runtime accepts a broader event set than the SDK types expose.
        try {
          const resp = await fetch(new URL("/tui/publish", ctx.serverUrl), {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ type: "tui.session.select", properties: { sessionID: sid } }),
          });
          await log(`auto-kickoff: tui.session.select posted (status=${resp.status})`);
        } catch (err) {
          await log(`auto-kickoff: tui.session.select POST failed: ${err}`);
        }
        await deliverKickoffPrompt(sid);
      } catch (err) {
        await log(`auto-kickoff: error: ${err}`);
      }
    }, graceMs);
  }

  // --- Return hooks ---
  return {
    event: async ({ event }: { event: Event }) => {
      // Log every event type for debugging (permission hook, delivery, etc.)
      await log(`event: type=${event.type}`);
      updatePluginState(event);
      // Track root session ID from creation events — also trigger immediate delivery
      // so queued messages arrive without waiting for the next background loop tick.
      if (event.type === "session.created") {
        const e = event as EventSessionCreated;
        const info = (e as any).properties?.info;
        if (info?.id && !info?.parentID) {
          if (configuredOpenCodeSessionId && info.id !== configuredOpenCodeSessionId) return;
          activeSessionId = info.id;
          await log(`tracking root session: ${info.id} — triggering cold-boot delivery`);
          // Persist the TUI-generated ses_* ID for the instance so that a
          // subsequent `c2c start opencode -n <name>` can pass --session
          // and resume this exact conversation instead of a fresh one.
          // Guard: only capture on the FIRST root session of this plugin run
          // (turn_count === 0). If turns have already happened, we have an
          // established session — overwriting would clobber the real session ID
          // with a mid-run spurious one (root cause of #58 TUI divergence).
          const isFirstSession = pluginState.agent.turn_count === 0;
          if (sessionId && info.id.startsWith("ses") && isFirstSession) {
            try {
              const instDir = path.join(
                process.env.HOME || "",
                ".local", "share", "c2c", "instances", sessionId
              );
              fs.mkdirSync(instDir, { recursive: true });
              fs.writeFileSync(path.join(instDir, "opencode-session.txt"), info.id + "\n");
              await log(`captured opencode session id → ${path.join(instDir, "opencode-session.txt")}`);
            } catch (err) {
              await log(`session id capture error: ${err}`);
            }
          } else if (sessionId && !isFirstSession) {
            await log(`skipped opencode-session.txt overwrite for ${info.id} (turn_count=${pluginState.agent.turn_count} — real session already established)`);
          }
          // Delay before first promptAsync: calling it too soon after session.created
          // can succeed silently but the session may not yet be ready to surface the
          // message. Configurable via C2C_PLUGIN_COLD_BOOT_DELAY_MS (default 1500;
          // set to 0 in tests to skip the delay).
          const coldBootDelayMs = parseInt(process.env.C2C_PLUGIN_COLD_BOOT_DELAY_MS || "1500", 10);
          if (coldBootDelayMs > 0) {
            await new Promise<void>(resolve => setTimeout(resolve, coldBootDelayMs));
          }
          await deliverMessages(info.id);
          // If messages remain in spool after the first attempt, retry once more after 3s.
          const afterSpool = readSpool();
          if (afterSpool.length > 0) {
            await log(`cold-boot: ${afterSpool.length} message(s) still in spool after first attempt — retrying in 3s`);
            setTimeout(() => deliverMessages(info.id).catch(() => {}), 3000);
          }
        }
        return;
      }

      // Permission flow (v2): opencode emits "permission.asked" via the SDK Event
      // stream for every ask — both config-declared (e.g. `"permission": {"bash": "ask"}`)
      // and runtime-declared. The `permission.ask` plugin hook in the Hooks interface
      // is NOT wired in current opencode builds (binary has no literal "permission.ask"
      // string — only "permission.asked"/"permission.replied" events). So we resolve
      // the dialog by calling the HTTP API directly.
      if (event.type === "permission.asked" || event.type === "permission.updated") {
        const perm = (event as any).properties ?? {};
        const permId: string = perm.id || "";
        if (!permId) return;
        if (seenPermissionIds.includes(permId)) return;
        seenPermissionIds.push(permId);
        if (seenPermissionIds.length > 20) seenPermissionIds.shift();

        const sid: string = perm.sessionID || activeSessionId || sessionId || "unknown";
        const timeoutSec = Math.round(permissionTimeoutMs / 1000);
        const summary = summarizePermission(perm as Record<string, unknown>);
        const instanceName: string = process.env.C2C_INSTANCE_NAME || "";
        const from = instanceName || sessionId || sid;
        const msg = [
          `PERMISSION REQUEST from ${from}:`,
          `  action: ${summary}`,
          `  id: ${permId}`,
          `  session: ${sid}`,
          `Reply within ${timeoutSec}s:`,
          `  c2c send ${sessionId} "permission:${permId}:approve-once"`,
          `  c2c send ${sessionId} "permission:${permId}:approve-always"`,
          `  c2c send ${sessionId} "permission:${permId}:reject"`,
          `(timeout → auto-reject; late replies will be NACK'd)`,
        ].join("\n");

        // Fire-and-forget: wait for a reply in the background and resolve via HTTP.
        void (async () => {
          const supervisors = await selectSupervisors();
          for (const supervisor of supervisors) {
            try {
              await runC2c(["send", supervisor, msg]);
              await log(`permission DM sent to ${supervisor}: ${permId}`);
            } catch (err) {
              await log(`permission DM error (${supervisor}): ${err}`);
            }
          }
          const minutes = Math.round(permissionTimeoutMs / 60000);
          const who = supervisors.length === 1 ? supervisors[0] : `${supervisors.length} supervisors`;
          void toast(`c2c · awaiting approval from ${who} (${minutes}m)`);
          const reply = await waitForPermissionReply(permId, permissionTimeoutMs);
          const timedOut = reply === "timeout";
          const response =
            reply === "approve-once" ? "once" :
            reply === "approve-always" ? "always" :
            "reject"; // covers both explicit reject AND timeout (fail-closed)
          if (timedOut) {
            await log(`permission timeout (${timeoutSec}s): ${permId} — auto-rejecting`);
            timedOutPermissions.set(permId, {
              sid,
              supervisors,
              timedOutAtMs: Date.now(),
            });
            // Garbage-collect the entry later so the Map doesn't grow forever.
            setTimeout(() => timedOutPermissions.delete(permId), timedOutMemoryMs);
            // Notify every supervisor we asked, so the swarm knows the
            // request expired without human input.
            for (const supervisor of supervisors) {
              try {
                await runC2c(["send", supervisor,
                  `permission ${permId} timed out after ${timeoutSec}s — auto-rejected. Reply with "permission:${permId}:approve-once" or similar to learn it arrived late.`]);
              } catch { /* best-effort */ }
            }
            const mins = Math.round(permissionTimeoutMs / 60000);
            void toast(`c2c · no reply in ${mins}m — auto-rejected`, "warning");
          }
          try {
            await (ctx.client as any).postSessionIdPermissionsPermissionId({
              path: { id: sid, permissionID: permId },
              body: { response },
            });
            await log(`permission resolved via HTTP: ${permId} → ${response}${timedOut ? " (timeout)" : ""}`);
            if (!timedOut) {
              const by = supervisors.length === 1 ? ` by ${supervisors[0]}` : "";
              const nice =
                response === "once"   ? `approved once${by}` :
                response === "always" ? `approved always${by}` :
                                        `rejected${by}`;
              void toast(`c2c · ${nice}`);
            }
          } catch (err) {
            await log(`permission HTTP resolve error: ${permId} → ${response}: ${err}`);
            void toast(`c2c · resolve failed — use TUI dialog`, "error");
          }
        })();
        return;
      }

      // Question flow: opencode emits "question.asked" when the agent needs
      // human input (clarification, multiple-choice, free text). We notify the
      // supervisor via DM and forward their reply through the HTTP API.
      if (event.type === "question.asked") {
        const qProps = (event as any).properties ?? {};
        const qId: string = qProps.id || "";
        if (!qId || seenQuestionIds.includes(qId)) return;
        seenQuestionIds.push(qId);
        if (seenQuestionIds.length > 20) seenQuestionIds.shift();

        const questions: Array<{question: string; header: string; options: Array<{value: string}>}> =
          qProps.questions || [];
        const sid: string = qProps.sessionID || activeSessionId || sessionId || "unknown";
        const instanceName: string = process.env.C2C_INSTANCE_NAME || "";
        const from = instanceName || sessionId || sid;
        const timeoutSec = Math.round(permissionTimeoutMs / 1000); // reuses C2C_PERMISSION_TIMEOUT_MS

        // Capture in statefile so observer pane shows pending question.
        if (questions.length > 0) {
          const first = questions[0];
          pluginState.pendingQuestion = {
            id: qId,
            text: first.question || "",
            header: first.header || "",
            options: (first.options || []).map((o: any) => String(o.value || o)),
          };
          writeStateSnapshot();
        }

        const lines = [`QUESTION REQUEST from ${from}:`];
        for (let i = 0; i < questions.length; i++) {
          const q = questions[i];
          lines.push(`  Q${i + 1}: ${q.header || q.question}`);
          if (q.question !== q.header) lines.push(`       ${q.question}`);
          const opts = (q.options || []).map((o: any) => String(o.value || o));
          if (opts.length > 0) lines.push(`       Options: ${opts.join(" | ")}`);
        }
        lines.push(`  id: ${qId}`, `  session: ${sid}`);
        lines.push(`Reply within ${timeoutSec}s:`);
        lines.push(`  c2c send ${sessionId} "question:${qId}:answer:<your answer>"`);
        lines.push(`  c2c send ${sessionId} "question:${qId}:reject"`);

        void (async () => {
          const supervisors = await selectSupervisors();
          for (const supervisor of supervisors) {
            try {
              await runC2c(["send", supervisor, lines.join("\n")]);
              await log(`question DM sent to ${supervisor}: ${qId}`);
            } catch (err) {
              await log(`question DM error (${supervisor}): ${err}`);
            }
          }
          void toast(`c2c · question — awaiting human input`);
          const reply = await waitForQuestionReply(qId, timeoutSec * 1000);
          pluginState.pendingQuestion = null;
          writeStateSnapshot();
          const answers: string[][] = questions.map(() =>
            reply.answer !== null ? [reply.answer] : []
          );
          try {
            if (reply.rejected || reply.answer === null) {
              await (ctx.client as any).question.reject({
                path: { id: qId },
              });
              await log(`question rejected/timed-out: ${qId}`);
              void toast(`c2c · question ${reply.rejected ? "rejected" : "timed out"}`, "warning");
            } else {
              await (ctx.client as any).question.reply({
                path: { id: qId },
                body: { answers },
              });
              await log(`question replied: ${qId} → "${reply.answer}"`);
              void toast(`c2c · question answered`);
            }
          } catch (err) {
            await log(`question API error: ${qId}: ${err}`);
            void toast(`c2c · question reply failed — use TUI`, "error");
          }
        })();
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
        await deliverKickoffPrompt(idleSessionId);
        await deliverMessages(idleSessionId);
      }
    },

  };
};

export default C2CDelivery;
