import { C2cEvent, MessageEvent } from "./types";

/**
 * Full-text haystack for an event. Message content is included in full
 * (not the 120-char UI preview), so search finds tokens deep in a body.
 */
export function eventSearchHaystack(e: C2cEvent): string {
  switch (e.event_type) {
    case "message": {
      const m = e as MessageEvent;
      return [m.from_alias, m.to_alias, m.content, m.room_id ?? ""].join(" ");
    }
    case "drain":
    case "sweep":
    case "peer.alive":
    case "peer.dead":
      return `${e.event_type} ${(e as { alias: string }).alias}`;
    case "room.join":
    case "room.leave": {
      const r = e as { alias: string; room_id: string };
      return `${e.event_type} ${r.alias} ${r.room_id}`;
    }
    default:
      return `${e.event_type} ${JSON.stringify(e)}`;
  }
}

/** Case-insensitive substring match over {@link eventSearchHaystack}. Empty query matches all. */
export function matchesSearch(e: C2cEvent, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return eventSearchHaystack(e).toLowerCase().includes(q);
}
