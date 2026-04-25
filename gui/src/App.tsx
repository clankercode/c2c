import { useEffect, useRef, useState } from "react";
import { Command, Child } from "@tauri-apps/plugin-shell";
import { C2cEvent } from "./types";
import { EventFeed } from "./EventFeed";
import { ComposeBar } from "./ComposeBar";
import { Sidebar } from "./Sidebar";
import { registerAlias, joinRoom } from "./useSend";
import { loadHistory, loadRoomHistory, loadPeerHistory, pollInbox } from "./useHistory";
import { discoverPeers, discoverRooms, fetchHealth, HealthInfo } from "./useDiscovery";
import { WelcomeWizard } from "./components/WelcomeWizard";

const MAX_EVENTS = 1000;
const ALIAS_KEY = "c2c-gui-my-alias";
const SESSION_ID_KEY = "c2c-gui-my-session-id";

function generateSessionId(): string {
  return "gui-" + Math.random().toString(36).slice(2, 11) + "-" + Math.random().toString(36).slice(2, 11);
}

export function App() {
  const [events, setEvents] = useState<C2cEvent[]>([]);
  const [status, setStatus] = useState<"connecting" | "live" | "error">("connecting");
  const [peers, setPeers] = useState<Set<string>>(new Set());
  const [rooms, setRooms] = useState<Set<string>>(new Set());
  const [roomMembers, setRoomMembers] = useState<Map<string, Set<string>>>(new Map());
  const [composeTo, setComposeTo] = useState("");
  const [composeIsRoom, setComposeIsRoom] = useState(false);
  const [selectedRoom, setSelectedRoom] = useState<string | null>(null);
  const [selectedPeer, setSelectedPeer] = useState<string | null>(null);
  const [focusHistoryEvents, setFocusHistoryEvents] = useState<C2cEvent[]>([]);
  const [unreadRooms, setUnreadRooms] = useState<Set<string>>(new Set());
  const [unreadPeers, setUnreadPeers] = useState<Set<string>>(new Set());
  const selectedRoomRef = useRef<string | null>(null);
  const selectedPeerRef = useRef<string | null>(null);
  const myAliasRef = useRef<string>("");
  const mySessionIdRef = useRef<string>("");
  const [myAlias, setMyAlias] = useState(() => localStorage.getItem(ALIAS_KEY) ?? "human");
  const [mySessionId, setMySessionId] = useState<string>(() => localStorage.getItem(SESSION_ID_KEY) ?? "");
  const [aliasInput, setAliasInput] = useState(() => localStorage.getItem(ALIAS_KEY) ?? "human");
  const [showWizard, setShowWizard] = useState(() => !localStorage.getItem(ALIAS_KEY));
  const [aliasStatus, setAliasStatus] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [health, setHealth] = useState<HealthInfo | null>(null);
  const childRef = useRef<Child | null>(null);
  const cancelledRef = useRef(false);
  const reconnectAttemptRef = useRef(0);
  const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  async function startMonitor() {
    setStatus("connecting");
    try {
      const cmd = Command.create("c2c", [
        "monitor", "--all", "--json", "--drains", "--sweeps",
      ]);

      cmd.stdout.on("data", (line: string) => {
        if (cancelledRef.current) return;
        const trimmed = line.trim();
        if (!trimmed) return;
        try {
          const event: C2cEvent = JSON.parse(trimmed);
          if (event.event_type === "monitor.ready") {
            reconnectAttemptRef.current = 0;
            setStatus("live");
            return;
          }
          setEvents(prev => {
            const next = [...prev, event];
            return next.length > MAX_EVENTS ? next.slice(-MAX_EVENTS) : next;
          });
          reconnectAttemptRef.current = 0;
          setStatus("live");

          if (event.event_type === "peer.alive") {
            const alias = (event as { alias: string }).alias;
            setPeers(prev => new Set([...prev, alias]));
          } else if (event.event_type === "peer.dead") {
            const alias = (event as { alias: string }).alias;
            setPeers(prev => { const s = new Set(prev); s.delete(alias); return s; });
          } else if (event.event_type === "room.join") {
            const room_id = (event as { room_id: string; alias: string }).room_id;
            const alias = (event as { room_id: string; alias: string }).alias;
            setRooms(prev => new Set([...prev, room_id]));
            setRoomMembers(prev => {
              const next = new Map(prev);
              const members = new Set(next.get(room_id) ?? []);
              members.add(alias);
              next.set(room_id, members);
              return next;
            });
          } else if (event.event_type === "room.leave") {
            const room_id = (event as { room_id: string; alias: string }).room_id;
            const alias = (event as { room_id: string; alias: string }).alias;
            setRoomMembers(prev => {
              const next = new Map(prev);
              const members = next.get(room_id);
              if (members) {
                members.delete(alias);
                if (members.size === 0) {
                  next.delete(room_id);
                }
              }
              return next;
            });
          } else if (event.event_type === "message") {
            const m = event as { to_alias: string; from_alias: string; content?: string };
            const me = myAliasRef.current;
            if (m.to_alias === me || m.from_alias === me) {
              const peer = m.from_alias === me ? m.to_alias : m.from_alias;
              if (selectedPeerRef.current !== peer) {
                setUnreadPeers(prev => new Set([...prev, peer]));
                if (m.from_alias !== me && Notification.permission === "granted") {
                  new Notification(`DM from ${m.from_alias}`, {
                    body: (m.content ?? "").slice(0, 80),
                    tag: `dm-${m.from_alias}`,
                  });
                }
              }
            } else {
              const roomId = m.to_alias;
              if (selectedRoomRef.current !== roomId) {
                setUnreadRooms(prev => new Set([...prev, roomId]));
              }
            }
          }
        } catch {
          // ignore non-JSON lines
        }
      });

      cmd.stderr.on("data", () => { /* suppress */ });
      function scheduleReconnect() {
        if (cancelledRef.current) return;
        setStatus("error");
        const attempt = ++reconnectAttemptRef.current;
        const delay = Math.min(3000 * Math.pow(2, attempt - 1), 30000);
        reconnectTimerRef.current = setTimeout(() => {
          if (!cancelledRef.current) startMonitor();
        }, delay);
      }

      cmd.on("close", scheduleReconnect);
      cmd.on("error", scheduleReconnect);

      const child = await cmd.spawn();
      childRef.current = child;
    } catch {
      if (!cancelledRef.current) {
        setStatus("error");
        const attempt = ++reconnectAttemptRef.current;
        const delay = Math.min(3000 * Math.pow(2, attempt - 1), 30000);
        reconnectTimerRef.current = setTimeout(() => {
          if (!cancelledRef.current) startMonitor();
        }, delay);
      }
    }
  }

  async function handleReconnect() {
    if (reconnectTimerRef.current) {
      clearTimeout(reconnectTimerRef.current);
      reconnectTimerRef.current = null;
    }
    reconnectAttemptRef.current = 0;
    childRef.current?.kill().catch(() => {});
    childRef.current = null;
    await startMonitor();
  }

  async function refreshBroker() {
    setRefreshing(true);
    try {
      const [ps, rs, h] = await Promise.all([discoverPeers(), discoverRooms(), fetchHealth()]);
      if (h) setHealth(h);
      setPeers(prev => {
        const alive = new Set(ps.filter(p => p.alive).map(p => p.alias));
        const dead = new Set(ps.filter(p => !p.alive).map(p => p.alias));
        const merged = new Set([...prev, ...alive]);
        dead.forEach(a => merged.delete(a));
        return merged;
      });
      setRooms(prev => new Set([...prev, ...rs.map(r => r.room_id)]));
      setRoomMembers(prev => {
        const next = new Map(prev);
        rs.forEach(r => { if (r.alive_members) next.set(r.room_id, new Set(r.alive_members)); });
        return next;
      });
    } finally {
      setRefreshing(false);
    }
  }

  useEffect(() => {
    cancelledRef.current = false;

    // Request notification permission for desktop alerts on new DMs
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission().catch(() => {});
    }

    // Seed peers and rooms from local broker before monitor arms.
    refreshBroker();

    // Periodic re-discovery: picks up peers that registered after the initial
    // seed but before/between monitor events (e.g. restarts, alias changes).
    const refreshTimer = setInterval(() => refreshBroker(), 60_000);

    // If we have a stored alias, ensure we're joined to the default social room.
    const storedAlias = localStorage.getItem(ALIAS_KEY) ?? undefined;
    const storedSessionId = localStorage.getItem(SESSION_ID_KEY) ?? undefined;
    if (storedAlias) {
      joinRoom("swarm-lounge", storedAlias).then(res => {
        if (res.ok) setRooms(prev => new Set([...prev, "swarm-lounge"]));
      });
    }
    Promise.all([
      loadHistory(100, storedSessionId),
      storedSessionId ? pollInbox(storedSessionId) : Promise.resolve([] as import("./types").C2cEvent[]),
    ]).then(([hist, inbox]) => {
      if (cancelledRef.current) return;
      const combined = [...hist, ...inbox].sort(
        (a, b) => parseFloat(a.monitor_ts) - parseFloat(b.monitor_ts)
      );
      if (combined.length > 0) setEvents(combined);
      startMonitor();
    });

    return () => {
      cancelledRef.current = true;
      clearInterval(refreshTimer);
      if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
      childRef.current?.kill().catch(() => {});
    };
  }, []);

  // Keep refs in sync so the event handler closure sees current values
  useEffect(() => { selectedRoomRef.current = selectedRoom; }, [selectedRoom]);
  useEffect(() => { selectedPeerRef.current = selectedPeer; }, [selectedPeer]);
  useEffect(() => { myAliasRef.current = myAlias; }, [myAlias]);
  useEffect(() => { mySessionIdRef.current = mySessionId; }, [mySessionId]);

  async function applyAlias() {
    const a = aliasInput.trim();
    if (!a) return;
    setAliasStatus("registering…");
    let sid = localStorage.getItem(SESSION_ID_KEY) ?? generateSessionId();
    const res = await registerAlias(a, sid);
    if (res.ok) {
      setMyAlias(a);
      setMySessionId(sid);
      localStorage.setItem(ALIAS_KEY, a);
      localStorage.setItem(SESSION_ID_KEY, sid);
      setAliasStatus("✓ registered as " + a);
    } else {
      setAliasStatus("error: " + (res.error ?? "unknown"));
    }
    setTimeout(() => setAliasStatus(null), 3000);
  }

  const statusColor = { connecting: "#f9e2af", live: "#a6e3a1", error: "#f38ba8" }[status];

  function handleWizardComplete(alias: string, sessionId: string) {
    setMyAlias(alias);
    setMySessionId(sessionId);
    setAliasInput(alias);
    localStorage.setItem(ALIAS_KEY, alias);
    localStorage.setItem(SESSION_ID_KEY, sessionId);
    setShowWizard(false);
    // Auto-join the default social room on first registration
    joinRoom("swarm-lounge", alias).then(res => {
      if (res.ok) setRooms(prev => new Set([...prev, "swarm-lounge"]));
    });
  }

  return (
    <div style={{
      display: "flex", flexDirection: "column", height: "100vh",
      background: "#1e1e2e", color: "#cdd6f4",
    }}>
      <WelcomeWizard open={showWizard} onComplete={handleWizardComplete} onSkip={() => setShowWizard(false)} />
      {/* Header */}
      <div style={{
        padding: "6px 16px", background: "#181825",
        borderBottom: "1px solid #313244",
        display: "flex", alignItems: "center", gap: 12,
      }}>
        <span style={{ fontWeight: 700, letterSpacing: 1, fontSize: 14 }}>c2c</span>
        <span style={{ fontSize: 11, color: "#585b70" }}>swarm monitor</span>
        {status === "error" ? (
          <button
            onClick={handleReconnect}
            title="Auto-reconnecting — click to retry now"
            style={{
              marginLeft: "auto", background: "transparent", border: "1px solid #f38ba8",
              borderRadius: 4, color: "#f38ba8", padding: "2px 6px",
              fontSize: 11, cursor: "pointer",
            }}
          >
            ● error · retry now
          </button>
        ) : (
          <span style={{ marginLeft: "auto", fontSize: 11, color: statusColor }}>● {status}</span>
        )}
        {(unreadRooms.size + unreadPeers.size) > 0 && (
          <span style={{
            background: "#f38ba8", color: "#1e1e2e",
            borderRadius: 10, padding: "1px 6px", fontSize: 10, fontWeight: 700,
          }}>
            {unreadRooms.size + unreadPeers.size} unread
          </span>
        )}
        <span style={{ fontSize: 11, color: "#585b70" }}>{events.length} events</span>
        {health && (
          <>
            <span style={{ fontSize: 11, color: "#585b70" }}>
              {health.alive}/{health.registrations} peers · {health.rooms} rooms
            </span>
            {health.relay && (
              <span
                title={health.relay.message}
                style={{
                  fontSize: 11,
                  color: health.relay.status === "green" ? "#a6e3a1"
                       : health.relay.status === "yellow" ? "#f9e2af"
                       : "#f38ba8",
                }}
              >
                ⬡ relay {health.relay.status}
              </span>
            )}
          </>
        )}
        <button
          onClick={() => refreshBroker()}
          disabled={refreshing}
          title="Refresh peer/room list from broker"
          style={{
            background: "transparent", border: "1px solid #45475a",
            borderRadius: 4, color: refreshing ? "#45475a" : "#89dceb",
            padding: "2px 6px", fontSize: 11, cursor: "pointer",
          }}
        >
          {refreshing ? "…" : "⟳"}
        </button>

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
          {!myAlias && !aliasStatus && (
            <span style={{ fontSize: 11, color: "#45475a" }}>observer mode</span>
          )}
        </div>
      </div>

      {/* Main area: sidebar + feed */}
      <div style={{ flex: 1, overflow: "hidden", display: "flex" }}>
        <Sidebar
          peers={[...peers]}
          rooms={[...rooms]}
          roomMembers={roomMembers}
          selectedRoom={selectedRoom}
          selectedPeer={selectedPeer}
          unreadRooms={unreadRooms}
          unreadPeers={unreadPeers}
          myAlias={myAlias}
          onRoomJoined={roomId => setRooms(prev => new Set([...prev, roomId]))}
          onRoomLeft={roomId => {
            setRooms(prev => { const s = new Set(prev); s.delete(roomId); return s; });
            if (selectedRoom === roomId) { setSelectedRoom(null); setFocusHistoryEvents([]); }
          }}
          onSelect={(target, isRoom) => {
            setComposeTo(target);
            setComposeIsRoom(isRoom);
            setFocusHistoryEvents([]);
            if (isRoom) {
              setSelectedRoom(target);
              setSelectedPeer(null);
              setUnreadRooms(prev => { const s = new Set(prev); s.delete(target); return s; });
              loadRoomHistory(target, 100).then(hist => setFocusHistoryEvents(hist));
            } else {
              setSelectedPeer(target);
              setSelectedRoom(null);
              setUnreadPeers(prev => { const s = new Set(prev); s.delete(target); return s; });
              loadPeerHistory(target, mySessionIdRef.current, myAlias, 100).then(hist => setFocusHistoryEvents(hist));
            }
          }}
        />
        <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
          {events.length === 0 ? (
            <div style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", color: "#585b70" }}>
              Waiting for swarm events…
            </div>
          ) : (
            <EventFeed
              events={events}
              selectedRoom={selectedRoom}
              selectedPeer={selectedPeer}
              myAlias={myAlias}
              focusHistoryEvents={focusHistoryEvents}
              onClearFocus={() => { setSelectedRoom(null); setSelectedPeer(null); setFocusHistoryEvents([]); }}
            />
          )}
        </div>
      </div>

      {/* Compose bar */}
        <ComposeBar
          peers={[...peers]}
          rooms={[...rooms]}
          myAlias={myAlias}
          initialTo={composeTo}
          initialIsRoom={composeIsRoom}
          onSent={event => setEvents(prev => {
            const next = [...prev, event];
            return next.length > MAX_EVENTS ? next.slice(-MAX_EVENTS) : next;
          })}
        />
    </div>
  );
}
