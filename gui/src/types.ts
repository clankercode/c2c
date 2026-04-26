// NDJSON event types from `c2c monitor --json --all --drains --sweeps`

export interface BaseEvent {
  event_type: string;
  monitor_ts: string;
}

export interface MessageEvent extends BaseEvent {
  event_type: "message";
  from_alias: string;
  to_alias: string;
  content: string;
  ts?: string;
  room_id?: string;
}

export interface DrainEvent extends BaseEvent {
  event_type: "drain";
  alias: string;
}

export interface SweepEvent extends BaseEvent {
  event_type: "sweep";
  alias: string;
}

export interface PeerAliveEvent extends BaseEvent {
  event_type: "peer.alive";
  alias: string;
}

export interface PeerDeadEvent extends BaseEvent {
  event_type: "peer.dead";
  alias: string;
}

export interface RoomJoinEvent extends BaseEvent {
  event_type: "room.join";
  room_id: string;
  alias: string;
}

export interface RoomLeaveEvent extends BaseEvent {
  event_type: "room.leave";
  room_id: string;
  alias: string;
}

export type C2cEvent =
  | MessageEvent
  | DrainEvent
  | SweepEvent
  | PeerAliveEvent
  | PeerDeadEvent
  | RoomJoinEvent
  | RoomLeaveEvent
  | (BaseEvent & Record<string, unknown>);

/** Validate and type-check a raw JSON object as a C2cEvent.
    Returns null if the object is malformed or missing required fields.
    This guards the monitor JSON ingestion point against malformed data. */
export function safeParseEvent(raw: unknown): C2cEvent | null {
  if (raw === null || raw === undefined || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.event_type !== "string") return null;
  if (typeof obj.monitor_ts !== "string") return null;
  if (isNaN(parseFloat(obj.monitor_ts))) return null;

  switch (obj.event_type) {
    case "message":
      if (typeof obj.from_alias !== "string") return null;
      if (typeof obj.to_alias !== "string") return null;
      if (typeof obj.content !== "string") return null;
      return obj as unknown as MessageEvent;
    case "drain":
    case "sweep":
    case "peer.alive":
    case "peer.dead":
      if (typeof obj.alias !== "string") return null;
      return obj as unknown as DrainEvent;
    case "room.join":
    case "room.leave":
      if (typeof obj.room_id !== "string") return null;
      if (typeof obj.alias !== "string") return null;
      return obj as unknown as RoomJoinEvent;
    case "monitor.ready":
      // Internal sentinel — pass through as opaque record
      return obj as unknown as BaseEvent & Record<string, unknown>;
    default:
      // Unknown event type — allow as opaque record
      return obj as unknown as BaseEvent & Record<string, unknown>;
  }
}
