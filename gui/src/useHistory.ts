import { Command } from "@tauri-apps/plugin-shell";
import { C2cEvent } from "./types";

interface HistoryEntry {
  drained_at: number;
  from_alias: string;
  to_alias: string;
  content: string;
}

export async function loadHistory(limit = 100): Promise<C2cEvent[]> {
  try {
    const result = await Command.create("c2c", [
      "history", "--json", "--limit", String(limit),
    ]).execute();
    if (result.code !== 0) return [];
    const entries: HistoryEntry[] = JSON.parse(result.stdout);
    const now = Date.now() / 1000;
    return entries.map(e => ({
      event_type: "message" as const,
      monitor_ts: String(e.drained_at ?? now),
      from_alias: e.from_alias ?? "",
      to_alias: e.to_alias ?? "",
      content: e.content ?? "",
      ts: e.drained_at ? new Date(e.drained_at * 1000).toISOString() : undefined,
      _historical: true,
    }));
  } catch {
    return [];
  }
}
