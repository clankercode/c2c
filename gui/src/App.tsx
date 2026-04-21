import { useEffect, useRef, useState } from "react";
import { Command, Child } from "@tauri-apps/plugin-shell";
import { C2cEvent } from "./types";
import { EventFeed } from "./EventFeed";
import { ComposeBar } from "./ComposeBar";
import { registerAlias } from "./useSend";
import { loadHistory } from "./useHistory";
import { discoverPeers, discoverRooms } from "./useDiscovery";

const MAX_EVENTS = 1000;
const ALIAS_KEY = "c2c-gui-my-alias";

export function App() {
  const [events, setEvents] = useState<C2cEvent[]>([]);
  const [status, setStatus] = useState<"connecting" | "live" | "error">("connecting");
  const [peers, setPeers] = useState<Set<string>>(new Set());
  const [rooms, setRooms] = useState<Set<string>>(new Set());
  const [myAlias, setMyAlias] = useState(() => localStorage.getItem(ALIAS_KEY) ?? "");
  const [aliasInput, setAliasInput] = useState(() => localStorage.getItem(ALIAS_KEY) ?? "");
  const [aliasStatus, setAliasStatus] = useState<string | null>(null);
  const childRef = useRef<Child | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function startMonitor() {
      try {
        const cmd = Command.create("c2c", [
          "monitor", "--all", "--json", "--drains", "--sweeps",
        ]);

        cmd.stdout.on("data", (line: string) => {
          if (cancelled) return;
          const trimmed = line.trim();
          if (!trimmed) return;
          try {
            const event: C2cEvent = JSON.parse(trimmed);
            setEvents(prev => {
              const next = [...prev, event];
              return next.length > MAX_EVENTS ? next.slice(-MAX_EVENTS) : next;
            });
            setStatus("live");

            if (event.event_type === "peer.alive") {
              const alias = (event as { alias: string }).alias;
              setPeers(prev => new Set([...prev, alias]));
            } else if (event.event_type === "peer.dead") {
              const alias = (event as { alias: string }).alias;
              setPeers(prev => { const s = new Set(prev); s.delete(alias); return s; });
            } else if (event.event_type === "room.join") {
              const room_id = (event as { room_id: string }).room_id;
              setRooms(prev => new Set([...prev, room_id]));
            } else if (event.event_type === "room.leave") {
              // Keep room in list even if it's empty (alias may rejoin)
            }
          } catch {
            // ignore non-JSON lines
          }
        });

        cmd.stderr.on("data", () => { /* suppress */ });
        cmd.on("close", () => { if (!cancelled) setStatus("error"); });
        cmd.on("error", () => { if (!cancelled) setStatus("error"); });

        const child = await cmd.spawn();
        childRef.current = child;
      } catch {
        if (!cancelled) setStatus("error");
      }
    }

    // Seed peers and rooms from local broker before monitor arms.
    Promise.all([discoverPeers(), discoverRooms()]).then(([ps, rs]) => {
      if (cancelled) return;
      setPeers(new Set(ps.filter(p => p.alive).map(p => p.alias)));
      setRooms(new Set(rs.map(r => r.room_id)));
    });

    // Load recent history before starting the live monitor.
    loadHistory(100).then(hist => {
      if (!cancelled && hist.length > 0) {
        setEvents(hist);
      }
      if (!cancelled) startMonitor();
    });

    return () => {
      cancelled = true;
      childRef.current?.kill().catch(() => {});
    };
  }, []);

  async function applyAlias() {
    const a = aliasInput.trim();
    if (!a) return;
    setAliasStatus("registering…");
    const res = await registerAlias(a);
    if (res.ok) {
      setMyAlias(a);
      localStorage.setItem(ALIAS_KEY, a);
      setAliasStatus("✓ registered as " + a);
    } else {
      setAliasStatus("error: " + (res.error ?? "unknown"));
    }
    setTimeout(() => setAliasStatus(null), 3000);
  }

  const statusColor = { connecting: "#f9e2af", live: "#a6e3a1", error: "#f38ba8" }[status];

  return (
    <div style={{
      display: "flex", flexDirection: "column", height: "100vh",
      background: "#1e1e2e", color: "#cdd6f4",
    }}>
      {/* Header */}
      <div style={{
        padding: "6px 16px", background: "#181825",
        borderBottom: "1px solid #313244",
        display: "flex", alignItems: "center", gap: 12,
      }}>
        <span style={{ fontWeight: 700, letterSpacing: 1, fontSize: 14 }}>c2c</span>
        <span style={{ fontSize: 11, color: "#585b70" }}>swarm monitor</span>
        <span style={{ marginLeft: "auto", fontSize: 11, color: statusColor }}>● {status}</span>
        <span style={{ fontSize: 11, color: "#585b70" }}>{events.length} events</span>

        {/* Alias setup */}
        <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
          <input
            value={aliasInput}
            onChange={e => setAliasInput(e.target.value)}
            onKeyDown={e => e.key === "Enter" && applyAlias()}
            placeholder="your alias"
            style={{
              background: "#313244", border: "1px solid #45475a",
              borderRadius: 4, color: "#cdd6f4", padding: "3px 6px",
              fontSize: 12, outline: "none", width: 120,
            }}
          />
          <button
            onClick={applyAlias}
            style={{
              background: "#89b4fa", border: "none", borderRadius: 4,
              color: "#1e1e2e", padding: "3px 8px", fontSize: 11,
              fontWeight: 700, cursor: "pointer",
            }}
          >
            {myAlias ? "re-register" : "register"}
          </button>
          {aliasStatus && (
            <span style={{ fontSize: 11, color: aliasStatus.startsWith("error") ? "#f38ba8" : "#a6e3a1" }}>
              {aliasStatus}
            </span>
          )}
          {myAlias && !aliasStatus && (
            <span style={{ fontSize: 11, color: "#89dceb" }}>you: {myAlias}</span>
          )}
        </div>
      </div>

      {/* Event feed */}
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
        {events.length === 0 ? (
          <div style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", color: "#585b70" }}>
            Waiting for swarm events…
          </div>
        ) : (
          <EventFeed events={events} />
        )}
      </div>

      {/* Compose bar */}
      <ComposeBar
        peers={[...peers]}
        rooms={[...rooms]}
        myAlias={myAlias}
      />
    </div>
  );
}
