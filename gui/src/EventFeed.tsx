import { C2cEvent, MessageEvent } from "./types";

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
      const preview = m.content.slice(0, 80).replace(/\n/g, " ");
      return `${m.from_alias} → ${m.to_alias}: ${preview}`;
    }
    case "drain":        return `${(e as { alias: string }).alias} polled inbox`;
    case "sweep":        return `${(e as { alias: string }).alias} swept`;
    case "peer.alive":   return `${(e as { alias: string }).alias} registered`;
    case "peer.dead":    return `${(e as { alias: string }).alias} deregistered`;
    case "room.join": {
      const r = e as { alias: string; room_id: string };
      return `${r.alias} joined ${r.room_id}`;
    }
    case "room.leave": {
      const r = e as { alias: string; room_id: string };
      return `${r.alias} left ${r.room_id}`;
    }
    default: return JSON.stringify(e);
  }
}

interface Props {
  events: C2cEvent[];
}

export function EventFeed({ events }: Props) {
  return (
    <div style={{ fontFamily: "monospace", fontSize: "13px", overflowY: "auto", flex: 1 }}>
      {events.slice().reverse().map((e, i) => (
        <div key={i} style={{ padding: "2px 8px", borderBottom: "1px solid #1e1e2e" }}>
          <span style={{ color: "#585b70", marginRight: 8 }}>
            {new Date(parseFloat(e.monitor_ts) * 1000).toLocaleTimeString()}
          </span>
          <span style={{ marginRight: 6 }}>{eventIcon(e)}</span>
          <span style={{ color: "#cdd6f4" }}>{eventLabel(e)}</span>
        </div>
      ))}
    </div>
  );
}
