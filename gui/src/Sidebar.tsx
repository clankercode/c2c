interface Props {
  peers: string[];
  rooms: string[];
  roomMembers?: Map<string, Set<string>>;
  selectedRoom?: string | null;
  selectedPeer?: string | null;
  unreadRooms?: Set<string>;
  unreadPeers?: Set<string>;
  onSelect: (target: string, isRoom: boolean) => void;
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

export function Sidebar({ peers, rooms, roomMembers = new Map(), selectedRoom, selectedPeer, unreadRooms = new Set(), unreadPeers = new Set(), onSelect }: Props) {
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
          {rooms.map(r => (
            <div
              key={r}
              style={selectedRoom === r ? ITEM_ACTIVE_STYLE : ITEM_STYLE}
              onClick={() => onSelect(r, true)}
              title={r}
            >
              <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis" }}>
                🏠 {r}
                {roomMembers.has(r) && (
                  <span style={{ color: "#45475a", fontSize: 10, marginLeft: 4 }}>
                    {roomMembers.get(r)!.size}
                  </span>
                )}
              </span>
              {unreadRooms.has(r) && (
                <span style={{ width: 6, height: 6, borderRadius: "50%", background: "#f38ba8", flexShrink: 0, display: "inline-block" }} />
              )}
            </div>
          ))}
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
    </div>
  );
}
