import { useState } from "react";
import { joinRoom, leaveRoom } from "./useSend";

interface Props {
  peers: string[];
  rooms: string[];
  roomMembers?: Map<string, Set<string>>;
  selectedRoom?: string | null;
  selectedPeer?: string | null;
  unreadRooms?: Set<string>;
  unreadPeers?: Set<string>;
  myAlias?: string;
  onSelect: (target: string, isRoom: boolean) => void;
  onRoomJoined?: (roomId: string) => void;
  onRoomLeft?: (roomId: string) => void;
}

const SECTION_STYLE: React.CSSProperties = {
  padding: "6px 10px 2px",
  fontSize: 10,
  color: "#585b70",
  textTransform: "uppercase",
  letterSpacing: 1,
};

const ITEM_STYLE: React.CSSProperties = {
  padding: "3px 10px",
  fontSize: 12,
  cursor: "pointer",
  color: "#bac2de",
  whiteSpace: "nowrap",
  overflow: "hidden",
  textOverflow: "ellipsis",
  display: "flex",
  alignItems: "center",
  gap: 4,
};

const ITEM_ACTIVE_STYLE: React.CSSProperties = {
  ...ITEM_STYLE,
  background: "#313244",
  color: "#89dceb",
};

const ITEM_PEER_ACTIVE_STYLE: React.CSSProperties = {
  ...ITEM_STYLE,
  background: "#313244",
  color: "#cba6f7",
};

export function Sidebar({ peers, rooms, roomMembers = new Map(), selectedRoom, selectedPeer, unreadRooms = new Set(), unreadPeers = new Set(), myAlias = "", onSelect, onRoomJoined, onRoomLeft }: Props) {
  const [joinInput, setJoinInput] = useState("");
  const [joining, setJoining] = useState(false);
  const [joinError, setJoinError] = useState<string | null>(null);
  const [leavingRoom, setLeavingRoom] = useState<string | null>(null);

  async function handleLeave(rid: string) {
    if (leavingRoom) return;
    setLeavingRoom(rid);
    const res = await leaveRoom(rid, myAlias);
    setLeavingRoom(null);
    if (res.ok) onRoomLeft?.(rid);
  }

  async function handleJoin() {
    const rid = joinInput.trim();
    if (!rid || joining) return;
    setJoining(true);
    setJoinError(null);
    const res = await joinRoom(rid, myAlias);
    setJoining(false);
    if (res.ok) {
      setJoinInput("");
      onRoomJoined?.(rid);
      onSelect(rid, true);
    } else {
      setJoinError(res.error ?? "join failed");
    }
  }

  return (
    <div style={{
      width: 160,
      background: "#181825",
      borderRight: "1px solid #313244",
      display: "flex",
      flexDirection: "column",
      overflow: "hidden",
      flexShrink: 0,
    }}>
      {rooms.length > 0 && (
        <>
          <div style={SECTION_STYLE}>Rooms</div>
          {rooms.map(r => {
            const isActive = selectedRoom === r;
            const members = roomMembers.get(r);
            return (
              <div key={r}>
                <div
                  style={isActive ? ITEM_ACTIVE_STYLE : ITEM_STYLE}
                  onClick={() => onSelect(r, true)}
                  title={r}
                >
                  <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis" }}>
                    🏠 {r}
                    {members && (
                      <span style={{ color: "#45475a", fontSize: 10, marginLeft: 4 }}>
                        {members.size}
                      </span>
                    )}
                  </span>
                  {unreadRooms.has(r) && (
                    <span style={{ width: 6, height: 6, borderRadius: "50%", background: "#f38ba8", flexShrink: 0, display: "inline-block" }} />
                  )}
                  {isActive && (
                    <button
                      onClick={e => { e.stopPropagation(); handleLeave(r); }}
                      disabled={leavingRoom === r}
                      title="Leave room"
                      style={{
                        background: "transparent", border: "none",
                        color: "#45475a", fontSize: 10,
                        padding: "0 2px", cursor: "pointer", flexShrink: 0,
                        lineHeight: 1,
                      }}
                    >
                      {leavingRoom === r ? "…" : "✕"}
                    </button>
                  )}
                </div>
                {/* Expanded member list when this room is active */}
                {isActive && members && members.size > 0 && (
                  <div style={{ paddingLeft: 16, paddingBottom: 4 }}>
                    {[...members].map(m => (
                      <div
                        key={m}
                        style={{
                          fontSize: 11,
                          color: "#89b4fa",
                          padding: "1px 10px",
                          display: "flex",
                          alignItems: "center",
                          gap: 4,
                          cursor: "pointer",
                          whiteSpace: "nowrap",
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                        }}
                        onClick={() => onSelect(m, false)}
                        title={`DM ${m}`}
                      >
                        <span style={{
                          width: 5, height: 5, borderRadius: "50%",
                          background: "#a6e3a1", flexShrink: 0,
                          display: "inline-block",
                        }} />
                        {m}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            );
          })}
        </>
      )}

      {peers.length > 0 && (
        <>
          <div style={{ ...SECTION_STYLE, marginTop: 8 }}>Peers</div>
          {peers.map(p => (
            <div
              key={p}
              style={selectedPeer === p ? ITEM_PEER_ACTIVE_STYLE : ITEM_STYLE}
              onClick={() => onSelect(p, false)}
              title={p}
            >
              <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis" }}>👤 {p}</span>
              {unreadPeers.has(p) && (
                <span style={{ width: 6, height: 6, borderRadius: "50%", background: "#f38ba8", flexShrink: 0, display: "inline-block" }} />
              )}
            </div>
          ))}
        </>
      )}

      {peers.length === 0 && rooms.length === 0 && (
        <div style={{ padding: "12px 10px", fontSize: 11, color: "#45475a" }}>
          No peers yet
        </div>
      )}

      {/* Spacer + join room footer */}
      <div style={{ flex: 1 }} />
      <div style={{
        borderTop: "1px solid #313244",
        padding: "6px 8px",
        display: "flex",
        flexDirection: "column",
        gap: 4,
      }}>
        <div style={{ fontSize: 10, color: "#585b70", textTransform: "uppercase", letterSpacing: 1 }}>
          Join room
        </div>
        <div style={{ display: "flex", gap: 4 }}>
          <input
            value={joinInput}
            onChange={e => { setJoinInput(e.target.value); setJoinError(null); }}
            onKeyDown={e => e.key === "Enter" && handleJoin()}
            placeholder="room-id"
            disabled={joining}
            style={{
              flex: 1,
              background: "#1e1e2e",
              border: "1px solid #45475a",
              borderRadius: 3,
              color: "#cdd6f4",
              padding: "2px 5px",
              fontSize: 11,
              outline: "none",
              minWidth: 0,
            }}
          />
          <button
            onClick={handleJoin}
            disabled={!joinInput.trim() || joining}
            style={{
              background: joining ? "#45475a" : "#89b4fa",
              border: "none",
              borderRadius: 3,
              color: "#11111b",
              padding: "2px 6px",
              fontSize: 11,
              fontWeight: 700,
              cursor: "pointer",
              flexShrink: 0,
            }}
          >
            {joining ? "…" : "+"}
          </button>
        </div>
        {joinError && (
          <div style={{ fontSize: 10, color: "#f38ba8", wordBreak: "break-word" }}>
            {joinError}
          </div>
        )}
      </div>
    </div>
  );
}
