import { useEffect, useRef, useState } from "react";
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

function isPeerEvent(e: C2cEvent, peer: string, myAlias: string): boolean {
  if (e.event_type !== "message") return false;
  const m = e as MessageEvent;
  return (m.from_alias === peer && m.to_alias === myAlias) ||
         (m.from_alias === myAlias && m.to_alias === peer);
}

function dedupeAndSort(history: C2cEvent[], live: C2cEvent[]): C2cEvent[] {
  const seenKeys = new Set(live.map(e => `${e.monitor_ts}-${(e as MessageEvent).content ?? ""}`));
  const dedupedHistory = history.filter(e => {
    const k = `${e.monitor_ts}-${(e as MessageEvent).content ?? ""}`;
    return !seenKeys.has(k);
  });
  return [...dedupedHistory, ...live].sort(
    (a, b) => parseFloat(b.monitor_ts) - parseFloat(a.monitor_ts)
  );
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
  selectedPeer?: string | null;
  myAlias?: string;
  focusHistoryEvents?: C2cEvent[];
  onClearFocus?: () => void;
}

export function EventFeed({ events, selectedRoom, selectedPeer, myAlias = "", focusHistoryEvents = [], onClearFocus }: Props) {
  const [filter, setFilter] = useState<Filter>("all");
  const [search, setSearch] = useState("");
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const listRef = useRef<HTMLDivElement>(null);
  const prevLenRef = useRef(0);

  function toggleExpand(i: number) {
    setExpanded(prev => {
      const next = new Set(prev);
      if (next.has(i)) next.delete(i); else next.add(i);
      return next;
    });
  }

  let visible: C2cEvent[];
  if (selectedRoom) {
    const liveRoomEvents = events.filter(e => isRoomEvent(e, selectedRoom) && !(e as { _historical?: boolean })._historical);
    visible = dedupeAndSort(focusHistoryEvents, liveRoomEvents);
  } else if (selectedPeer) {
    const livePeerEvents = events.filter(e => isPeerEvent(e, selectedPeer, myAlias) && !(e as { _historical?: boolean })._historical);
    visible = dedupeAndSort(focusHistoryEvents, livePeerEvents);
  } else {
    visible = events.filter(e => matchesFilter(e, filter)).slice().reverse();
  }

  // Apply search filter across all modes
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    visible = visible.filter(e => eventLabel(e).toLowerCase().includes(q));
  }

  // Auto-scroll to top when new live events arrive (global feed is newest-first)
  useEffect(() => {
    if (!selectedRoom && !selectedPeer && events.length > prevLenRef.current) {
      listRef.current?.scrollTo({ top: 0, behavior: "smooth" });
    }
    prevLenRef.current = events.length;
  }, [events.length, selectedRoom, selectedPeer]);

  const focusLabel = selectedRoom ? `🏠 ${selectedRoom}` : selectedPeer ? `👤 ${selectedPeer}` : null;

  return (
    <div style={{ display: "flex", flexDirection: "column", flex: 1, overflow: "hidden" }}>
      {/* Filter / focus bar */}
      <div style={{
        display: "flex", gap: 4, padding: "4px 8px",
        background: "#11111b", borderBottom: "1px solid #1e1e2e",
        alignItems: "center",
      }}>
        {focusLabel ? (
          <>
            <span style={{ fontSize: 11, color: selectedRoom ? "#89dceb" : "#cba6f7", fontWeight: 700 }}>
              {focusLabel}
            </span>
            <button onClick={onClearFocus} style={{ ...FILTER_BTN, marginLeft: 4 }}>
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
        <input
          value={search}
          onChange={e => setSearch(e.target.value)}
          placeholder="search…"
          style={{
            marginLeft: "auto",
            background: "#1e1e2e",
            border: "1px solid #313244",
            borderRadius: 4,
            color: "#cdd6f4",
            padding: "1px 6px",
            fontSize: 11,
            outline: "none",
            width: 100,
          }}
        />
        <span style={{ fontSize: 11, color: "#45475a", flexShrink: 0 }}>
          {visible.length}{!focusLabel && !search && ` / ${events.length}`}
        </span>
      </div>

      {/* Event list — newest on top in all modes */}
      <div ref={listRef} style={{ fontFamily: "monospace", fontSize: "13px", overflowY: "auto", flex: 1 }}>
        {visible.length === 0 ? (
          <div style={{ padding: 16, color: "#45475a" }}>
            {focusLabel ? `No messages with ${selectedRoom ?? selectedPeer} yet.` : "No events match filter."}
          </div>
        ) : (
          visible.map((e, i) => {
            const isMsg = e.event_type === "message";
            const isExpanded = expanded.has(i);
            const m = isMsg ? (e as MessageEvent) : null;
            const isTruncated = isMsg && m!.content.length > 120;
            return (
              <div
                key={i}
                onClick={() => isMsg && isTruncated && toggleExpand(i)}
                style={{
                  padding: "3px 8px",
                  borderBottom: "1px solid #1e1e2e",
                  opacity: (e as { _historical?: boolean })._historical ? 0.65 : 1,
                  cursor: isMsg && isTruncated ? "pointer" : "default",
                  background: isExpanded ? "#1e1e2e" : "transparent",
                }}
              >
                <span style={{ color: "#45475a", marginRight: 8, fontSize: 11 }}>
                  {(() => {
                    const d = new Date(parseFloat(e.monitor_ts) * 1000);
                    const now = new Date();
                    const sameDay = d.toDateString() === now.toDateString();
                    return sameDay
                      ? d.toLocaleTimeString()
                      : d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " " + d.toLocaleTimeString();
                  })()}
                </span>
                <span style={{ marginRight: 6 }}>{eventIcon(e)}</span>
                <span style={{ color: eventColor(e) }}>
                  {isMsg && m ? (
                    isExpanded ? (
                      <>
                        <span style={{ color: "#89b4fa" }}>{m.from_alias} → {m.to_alias}: </span>
                        <span style={{ whiteSpace: "pre-wrap" }}>{m.content}</span>
                      </>
                    ) : (
                      eventLabel(e)
                    )
                  ) : (
                    eventLabel(e)
                  )}
                </span>
                {isMsg && isTruncated && !isExpanded && (
                  <span style={{ color: "#45475a", fontSize: 10, marginLeft: 6 }}>▸</span>
                )}
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
