import { Command } from "@tauri-apps/plugin-shell";
import { safeParsePeerInfo, safeParseHealthInfo, safeParseRoomInfo } from "./types";

export interface PeerInfo {
  alias: string;
  alive: boolean;
}

export interface RoomInfo {
  room_id: string;
  member_count: number;
  alive_count: number;
  alive_members?: string[];
}

export async function discoverPeers(): Promise<PeerInfo[]> {
  try {
    const result = await Command.create("c2c", ["list", "--json"]).execute();
    if (result.code !== 0) return [];
    let raw: unknown;
    try { raw = JSON.parse(result.stdout); } catch { return []; }
    if (!Array.isArray(raw)) return [];
    return (raw as unknown[])
      .map(safeParsePeerInfo)
      .filter((e): e is NonNullable<typeof e> => e !== null)
      .map(e => ({ alias: e.alias, alive: e.alive }));
  } catch (err) {
    console.error("[c2c/gui] discoverPeers JSON.parse error:", err, "(CLI may have output non-JSON)");
    return [];
  }
}

export interface HealthInfo {
  alive: number;
  registrations: number;
  rooms: number;
  relay: { status: "green" | "yellow" | "red" | string; message: string } | null;
}

export async function fetchHealth(): Promise<HealthInfo | null> {
  try {
    const result = await Command.create("c2c", ["health", "--json"]).execute();
    if (result.code !== 0) return null;
    let raw: unknown;
    try { raw = JSON.parse(result.stdout); } catch { return null; }
    const data = safeParseHealthInfo(raw);
    if (!data) return null;
    return {
      alive: data.alive,
      registrations: data.registrations,
      rooms: data.rooms,
      relay: data.relay,
    };
  } catch (err) {
    console.error("[c2c/gui] fetchHealth JSON.parse error:", err, "(CLI may have output non-JSON)");
    return null;
  }
}

export async function discoverRooms(): Promise<RoomInfo[]> {
  try {
    const result = await Command.create("c2c", ["room", "list", "--json"]).execute();
    if (result.code !== 0) return [];
    let raw: unknown;
    try { raw = JSON.parse(result.stdout); } catch { return []; }
    if (!Array.isArray(raw)) return [];
    return (raw as unknown[])
      .map(safeParseRoomInfo)
      .filter((e): e is NonNullable<typeof e> => e !== null)
      .map(e => ({
        room_id: e.room_id,
        member_count: e.member_count,
        alive_count: e.alive_count,
        alive_members: e.alive_members,
      }));
  } catch (err) {
    console.error("[c2c/gui] discoverRooms JSON.parse error:", err, "(CLI may have output non-JSON)");
    return [];
  }
}
