import { Command } from "@tauri-apps/plugin-shell";
import { C2cEvent } from "./types";

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

export async function loadHistory(limit = 100): Promise<C2cEvent[]> {
  try {
    const result = await Command.create("c2c", [
      "history", "--json", "--limit", String(limit),
    ]).execute();
    if (result.code !== 0) return [];
    const entries: HistoryEntry[] = JSON.parse(result.stdout);
    return entries.map(e => entryToEvent(e));
  } catch {
    return [];
  }
}

export async function loadRoomHistory(roomId: string, limit = 50): Promise<C2cEvent[]> {
  try {
    const result = await Command.create("c2c", [
      "room", "history", roomId, "--json", "--limit", String(limit),
    ]).execute();
    if (result.code !== 0) return [];
    const entries: HistoryEntry[] = JSON.parse(result.stdout);
    return entries.map(e => entryToEvent(e, roomId));
  } catch {
    return [];
  }
}

export async function loadPeerHistory(peerAlias: string, myAlias: string, limit = 50): Promise<C2cEvent[]> {
  try {
    const result = await Command.create("c2c", [
      "history", "--json", "--limit", String(limit),
    ]).execute();
    if (result.code !== 0) return [];
    const entries: HistoryEntry[] = JSON.parse(result.stdout);
    return entries
      .map(e => entryToEvent(e))
      .filter(e => {
        if (e.event_type !== "message") return false;
        const m = e as { from_alias: string; to_alias: string };
        return (m.from_alias === peerAlias && m.to_alias === myAlias) ||
               (m.from_alias === myAlias && m.to_alias === peerAlias);
      });
  } catch {
    return [];
  }
}
