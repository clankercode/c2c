import { Command } from "@tauri-apps/plugin-shell";
import { safeParsePendingReply } from "./types";

export interface PendingPermission {
  permId: string;
  kind: "permission" | "question";
  fromAlias: string;
  content: string;
  ts: number; // epoch seconds when received
  expiresAt: number; // epoch seconds
}

export interface PermissionHistoryEntry {
  permId: string;
  kind: "permission" | "question";
  fromAlias: string;
  content: string;
  decision: "approved" | "denied" | "expired";
  ts: number; // epoch seconds of decision
}

// Parse a permission message content string into a permission object
// Format: "permission:<perm_id>:<kind>" or other content
export function parsePermissionMessage(content: string, fromAlias: string, ts: number): PendingPermission | null {
  const prefix = "permission:";
  if (!content.startsWith(prefix)) return null;
  const rest = content.slice(prefix.length);
  const colonIdx = rest.indexOf(":");
  if (colonIdx < 0) return null;
  const permId = rest.slice(0, colonIdx);
  const kind = rest.slice(colonIdx + 1) as "permission" | "question";
  if (kind !== "permission" && kind !== "question") return null;

  // TTL is 300s (5 min), capped at 300 per the broker spec
  const TTL = 300;
  return {
    permId,
    kind,
    fromAlias,
    content,
    ts,
    expiresAt: ts + TTL,
  };
}

// Get seconds remaining until expiry
export function ttlSeconds(p: PendingPermission): number {
  return Math.max(0, Math.round(p.expiresAt - Date.now() / 1000));
}

// Check if a pending permission is expired
export function isExpired(p: PendingPermission): boolean {
  return ttlSeconds(p) <= 0;
}

// Approve a pending permission: check with broker, then send approval message
export async function approvePermission(
  perm: PendingPermission,
  myAlias: string,
  _sessionId: string
): Promise<{ ok: boolean; error?: string }> {
  // 1. Validate with broker
  try {
    const result = await Command.create("c2c", [
      "check-pending-reply", "--json", perm.permId, myAlias,
    ]).execute();
    if (result.code !== 0) {
      return { ok: false, error: result.stderr || `exit ${result.code}` };
    }
    let raw: unknown;
    try { raw = JSON.parse(result.stdout); } catch {
      return { ok: false, error: "JSON parse error" };
    }
    const data = safeParsePendingReply(raw);
    if (!data || !data.valid) {
      return { ok: false, error: data?.error || "invalid reply" };
    }
  } catch (e) {
    return { ok: false, error: String(e) };
  }

  // 2. Send approval back to requester
  // The requester's session_id was returned by check_pending_reply as requester_session_id
  // We send a direct message back to the requester
  // Format: the approval is sent via a regular send to the requester
  // Actually, looking at the flow: the supervisor sends "approved:<perm_id>" or "denied:<perm_id>"
  // back to the requester via their session_id
  // But we don't have the requester's alias — we need to look this up.
  // For now, we'll use the alias-based send which routes to the requester's session.
  // Actually, the check_pending_reply returns requester_session_id but we need the alias.
  // The broker routes based on session_id, but we use alias in the send command.
  // The requesting agent's alias is in the original message (fromAlias).
  try {
    const sendResult = await Command.create("c2c", [
      "send", "--from", myAlias, perm.fromAlias,
      `approved:${perm.permId}`,
    ]).execute();
    if (sendResult.code !== 0) {
      return { ok: false, error: sendResult.stderr || `exit ${sendResult.code}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

// Deny a pending permission
export async function denyPermission(
  perm: PendingPermission,
  myAlias: string,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const result = await Command.create("c2c", [
      "send", "--from", myAlias, perm.fromAlias,
      `denied:${perm.permId}`,
    ]).execute();
    if (result.code !== 0) {
      return { ok: false, error: result.stderr || `exit ${result.code}` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}
