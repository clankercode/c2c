import { Command } from "@tauri-apps/plugin-shell";

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
    const entries = JSON.parse(result.stdout) as Array<{ alias: string; alive: boolean }>;
    return entries.map(e => ({ alias: e.alias, alive: e.alive ?? false }));
  } catch {
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
    const data = JSON.parse(result.stdout) as {
      alive?: number; registrations?: number; rooms?: number;
      relay?: { status: string; message: string };
    };
    return {
      alive: data.alive ?? 0,
      registrations: data.registrations ?? 0,
      rooms: data.rooms ?? 0,
      relay: data.relay ?? null,
    };
  } catch {
    return null;
  }
}

export async function discoverRooms(): Promise<RoomInfo[]> {
  try {
    const result = await Command.create("c2c", ["room", "list", "--json"]).execute();
    if (result.code !== 0) return [];
    const entries = JSON.parse(result.stdout) as Array<{
      room_id: string; member_count: number; alive_count: number; alive_members?: string[];
    }>;
    return entries.map(e => ({
      room_id: e.room_id,
      member_count: e.member_count ?? 0,
      alive_count: e.alive_count ?? 0,
      alive_members: e.alive_members,
    }));
  } catch {
    return [];
  }
}
