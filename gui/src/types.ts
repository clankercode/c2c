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
