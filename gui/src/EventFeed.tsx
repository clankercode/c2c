import { useState } from "react";
import { C2cEvent, MessageEvent } from "./types";

type Filter = "all" | "messages" | "peers" | "rooms";

function eventIcon(e: C2cEvent): string {
  switch (e.event_type) {
    case "message": return "💬";
    case "drain":   return "📤";
    case "sweep":   return "🗑️";
    case "peer.alive": return "🟢";
    case "peer.dead":  return "🔴";
    case "room.join":  return "🚀";
    case "room.leave": return "👋";
    default:           return "•";
  }
}

function eventLabel(e: C2cEvent): string {
  switch (e.event_type) {
    case "message": {
      const m = e as MessageEvent;
      const preview = m.content.slice(0, 120).replace(/\n/g, " ");
      const ellipsis = m.content.length > 120 ? "…" : "";
      return `${m.from_alias} → ${m.to_alias}: ${preview}${ellipsis}`;
    }
    case "drain":        return `${(e as { alias: string }).alias} polled`;
    case "sweep":        return `${(e as { alias: string }).alias} swept`;
    case "peer.alive":   return `${(e as { alias: string }).alias} registered`;
    case "peer.dead":    return `${(e as { alias: string }).alias} gone`;
    case "room.join": {
      const r = e as { alias: string; room_id: string };
      return `${r.alias} → ${r.room_id}`;
    }
    case "room.leave": {
      const r = e as { alias: string; room_id: string };
      return `${r.alias} ← ${r.room_id}`;
    }
    default: return JSON.stringify(e);
  }
}

function eventColor(e: C2cEvent): string {
  switch (e.event_type) {
    case "message":    return "#cdd6f4";
    case "peer.alive": return "#a6e3a1";
    case "peer.dead":  return "#f38ba8";
    case "room.join":  return "#89dceb";
    case "room.leave": return "#fab387";
    default:           return "#585b70";
  }
}

function matchesFilter(e: C2cEvent, filter: Filter): boolean {
  if (filter === "all") return true;
  if (filter === "messages") return e.event_type === "message";
  if (filter === "peers") return e.event_type === "peer.alive" || e.event_type === "peer.dead";
  if (filter === "rooms") return e.event_type === "room.join" || e.event_type === "room.leave";
  return true;
}

function isRoomEvent(e: C2cEvent, roomId: string): boolean {
  if (e.event_type === "message") {
    const m = e as MessageEvent;
    return m.to_alias === roomId || m.from_alias === roomId;
  }
  if (e.event_type === "room.join" || e.event_type === "room.leave") {
    return (e as { room_id: string }).room_id === roomId;
  }
  return false;
}

const FILTER_BTN: React.CSSProperties = {
  background: "transparent",
  border: "1px solid #45475a",
  borderRadius: 4,
  color: "#585b70",
  padding: "2px 8px",
  fontSize: 11,
  cursor: "pointer",
};

const FILTER_BTN_ACTIVE: React.CSSProperties = {
  ...FILTER_BTN,
  background: "#313244",
  color: "#cdd6f4",
  borderColor: "#89b4fa",
};

interface Props {
  events: C2cEvent[];
  selectedRoom?: string | null;
  roomHistoryEvents?: C2cEvent[];
  onClearRoom?: () => void;
}

export function EventFeed({ events, selectedRoom, roomHistoryEvents = [], onClearRoom }: Props) {
  const [filter, setFilter] = useState<Filter>("all");

  let visible: C2cEvent[];
  if (selectedRoom) {
    const liveRoomEvents = events.filter(e => isRoomEvent(e, selectedRoom) && !(e as { _historical?: boolean })._historical);
    const seenKeys = new Set(liveRoomEvents.map(e => `${e.monitor_ts}-${(e as MessageEvent).content ?? ""}`));
    const dedupedHistory = roomHistoryEvents.filter(e => {
      const k = `${e.monitor_ts}-${(e as MessageEvent).content ?? ""}`;
      return !seenKeys.has(k);
    });
    visible = [...dedupedHistory, ...liveRoomEvents].slice().sort(
      (a, b) => parseFloat(b.monitor_ts) - parseFloat(a.monitor_ts)
    );
  } else {
    visible = events.filter(e => matchesFilter(e, filter)).slice().reverse();
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", flex: 1, overflow: "hidden" }}>
      {/* Filter / room bar */}
      <div style={{
        display: "flex", gap: 4, padding: "4px 8px",
        background: "#11111b", borderBottom: "1px solid #1e1e2e",
        alignItems: "center",
      }}>
        {selectedRoom ? (
          <>
            <span style={{ fontSize: 11, color: "#89dceb", fontWeight: 700 }}>🏠 {selectedRoom}</span>
            <button
              onClick={onClearRoom}
              style={{ ...FILTER_BTN, marginLeft: 4 }}
            >
              ✕ all events
            </button>
          </>
        ) : (
          (["all", "messages", "peers", "rooms"] as Filter[]).map(f => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              style={filter === f ? FILTER_BTN_ACTIVE : FILTER_BTN}
            >
              {f}
            </button>
          ))
        )}
        <span style={{ marginLeft: "auto", fontSize: 11, color: "#45475a" }}>
          {visible.length}{!selectedRoom && ` / ${events.length}`}
        </span>
      </div>

      {/* Event list */}
      <div style={{ fontFamily: "monospace", fontSize: "13px", overflowY: "auto", flex: 1 }}>
        {visible.length === 0 ? (
          <div style={{ padding: 16, color: "#45475a" }}>
            {selectedRoom ? `No messages in ${selectedRoom} yet.` : "No events match filter."}
          </div>
        ) : (
          visible.map((e, i) => (
            <div
              key={i}
              style={{
                padding: "3px 8px",
                borderBottom: "1px solid #1e1e2e",
                opacity: (e as { _historical?: boolean })._historical ? 0.65 : 1,
              }}
            >
              <span style={{ color: "#45475a", marginRight: 8, fontSize: 11 }}>
                {new Date(parseFloat(e.monitor_ts) * 1000).toLocaleTimeString()}
              </span>
              <span style={{ marginRight: 6 }}>{eventIcon(e)}</span>
              <span style={{ color: eventColor(e) }}>{eventLabel(e)}</span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
