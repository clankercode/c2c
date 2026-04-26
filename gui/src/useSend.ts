import { Command } from "@tauri-apps/plugin-shell";
import { toast } from "./useToast";

export interface SendCallbacks {
  onQueued?: (id: string) => void;
  onConfirmed?: (id: string) => void;
  onFailed?: (id: string) => void;
}

export async function sendMessage(
  toAlias: string,
  message: string,
  isRoom: boolean,
  myAlias: string,
  cbs: SendCallbacks = {},
): Promise<{ ok: boolean; error?: string }> {
  if (!toAlias.trim() || !message.trim()) {
    return { ok: false, error: "target and message required" };
  }
  const id = `outbox-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
  try {
    const args = isRoom
      ? (myAlias ? ["room", "send", "--from", myAlias, toAlias, message] : ["room", "send", toAlias, message])
      : (myAlias ? ["send", "--from", myAlias, toAlias, message] : ["send", toAlias, message]);
    cbs.onQueued?.(id);
    const result = await Command.create("c2c", args).execute();
    if (result.code !== 0) {
      cbs.onFailed?.(id);
      return { ok: false, error: result.stderr || `exit ${result.code}` };
    }
    cbs.onConfirmed?.(id);
    return { ok: true };
  } catch (e) {
    cbs.onFailed?.(id);
    return { ok: false, error: String(e) };
  }
}

export async function joinRoom(
  roomId: string,
  alias: string,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const args = alias
      ? ["room", "join", "--alias", alias, roomId]
      : ["room", "join", roomId];
    const result = await Command.create("c2c", args).execute();
    if (result.code !== 0) {
      return { ok: false, error: result.stderr || `exit ${result.code}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export async function leaveRoom(
  roomId: string,
  alias: string,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const args = alias
      ? ["room", "leave", "--alias", alias, roomId]
      : ["room", "leave", roomId];
    const result = await Command.create("c2c", args).execute();
    if (result.code !== 0) {
      return { ok: false, error: result.stderr || `exit ${result.code}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export async function registerAlias(
  alias: string,
  sessionId: string,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const result = await Command.create("c2c", [
      "register", "--alias", alias, "--session-id", sessionId,
    ]).execute();
    if (result.code !== 0) {
      const err = result.stderr || `exit ${result.code}`;
      toast.error(`register: ${err}`, 5);
      return { ok: false, error: err };
    }
    return { ok: true };
  } catch (e) {
    toast.error(`register: ${String(e)}`, 5);
    return { ok: false, error: String(e) };
  }
}
