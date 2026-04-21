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
      ? ["room", "send", toAlias, message]
      : ["send", toAlias, message];
    const env: Record<string, string> = {};
    if (myAlias) env["C2C_MCP_SESSION_ID"] = myAlias;
    const result = await Command.create("c2c", args, { env }).execute();
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
    const result = await Command.create("c2c", ["register", alias]).execute();
    if (result.code !== 0) {
      return { ok: false, error: result.stderr || `exit ${result.code}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}
