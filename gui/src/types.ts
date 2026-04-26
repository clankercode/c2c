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

// Sent-message local outbox — stores pending messages until delivery confirmed

export interface PendingMessage {
  id: string;           // unique outbox entry id
  toAlias: string;      // recipient alias or room id
  content: string;      // message body
  isRoom: boolean;      // true = room DM, false = direct
  sentAt: number;       // Date.now() at send time
  status: "pending" | "confirmed" | "failed";
}

// --- CLI JSON safe parsers ---

/** Guards poll-inbox --json output (InboxMessage[]) */
export function safeParseInboxMessage(raw: unknown): { from_alias: string; to_alias: string; content: string; ts?: number } | null {
  if (raw === null || raw === undefined || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.from_alias !== "string") return null;
  if (typeof obj.to_alias !== "string") return null;
  if (typeof obj.content !== "string") return null;
  return {
    from_alias: obj.from_alias,
    to_alias: obj.to_alias,
    content: obj.content,
    ts: typeof obj.ts === "number" ? obj.ts : undefined,
  };
}

/** Guards history --json / room history --json output (HistoryEntry[]) */
export function safeParseHistoryEntry(raw: unknown): { drained_at?: number; ts?: number; from_alias: string; to_alias?: string; content: string } | null {
  if (raw === null || raw === undefined || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.from_alias !== "string") return null;
  // content is required; missing content means malformed entry
  if (!Object.prototype.hasOwnProperty.call(obj, "content") || typeof obj.content !== "string") return null;
  return {
    drained_at: typeof obj.drained_at === "number" ? obj.drained_at : undefined,
    ts: typeof obj.ts === "number" ? obj.ts : undefined,
    from_alias: obj.from_alias,
    to_alias: typeof obj.to_alias === "string" ? obj.to_alias : undefined,
    content: obj.content,
  };
}

/** Guards list --json output (PeerInfo[]) */
export function safeParsePeerInfo(raw: unknown): { alias: string; alive: boolean } | null {
  if (raw === null || raw === undefined || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.alias !== "string") return null;
  return { alias: obj.alias, alive: obj.alive === true };
}

/** Guards health --json output (HealthInfo) */
export function safeParseHealthInfo(raw: unknown): {
  alive: number; registrations: number; rooms: number;
  relay: { status: string; message: string } | null;
} | null {
  if (raw === null || raw === undefined || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  return {
    alive: typeof obj.alive === "number" ? obj.alive : 0,
    registrations: typeof obj.registrations === "number" ? obj.registrations : 0,
    rooms: typeof obj.rooms === "number" ? obj.rooms : 0,
    relay: (obj.relay && typeof obj.relay === "object")
      ? {
          status: typeof (obj.relay as Record<string, unknown>).status === "string"
            ? (obj.relay as Record<string, unknown>).status as string : "",
          message: typeof (obj.relay as Record<string, unknown>).message === "string"
            ? (obj.relay as Record<string, unknown>).message as string : "",
        }
      : null,
  };
}

/** Guards room list --json output (RoomInfo[]) */
export function safeParseRoomInfo(raw: unknown): { room_id: string; member_count: number; alive_count: number; alive_members?: string[] } | null {
  if (raw === null || raw === undefined || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.room_id !== "string") return null;
  return {
    room_id: obj.room_id,
    member_count: typeof obj.member_count === "number" ? obj.member_count : 0,
    alive_count: typeof obj.alive_count === "number" ? obj.alive_count : 0,
    alive_members: Array.isArray(obj.alive_members)
      ? (obj.alive_members as unknown[]).filter((s): s is string => typeof s === "string")
      : undefined,
  };
}

/** Guards PendingMessage from localStorage (useOutbox) */
export function safeParsePendingMessage(raw: unknown): { id: string; toAlias: string; content: string; isRoom: boolean; sentAt: number; status: "pending" | "confirmed" | "failed" } | null {
  if (raw === null || raw === undefined || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.id !== "string") return null;
  if (typeof obj.toAlias !== "string") return null;
  if (typeof obj.content !== "string") return null;
  if (typeof obj.isRoom !== "boolean") return null;
  if (typeof obj.sentAt !== "number") return null;
  if (obj.status !== "pending" && obj.status !== "confirmed" && obj.status !== "failed") return null;
  return {
    id: obj.id,
    toAlias: obj.toAlias,
    content: obj.content,
    isRoom: obj.isRoom,
    sentAt: obj.sentAt,
    status: obj.status,
  };
}

/** Guards check-pending-reply --json output */
export function safeParsePendingReply(raw: unknown): { valid: boolean; error?: string } | null {
  if (raw === null || raw === undefined || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.valid !== "boolean") return null;
  return {
    valid: obj.valid,
    error: typeof obj.error === "string" ? obj.error : undefined,
  };
}

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
