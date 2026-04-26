import { ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
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

function dedupeAndSort(history: C2cEvent[], live: C2cEvent[], ascending = false): C2cEvent[] {
  const seenKeys = new Set(live.map(e => `${e.monitor_ts}-${(e as MessageEvent).content ?? ""}`));
  const dedupedHistory = history.filter(e => {
    const k = `${e.monitor_ts}-${(e as MessageEvent).content ?? ""}`;
    return !seenKeys.has(k);
  });
  const sign = ascending ? 1 : -1;
  return [...dedupedHistory, ...live].sort(
    (a, b) => sign * (parseFloat(a.monitor_ts) - parseFloat(b.monitor_ts))
  );
}

function renderInlineMarkdown(text: string, keyPrefix: string): ReactNode[] {
  const parts = text.split(/(`[^`]+`|\*\*[^*]+\*\*)/g);
  return parts.filter(part => part.length > 0).map((part, i) => {
    const key = `${keyPrefix}-inline-${i}`;
    if (part.startsWith("`") && part.endsWith("`")) {
      return (
        <code key={key} style={{
          background: "#11111b",
          border: "1px solid #313244",
          borderRadius: 4,
          padding: "0 4px",
          color: "#f9e2af",
          fontFamily: "monospace",
        }}>
          {part.slice(1, -1)}
        </code>
      );
    }
    if (part.startsWith("**") && part.endsWith("**")) {
      return <strong key={key}>{part.slice(2, -2)}</strong>;
    }
    return part;
  });
}

function renderTextBlock(text: string, keyPrefix: string): ReactNode {
  const lines = text.split("\n");
  return (
    <div key={keyPrefix}>
      {lines.map((line, i) => (
        <div key={`${keyPrefix}-line-${i}`} style={{ minHeight: "1em" }}>
          {line ? renderInlineMarkdown(line, `${keyPrefix}-${i}`) : "\u00a0"}
        </div>
      ))}
    </div>
  );
}

function MarkdownMessage({ content }: { content: string }) {
  const nodes: ReactNode[] = [];
  const fenceRe = /```([A-Za-z0-9_-]+)?\n?([\s\S]*?)```/g;
  let cursor = 0;
  let match: RegExpExecArray | null;
  let index = 0;

  while ((match = fenceRe.exec(content)) !== null) {
    if (match.index > cursor) {
      nodes.push(renderTextBlock(content.slice(cursor, match.index), `text-${index++}`));
    }
    const language = match[1];
    nodes.push(
      <pre key={`code-${index++}`} style={{
        background: "#11111b",
        border: "1px solid #313244",
        borderRadius: 6,
        color: "#a6e3a1",
        margin: "6px 0",
        overflowX: "auto",
        padding: "8px 10px",
        whiteSpace: "pre",
      }}>
        <code data-language={language ?? undefined}>{match[2].replace(/\n$/, "")}</code>
      </pre>,
    );
    cursor = fenceRe.lastIndex;
  }

  if (cursor < content.length || nodes.length === 0) {
    nodes.push(renderTextBlock(content.slice(cursor), `text-${index}`));
  }

  return <>{nodes}</>;
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

// Row height estimate for global feed
const GLOBAL_ROW_HEIGHT = 28;
const INITIAL_VIRTUAL_RECT = { height: 600, width: 800 };

interface Props {
  events: C2cEvent[];
  selectedRoom?: string | null;
  selectedPeer?: string | null;
  myAlias?: string;
  focusHistoryEvents?: C2cEvent[];
  onClearFocus?: () => void;
  onPeerClick?: (alias: string) => void;
}

export function EventFeed({ events, selectedRoom, selectedPeer, myAlias = "", focusHistoryEvents = [], onClearFocus, onPeerClick }: Props) {
  const [filter, setFilter] = useState<Filter>("all");
  const [search, setSearch] = useState("");
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const listRef = useRef<HTMLDivElement>(null);
  const prevLenRef = useRef(0);

  // Refs for dynamic row measurement
  const rowRefs = useRef<Map<number, HTMLDivElement>>(new Map());

  function toggleExpand(i: number) {
    setExpanded(prev => {
      const next = new Set(prev);
      if (next.has(i)) next.delete(i); else next.add(i);
      return next;
    });
  }

  const isFocused = !!(selectedRoom || selectedPeer);
  const filteredVisible = useMemo(() => {
    if (selectedRoom) {
      const liveRoomEvents = events.filter(e => isRoomEvent(e, selectedRoom) && !(e as { _historical?: boolean })._historical);
      return dedupeAndSort(focusHistoryEvents, liveRoomEvents, true);
    } else if (selectedPeer) {
      const livePeerEvents = events.filter(e => isPeerEvent(e, selectedPeer, myAlias) && !(e as { _historical?: boolean })._historical);
      return dedupeAndSort(focusHistoryEvents, livePeerEvents, true);
    } else {
      return events.filter(e => matchesFilter(e, filter)).slice().reverse();
    }
  }, [selectedRoom, selectedPeer, events, focusHistoryEvents, myAlias, filter]);

  // Apply search filter (runs every render since search changes frequently)
  const visible = search.trim()
    ? filteredVisible.filter(e => eventLabel(e).toLowerCase().includes(search.trim().toLowerCase()))
    : filteredVisible;

  // Track user scroll position for focused mode
  const isAtBottomRef = useRef(true);

  // Auto-scroll: global feed → top (newest first); focused chat → bottom (oldest first)
  useEffect(() => {
    const el = listRef.current;
    if (!el) return;
    const len = selectedRoom ? events.filter(e => isRoomEvent(e, selectedRoom)).length
              : selectedPeer ? events.filter(e => isPeerEvent(e, selectedPeer, myAlias)).length
              : events.length;
    if (len > prevLenRef.current) {
      if (selectedRoom || selectedPeer) {
        // Focused mode: only auto-scroll if already at bottom
        if (isAtBottomRef.current) {
          el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
        }
      } else {
        el.scrollTo({ top: 0, behavior: "smooth" });
      }
    }
    prevLenRef.current = len;
  }, [events, selectedRoom, selectedPeer, myAlias]);

  // Virtualizer for global feed (fixed-height rows)
  const globalVirtualizer = useVirtualizer({
    count: visible.length,
    getScrollElement: () => listRef.current,
    estimateSize: () => GLOBAL_ROW_HEIGHT,
    initialRect: INITIAL_VIRTUAL_RECT,
    overscan: 10,
  });

  // Dynamic measurement for focused chat bubbles
  const registerRowRef = useCallback((index: number, el: HTMLDivElement | null) => {
    if (el) {
      rowRefs.current.set(index, el);
    } else {
      rowRefs.current.delete(index);
    }
  }, []);

  const estimateSize = useCallback((index: number) => {
    const el = rowRefs.current.get(index);
    if (el) return el.getBoundingClientRect().height + 8; // +8 for padding
    // Heuristic: focused chat bubbles average ~80px, global feed uses GLOBAL_ROW_HEIGHT
    return isFocused ? 80 : GLOBAL_ROW_HEIGHT;
  }, [isFocused]);

  const dynamicVirtualizer = useVirtualizer({
    count: visible.length,
    getScrollElement: () => listRef.current,
    estimateSize,
    initialRect: INITIAL_VIRTUAL_RECT,
    measureElement: (el) => el.getBoundingClientRect().height + 8,
    overscan: 5,
  });

  const virtualizer = isFocused ? dynamicVirtualizer : globalVirtualizer;
  const estimatedRowHeight = isFocused ? 80 : GLOBAL_ROW_HEIGHT;
  const measuredVirtualItems = virtualizer.getVirtualItems();
  const renderedVirtualItems = measuredVirtualItems.length > 0
    ? measuredVirtualItems
    : visible.map((_, index) => ({
      index,
      key: index,
      size: estimatedRowHeight,
      start: index * estimatedRowHeight,
    }));

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

      {/* Virtualized event list */}
      <div
        ref={listRef}
        style={{ fontFamily: "monospace", fontSize: "13px", overflowY: "auto", flex: 1 }}
        onScroll={() => {
          const el = listRef.current;
          if (!el) return;
          if (isFocused) {
            const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50;
            isAtBottomRef.current = atBottom;
          }
        }}
      >
        {visible.length === 0 ? (
          <div style={{ padding: 16, color: "#45475a" }}>
            {focusLabel ? `No messages with ${selectedRoom ?? selectedPeer} yet.` : "No events match filter."}
          </div>
        ) : (
          <div
            style={{
              height: `${virtualizer.getTotalSize()}px`,
              width: "100%",
              position: "relative",
            }}
          >
            {renderedVirtualItems.map(virtualRow => {
              const e = visible[virtualRow.index];
              const i = virtualRow.index;
              const isMsg = e.event_type === "message";
              const m = isMsg ? (e as MessageEvent) : null;
              const isMine = isMsg && m!.from_alias === myAlias;
              const ts = (() => {
                const d = new Date(parseFloat(e.monitor_ts) * 1000);
                const now = new Date();
                return d.toDateString() === now.toDateString()
                  ? d.toLocaleTimeString()
                  : d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " " + d.toLocaleTimeString();
              })();
              const isHistorical = !!(e as { _historical?: boolean })._historical;

              // Focused chat bubble layout
              if (isFocused && isMsg && m) {
                return (
                  <div
                    key={i}
                    data-index={i}
                    ref={(el) => registerRowRef(i, el)}
                    style={{
                      position: "absolute",
                      top: 0,
                      left: 0,
                      width: "100%",
                      transform: `translateY(${virtualRow.start}px)`,
                      padding: "4px 10px",
                      display: "flex",
                      flexDirection: "column",
                      alignItems: isMine ? "flex-end" : "flex-start",
                      opacity: isHistorical ? 0.6 : 1,
                      boxSizing: "border-box",
                    }}
                  >
                    <div style={{ display: "flex", gap: 6, alignItems: "baseline", marginBottom: 2 }}>
                      {!isMine && (
                        <span
                          style={{ fontSize: 11, fontWeight: 700, color: "#89b4fa", cursor: onPeerClick ? "pointer" : "default" }}
                          onClick={() => onPeerClick?.(m.from_alias)}
                          title={onPeerClick ? `DM ${m.from_alias}` : undefined}
                        >
                          {m.from_alias}
                        </span>
                      )}
                      <span style={{ fontSize: 10, color: "#45475a" }}>{ts}</span>
                      {isMine && <span style={{ fontSize: 11, fontWeight: 700, color: "#cba6f7" }}>{m.from_alias}</span>}
                    </div>
                    <div style={{
                      background: isMine ? "#313244" : "#1e1e2e",
                      border: `1px solid ${isMine ? "#45475a" : "#313244"}`,
                      borderRadius: isMine ? "10px 10px 2px 10px" : "10px 10px 10px 2px",
                      padding: "5px 10px",
                      maxWidth: "70%",
                      color: "#cdd6f4",
                      wordBreak: "break-word",
                      fontFamily: "monospace",
                      fontSize: 13,
                    }}>
                      <MarkdownMessage content={m.content} />
                    </div>
                  </div>
                );
              }

              // Global feed compact log line
              const isExpanded = expanded.has(i);
              const isTruncated = isMsg && m!.content.length > 120;
              return (
                <div
                  key={i}
                  data-index={i}
                  ref={(el) => {
                    // Store ref for global feed — fixed height so no measurement needed
                    if (el) rowRefs.current.set(i, el);
                    else rowRefs.current.delete(i);
                  }}
                  onClick={() => isMsg && isTruncated && toggleExpand(i)}
                  style={{
                    position: "absolute",
                    top: 0,
                    left: 0,
                    width: "100%",
                    height: `${virtualRow.size}px`,
                    transform: `translateY(${virtualRow.start}px)`,
                    padding: "3px 8px",
                    borderBottom: "1px solid #1e1e2e",
                    opacity: isHistorical ? 0.65 : 1,
                    cursor: isMsg && isTruncated ? "pointer" : "default",
                    background: isExpanded ? "#1e1e2e" : "transparent",
                    boxSizing: "border-box",
                    display: isExpanded ? "block" : "flex",
                    alignItems: isExpanded ? undefined : "center",
                    overflow: isExpanded ? "visible" : "hidden",
                  }}
                >
                  <span style={{ color: "#45475a", marginRight: 8, fontSize: 11, flexShrink: 0 }}>{ts}</span>
                  <span style={{ marginRight: 6, flexShrink: 0 }}>{eventIcon(e)}</span>
                  <div style={{
                    color: eventColor(e),
                    display: "inline-block",
                    overflow: isExpanded ? "visible" : "hidden",
                    textOverflow: isExpanded ? undefined : "ellipsis",
                    verticalAlign: "top",
                    whiteSpace: isExpanded ? "normal" : "nowrap",
                  }}>
                    {isMsg && m ? (
                      isExpanded ? (
                        <>
                          <span
                            style={{ color: "#89b4fa", cursor: onPeerClick && m.from_alias !== myAlias ? "pointer" : "default" }}
                            onClick={e2 => { e2.stopPropagation(); if (m.from_alias !== myAlias) onPeerClick?.(m.from_alias); }}
                            title={onPeerClick && m.from_alias !== myAlias ? `DM ${m.from_alias}` : undefined}
                          >
                            {m.from_alias}
                          </span>
                          <span style={{ color: "#89b4fa" }}>{" → "}{m.to_alias}: </span>
                          <div style={{ display: "inline-block", verticalAlign: "top" }}>
                            <MarkdownMessage content={m.content} />
                          </div>
                        </>
                      ) : eventLabel(e)
                    ) : eventLabel(e)}
                  </div>
                  {isMsg && isTruncated && !isExpanded && (
                    <span style={{ color: "#45475a", fontSize: 10, marginLeft: 6, flexShrink: 0 }}>▸</span>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
