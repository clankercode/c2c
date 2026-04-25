import { useState, useEffect, useRef } from "react";
import { loadHistory } from "./useHistory";
import { C2cEvent, MessageEvent } from "./types";

interface Props {
  mySessionId: string;
  onClose: () => void;
}

const LOAD_LIMIT = 500;

function isMessage(e: C2cEvent): e is MessageEvent {
  return e.event_type === "message";
}

function formatTs(monitorTs: string): string {
  const epoch = parseFloat(monitorTs);
  if (!isFinite(epoch) || epoch <= 0) return "";
  const d = new Date(epoch * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())} ${d.getDate()}/${d.getMonth() + 1}`;
}

export function ArchivePanel({ mySessionId, onClose }: Props) {
  const [entries, setEntries] = useState<MessageEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState("");
  const [limit, setLimit] = useState(LOAD_LIMIT);
  const [loadingMore, setLoadingMore] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);

  async function fetch(lim: number) {
    const events = await loadHistory(lim, mySessionId || undefined);
    setEntries(events.filter(isMessage) as MessageEvent[]);
  }

  useEffect(() => {
    setLoading(true);
    fetch(limit).finally(() => setLoading(false));
  }, []);

  async function loadMore() {
    const newLimit = limit + LOAD_LIMIT;
    setLoadingMore(true);
    await fetch(newLimit);
    setLimit(newLimit);
    setLoadingMore(false);
  }

  const filterLower = filter.trim().toLowerCase();
  const visible = filterLower
    ? entries.filter(e =>
        e.from_alias.toLowerCase().includes(filterLower) ||
        (e.to_alias ?? "").toLowerCase().includes(filterLower) ||
        (e.room_id ?? "").toLowerCase().includes(filterLower) ||
        e.content.toLowerCase().includes(filterLower)
      )
    : entries;

  return (
    <div style={{
      position: "fixed", inset: 0, zIndex: 50,
      background: "rgba(17,17,27,0.85)",
      display: "flex", alignItems: "center", justifyContent: "center",
    }}
      onClick={e => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div style={{
        background: "#1e1e2e",
        border: "1px solid #313244",
        borderRadius: 8,
        width: "min(760px, 95vw)",
        height: "min(640px, 90vh)",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
      }}>
        {/* Header */}
        <div style={{
          padding: "10px 16px",
          background: "#181825",
          borderBottom: "1px solid #313244",
          display: "flex",
          alignItems: "center",
          gap: 10,
        }}>
          <span style={{ fontWeight: 700, fontSize: 13 }}>📜 Message Archive</span>
          <span style={{ fontSize: 11, color: "#585b70" }}>
            {loading ? "loading…" : `${visible.length} of ${entries.length} messages`}
          </span>
          <input
            value={filter}
            onChange={e => setFilter(e.target.value)}
            placeholder="filter by alias or content…"
            style={{
              marginLeft: "auto",
              background: "#313244",
              border: "1px solid #45475a",
              borderRadius: 4,
              color: "#cdd6f4",
              padding: "3px 8px",
              fontSize: 12,
              outline: "none",
              width: 200,
            }}
          />
          <button
            onClick={onClose}
            style={{
              background: "transparent",
              border: "none",
              color: "#585b70",
              fontSize: 16,
              cursor: "pointer",
              padding: "0 4px",
              lineHeight: 1,
            }}
            title="Close"
          >
            ✕
          </button>
        </div>

        {/* Scroll area */}
        <div ref={scrollRef} style={{ flex: 1, overflowY: "auto", padding: "8px 0" }}>
          {loading ? (
            <div style={{ padding: 24, textAlign: "center", color: "#585b70", fontSize: 12 }}>
              Loading archive…
            </div>
          ) : visible.length === 0 ? (
            <div style={{ padding: 24, textAlign: "center", color: "#45475a", fontSize: 12 }}>
              {filter ? "No messages match filter." : "No archived messages yet."}
            </div>
          ) : (
            <>
              {/* Load more at top */}
              {!filter && entries.length >= limit && (
                <div style={{ textAlign: "center", padding: "4px 0 8px" }}>
                  <button
                    onClick={loadMore}
                    disabled={loadingMore}
                    style={{
                      background: "transparent",
                      border: "1px solid #45475a",
                      borderRadius: 4,
                      color: "#89b4fa",
                      fontSize: 11,
                      padding: "3px 12px",
                      cursor: loadingMore ? "default" : "pointer",
                    }}
                  >
                    {loadingMore ? "loading…" : `load ${LOAD_LIMIT} more older messages`}
                  </button>
                </div>
              )}
              {visible.map((e, i) => (
                <div key={i} style={{
                  padding: "4px 16px",
                  borderBottom: "1px solid #181825",
                  display: "flex",
                  gap: 8,
                  alignItems: "flex-start",
                  fontSize: 12,
                }}>
                  <span style={{ color: "#45475a", fontSize: 10, whiteSpace: "nowrap", paddingTop: 2, minWidth: 70 }}>
                    {formatTs(e.monitor_ts)}
                  </span>
                  <span style={{ color: "#cba6f7", fontWeight: 600, whiteSpace: "nowrap", minWidth: 90 }}>
                    {e.from_alias}
                  </span>
                  <span style={{ color: "#585b70", fontSize: 10, whiteSpace: "nowrap", paddingTop: 2 }}>
                    → {e.room_id ? `🏠 ${e.room_id}` : `👤 ${e.to_alias ?? "?"}`}
                  </span>
                  <span style={{
                    color: "#cdd6f4",
                    flex: 1,
                    wordBreak: "break-word",
                    whiteSpace: "pre-wrap",
                  }}>
                    {e.content}
                  </span>
                </div>
              ))}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
