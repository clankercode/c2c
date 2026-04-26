import { Command } from "@tauri-apps/plugin-shell";
import { C2cEvent, safeParseInboxMessage, safeParseHistoryEntry } from "./types";
import { toast } from "./useToast";

interface HistoryEntry {
  drained_at?: number;
  ts?: number;
  from_alias: string;
  to_alias?: string;
  content: string;
}

function entryToEvent(e: HistoryEntry, toAlias?: string): C2cEvent {
  const ts = e.drained_at ?? e.ts ?? Date.now() / 1000;
  // Archive to_alias may be "recipient#room_id" for room fan-out — extract room
  const rawTo = toAlias ?? e.to_alias ?? "";
  const hashIdx = rawTo.indexOf("#");
  const resolvedTo = hashIdx >= 0 ? rawTo.slice(hashIdx + 1) : rawTo;
  const roomId = hashIdx >= 0 ? rawTo.slice(hashIdx + 1) : undefined;
  return {
    event_type: "message" as const,
    monitor_ts: String(ts),
    from_alias: e.from_alias ?? "",
    to_alias: resolvedTo,
    content: e.content ?? "",
    ts: new Date(ts * 1000).toISOString(),
    ...(roomId ? { room_id: roomId } : {}),
    _historical: true,
  };
}

export async function pollInbox(sessionId: string): Promise<C2cEvent[]> {
  try {
    const result = await Command.create("c2c", [
      "poll-inbox", "--json", "--session-id", sessionId,
    ]).execute();
    if (result.code !== 0) return [];
    let raw: unknown;
    try { raw = JSON.parse(result.stdout); } catch { return []; }
    if (!Array.isArray(raw)) return [];
    const messages = (raw as unknown[]).map(safeParseInboxMessage).filter((m): m is NonNullable<typeof m> => m !== null);
    const now = Date.now() / 1000;
    return messages.map((m, i) => {
      const msgTs = m.ts ?? (now + i * 0.001);
      return {
        event_type: "message" as const,
        monitor_ts: String(msgTs),
        from_alias: m.from_alias,
        to_alias: m.to_alias,
        content: m.content,
        ts: new Date(msgTs * 1000).toISOString(),
      };
    });
  } catch {
    return [];
  }
}

export async function loadHistory(limit = 100, sessionId?: string): Promise<C2cEvent[]> {
  try {
    const args = ["history", "--json", "--limit", String(limit)];
    if (sessionId) args.push("--session-id", sessionId);
    const result = await Command.create("c2c", args).execute();
    if (result.code !== 0) {
      toast.error(`history: ${result.stderr || `exit ${result.code}`}`, 5);
      return [];
    }
    let raw: unknown;
    try { raw = JSON.parse(result.stdout); } catch { toast.error("history: JSON parse error", 5); return []; }
    if (!Array.isArray(raw)) { toast.error("history: expected array", 5); return []; }
    const entries = (raw as unknown[]).map(safeParseHistoryEntry).filter((e): e is NonNullable<typeof e> => e !== null);
    return entries.map(e => entryToEvent(e));
  } catch (err) {
    toast.error(`history: ${String(err)}`, 5);
    return [];
  }
}

export async function loadRoomHistory(roomId: string, limit = 50): Promise<C2cEvent[]> {
  try {
    const result = await Command.create("c2c", [
      "room", "history", roomId, "--json", "--limit", String(limit),
    ]).execute();
    if (result.code !== 0) {
      toast.error(`room history: ${result.stderr || `exit ${result.code}`}`, 5);
      return [];
    }
    let raw: unknown;
    try { raw = JSON.parse(result.stdout); } catch { toast.error("room history: JSON parse error", 5); return []; }
    if (!Array.isArray(raw)) { toast.error("room history: expected array", 5); return []; }
    const entries = (raw as unknown[]).map(safeParseHistoryEntry).filter((e): e is NonNullable<typeof e> => e !== null);
    return entries.map(e => entryToEvent(e, roomId));
  } catch (err) {
    toast.error(`room history: ${String(err)}`, 5);
    return [];
  }
}

export async function loadPeerHistory(peerAlias: string, mySessionId: string, myAlias: string, limit = 50): Promise<C2cEvent[]> {
  try {
    const args = ["history", "--json", "--limit", String(limit)];
    if (mySessionId) args.push("--session-id", mySessionId);
    const result = await Command.create("c2c", args).execute();
    if (result.code !== 0) {
      toast.error(`history: ${result.stderr || `exit ${result.code}`}`, 5);
      return [];
    }
    let raw: unknown;
    try { raw = JSON.parse(result.stdout); } catch { toast.error("peer history: JSON parse error", 5); return []; }
    if (!Array.isArray(raw)) { toast.error("peer history: expected array", 5); return []; }
    const entries = (raw as unknown[]).map(safeParseHistoryEntry).filter((e): e is NonNullable<typeof e> => e !== null);
    return entries
      .map(e => entryToEvent(e))
      .filter(e => {
        if (e.event_type !== "message") return false;
        const m = e as { from_alias: string; to_alias: string };
        return (m.from_alias === peerAlias && m.to_alias === myAlias) ||
               (m.from_alias === myAlias && m.to_alias === peerAlias);
      });
  } catch (err) {
    toast.error(`history: ${String(err)}`, 5);
    return [];
  }
}
