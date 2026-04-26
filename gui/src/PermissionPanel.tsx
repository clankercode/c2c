import { useEffect, useRef, useState } from "react";
import { C2cEvent, MessageEvent } from "./types";
import {
  PendingPermission,
  PermissionHistoryEntry,
  parsePermissionMessage,
  isExpired,
  approvePermission,
  denyPermission,
} from "./usePermissions";

interface Props {
  events: C2cEvent[];
  myAlias: string;
  mySessionId: string;
}

// Simple badge-style count in the header area
function PermissionBadge({ count }: { count: number }) {
  if (count === 0) return null;
  return (
    <span
      title={`${count} pending permission${count === 1 ? "" : "s"}`}
      style={{
        background: "#f9e2af",
        color: "#11111b",
        borderRadius: 10,
        padding: "1px 6px",
        fontSize: 10,
        fontWeight: 700,
        cursor: "pointer",
      }}
    >
      {count} permission{count !== 1 ? "s" : ""}
    </span>
  );
}

function PermissionRow({
  perm,
  onApprove,
  onDeny,
  now,
}: {
  perm: PendingPermission;
  onApprove: (p: PendingPermission) => void;
  onDeny: (p: PendingPermission) => void;
  now: number;
}) {
  const remaining = Math.max(0, perm.expiresAt - now);
  const percent = Math.min(100, (remaining / 300) * 100); // 300 = 5 min TTL
  const expired = remaining <= 0;
  const color = expired ? "#f38ba8" : remaining < 60 ? "#f9e2af" : "#a6e3a1";

  return (
    <div
      style={{
        background: "#181825",
        border: `1px solid ${expired ? "#f38ba8" : "#313244"}`,
        borderRadius: 8,
        padding: "8px 12px",
        display: "flex",
        flexDirection: "column",
        gap: 6,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span
          style={{
            fontSize: 10,
            fontWeight: 700,
            textTransform: "uppercase",
            letterSpacing: 1,
            color: perm.kind === "permission" ? "#cba6f7" : "#89dceb",
          }}
        >
          {perm.kind}
        </span>
        <span style={{ fontSize: 12, color: "#cdd6f4", fontWeight: 600 }}>
          from {perm.fromAlias}
        </span>
        <span style={{ marginLeft: "auto", fontSize: 11, color }}>
          {expired
            ? "expired"
            : remaining < 60
            ? `${remaining.toFixed(0)}s left`
            : `${(remaining / 60).toFixed(1)}m left`}
        </span>
      </div>

      {/* TTL bar */}
      <div
        style={{
          height: 3,
          background: "#313244",
          borderRadius: 2,
          overflow: "hidden",
        }}
      >
        <div
          style={{
            height: "100%",
            width: `${percent}%`,
            background: color,
            transition: "width 1s linear, background 0.3s",
          }}
        />
      </div>

      {!expired && (
        <div style={{ display: "flex", gap: 6, marginTop: 2 }}>
          <button
            onClick={() => onApprove(perm)}
            style={{
              background: "#a6e3a1",
              border: "none",
              borderRadius: 4,
              color: "#11111b",
              padding: "4px 12px",
              fontSize: 11,
              fontWeight: 700,
              cursor: "pointer",
            }}
          >
            approve
          </button>
          <button
            onClick={() => onDeny(perm)}
            style={{
              background: "transparent",
              border: "1px solid #f38ba8",
              borderRadius: 4,
              color: "#f38ba8",
              padding: "4px 12px",
              fontSize: 11,
              fontWeight: 700,
              cursor: "pointer",
            }}
          >
            deny
          </button>
        </div>
      )}
    </div>
  );
}

function HistoryRow({ entry }: { entry: PermissionHistoryEntry }) {
  const color =
    entry.decision === "approved"
      ? "#a6e3a1"
      : entry.decision === "denied"
      ? "#f38ba8"
      : "#f9e2af";
  const date = new Date(entry.ts * 1000).toLocaleTimeString();
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 8,
        padding: "4px 0",
        borderBottom: "1px solid #313244",
      }}
    >
      <span
        style={{
          fontSize: 10,
          fontWeight: 700,
          textTransform: "uppercase",
          letterSpacing: 1,
          color,
          minWidth: 64,
        }}
      >
        {entry.decision}
      </span>
      <span style={{ fontSize: 11, color: "#cdd6f4" }}>
        {entry.kind} from {entry.fromAlias}
      </span>
      <span style={{ marginLeft: "auto", fontSize: 10, color: "#585b70" }}>
        {date}
      </span>
    </div>
  );
}

export function PermissionPanel({ events, myAlias, mySessionId }: Props) {
  const [pending, setPending] = useState<PendingPermission[]>([]);
  const [history, setHistory] = useState<PermissionHistoryEntry[]>([]);
  const [expanded, setExpanded] = useState(false);
  const [tab, setTab] = useState<"pending" | "history">("pending");
  const [now, setNow] = useState(() => Date.now() / 1000);
  const processingRef = useRef<Set<string>>(new Set());

  // Tick every second for countdown
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now() / 1000), 1000);
    return () => clearInterval(id);
  }, []);

  // Parse incoming events for permission messages addressed to me
  useEffect(() => {
    const myEvents = events.filter(
      (e): e is MessageEvent =>
        e.event_type === "message" &&
        (e as MessageEvent).to_alias === myAlias &&
        !processingRef.current.has((e as MessageEvent).content)
    );

    for (const event of myEvents) {
      const msg = event as MessageEvent;
      const content = msg.content ?? "";
      const ts = parseFloat(msg.ts ?? msg.monitor_ts);
      const perm = parsePermissionMessage(content, msg.from_alias, ts);
      if (perm && !pending.find((p) => p.permId === perm.permId)) {
        setPending((prev) => [...prev, perm]);
        // Mark as processing to avoid duplicates
        processingRef.current.add(content);
      }
    }
  }, [events, myAlias]);

  // Auto-expire: move expired to history
  useEffect(() => {
    const expired = pending.filter(isExpired);
    if (expired.length === 0) return;
    setHistory((prev) => [
      ...expired.map((p) => ({
        permId: p.permId,
        kind: p.kind,
        fromAlias: p.fromAlias,
        content: p.content,
        decision: "expired" as const,
        ts: p.expiresAt,
      })),
      ...prev,
    ]);
    setPending((prev) => prev.filter((p) => !isExpired(p)));
  }, [pending, now]);

  async function handleApprove(perm: PendingPermission) {
    setPending((prev) => prev.filter((p) => p.permId !== perm.permId));
    const res = await approvePermission(perm, myAlias, mySessionId);
    if (res.ok) {
      setHistory((prev) => [
        {
          permId: perm.permId,
          kind: perm.kind,
          fromAlias: perm.fromAlias,
          content: perm.content,
          decision: "approved",
          ts: Date.now() / 1000,
        },
        ...prev,
      ]);
    }
  }

  async function handleDeny(perm: PendingPermission) {
    setPending((prev) => prev.filter((p) => p.permId !== perm.permId));
    const res = await denyPermission(perm, myAlias);
    if (res.ok) {
      setHistory((prev) => [
        {
          permId: perm.permId,
          kind: perm.kind,
          fromAlias: perm.fromAlias,
          content: perm.content,
          decision: "denied",
          ts: Date.now() / 1000,
        },
        ...prev,
      ]);
    }
  }

  const badge = <PermissionBadge count={pending.length} />;

  if (pending.length === 0 && !expanded) {
    return (
      <div
        style={{
          position: "fixed",
          bottom: 12,
          right: 12,
          zIndex: 40,
        }}
      >
        {badge}
      </div>
    );
  }

  return (
    <div
      style={{
        position: "fixed",
        bottom: 12,
        right: 12,
        zIndex: 40,
        width: 360,
      }}
    >
      {/* Toggle header */}
      <button
        onClick={() => setExpanded((v) => !v)}
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          width: "100%",
          background: "#181825",
          border: `1px solid ${pending.length > 0 ? "#f9e2af" : "#313244"}`,
          borderRadius: expanded ? "8px 8px 0 0" : 8,
          padding: "6px 12px",
          cursor: "pointer",
          color: "#cdd6f4",
        }}
      >
        <span style={{ fontSize: 12, fontWeight: 700 }}>
          Permissions
          {pending.length > 0 && (
            <span style={{ color: "#f9e2af", marginLeft: 6 }}>
              ({pending.length} pending)
            </span>
          )}
        </span>
        <span style={{ marginLeft: "auto", fontSize: 10, color: "#585b70" }}>
          {expanded ? "▼" : "▲"}
        </span>
      </button>

      {expanded && (
        <div
          style={{
            background: "#181825",
            border: "1px solid #313244",
            borderTop: "none",
            borderRadius: "0 0 8px 8px",
            overflow: "hidden",
          }}
        >
          {/* Tab switcher */}
          <div
            style={{
              display: "flex",
              borderBottom: "1px solid #313244",
            }}
          >
            {(["pending", "history"] as const).map((t) => (
              <button
                key={t}
                onClick={() => setTab(t)}
                style={{
                  flex: 1,
                  padding: "6px 0",
                  background: "transparent",
                  border: "none",
                  borderBottom: tab === t ? "2px solid #89b4fa" : "2px solid transparent",
                  color: tab === t ? "#cdd6f4" : "#585b70",
                  fontSize: 11,
                  fontWeight: 700,
                  cursor: "pointer",
                  textTransform: "capitalize",
                }}
              >
                {t}
                {t === "pending" && pending.length > 0 && (
                  <span style={{ color: "#f9e2af", marginLeft: 4 }}>
                    ({pending.length})
                  </span>
                )}
                {t === "history" && history.length > 0 && (
                  <span style={{ color: "#585b70", marginLeft: 4 }}>
                    ({history.length})
                  </span>
                )}
              </button>
            ))}
          </div>

          {/* Content */}
          <div style={{ maxHeight: 320, overflowY: "auto", padding: 8 }}>
            {tab === "pending" && (
              <>
                {pending.length === 0 ? (
                  <div
                    style={{
                      textAlign: "center",
                      color: "#585b70",
                      fontSize: 12,
                      padding: "24px 0",
                    }}
                  >
                    No pending permissions
                  </div>
                ) : (
                  <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                    {pending.map((p) => (
                      <PermissionRow
                        key={p.permId}
                        perm={p}
                        now={now}
                        onApprove={handleApprove}
                        onDeny={handleDeny}
                      />
                    ))}
                  </div>
                )}
              </>
            )}
            {tab === "history" && (
              <>
                {history.length === 0 ? (
                  <div
                    style={{
                      textAlign: "center",
                      color: "#585b70",
                      fontSize: 12,
                      padding: "24px 0",
                    }}
                  >
                    No permission history
                  </div>
                ) : (
                  <div>
                    {history.map((h) => (
                      <HistoryRow key={h.permId + h.ts} entry={h} />
                    ))}
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
