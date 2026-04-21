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
