import { Command } from "@tauri-apps/plugin-shell";
import { toast } from "./useToast";

// Guard: shell plugin is only available inside Tauri desktop app, not in web browser
function isTauriDesktop(): boolean {
  try {
    // @ts-ignore — window.__TAURI__ only exists inside Tauri
    return typeof window !== "undefined" && !!window.__TAURI__;
  } catch {
    return false;
  }
}

export interface SendCallbacks {
  onConfirmed?: () => void;
  onFailed?: () => void;
}

export async function sendMessage(
  toAlias: string,
  message: string,
  isRoom: boolean,
  myAlias: string,
  cbs: SendCallbacks = {},
): Promise<{ ok: boolean; error?: string }> {
  if (!isTauriDesktop()) {
    const msg = "c2c desktop app required: open the installed Tauri app, not the web page";
    cbs.onFailed?.();
    return { ok: false, error: msg };
  }
  if (!toAlias.trim() || !message.trim()) {
    return { ok: false, error: "target and message required" };
  }
  try {
    const args = isRoom
      ? (myAlias ? ["room", "send", "--from", myAlias, toAlias, message] : ["room", "send", toAlias, message])
      : (myAlias ? ["send", "--from", myAlias, toAlias, message] : ["send", toAlias, message]);
    const result = await Command.create("c2c", args).execute();
    if (result.code !== 0) {
      cbs.onFailed?.();
      return { ok: false, error: result.stderr || `exit ${result.code}` };
    }
    cbs.onConfirmed?.();
    return { ok: true };
  } catch (e) {
    cbs.onFailed?.();
    return { ok: false, error: String(e) };
  }
}

export async function joinRoom(
  roomId: string,
  alias: string,
): Promise<{ ok: boolean; error?: string }> {
  if (!isTauriDesktop()) {
    return { ok: false, error: "c2c desktop app required: open the installed Tauri app, not the web page" };
  }
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
  if (!isTauriDesktop()) {
    return { ok: false, error: "c2c desktop app required: open the installed Tauri app, not the web page" };
  }
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
  if (!isTauriDesktop()) {
    const err = "c2c desktop app required: open the installed Tauri app, not the web page";
    toast.error(`register: ${err}`, 5);
    return { ok: false, error: err };
  }
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
