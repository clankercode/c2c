interface Props {
  peers: string[];
  rooms: string[];
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
};

export function Sidebar({ peers, rooms, onSelect }: Props) {
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
              style={ITEM_STYLE}
              onClick={() => onSelect(r, true)}
              title={r}
            >
              🏠 {r}
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
              style={ITEM_STYLE}
              onClick={() => onSelect(p, false)}
              title={p}
            >
              👤 {p}
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
