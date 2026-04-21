import { Command } from "@tauri-apps/plugin-shell";

export async function sendMessage(
  toAlias: string,
  message: string,
  isRoom: boolean,
  myAlias: string,
): Promise<{ ok: boolean; error?: string }> {
  if (!toAlias.trim() || !message.trim()) {
    return { ok: false, error: "target and message required" };
  }
  try {
    const args = isRoom
      ? (myAlias ? ["room", "send", "--from", myAlias, toAlias, message] : ["room", "send", toAlias, message])
      : (myAlias ? ["send", "--from", myAlias, toAlias, message] : ["send", toAlias, message]);
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
): Promise<{ ok: boolean; error?: string }> {
  try {
    const result = await Command.create("c2c", [
      "register", "--alias", alias, "--session-id", alias,
    ]).execute();
    if (result.code !== 0) {
      return { ok: false, error: result.stderr || `exit ${result.code}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}
