import { useState, useEffect, KeyboardEvent } from "react";
import { sendMessage } from "./useSend";
import { MessageEvent } from "./types";

interface Props {
  peers: string[];
  rooms: string[];
  myAlias: string;
  initialTo?: string;
  initialIsRoom?: boolean;
  onSent?: (event: MessageEvent) => void;
}

const INPUT_STYLE: React.CSSProperties = {
  background: "#313244",
  border: "1px solid #45475a",
  borderRadius: 4,
  color: "#cdd6f4",
  padding: "4px 8px",
  fontSize: 13,
  outline: "none",
};

export function ComposeBar({ peers, rooms, myAlias, initialTo = "", initialIsRoom = false, onSent }: Props) {
  const [to, setTo] = useState(initialTo);
  const [isRoom, setIsRoom] = useState(initialIsRoom);

  useEffect(() => {
    if (initialTo) { setTo(initialTo); setIsRoom(initialIsRoom); }
  }, [initialTo, initialIsRoom]);
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [lastError, setLastError] = useState<string | null>(null);
  const [lastOk, setLastOk] = useState(false);
  // Store the full failed attempt so retry sends to the exact same target
  const [failedAttempt, setFailedAttempt] = useState<{ text: string; to: string; isRoom: boolean } | null>(null);

  const targets = [
    ...peers.map(p => ({ label: `👤 ${p}`, value: p, room: false })),
    ...rooms.map(r => ({ label: `🏠 ${r}`, value: r, room: true })),
  ];

  async function send(attempt?: { text: string; to: string; isRoom: boolean }) {
    const target = attempt?.to ?? to.trim();
    const body = (attempt?.text ?? text).trim();
    const room = attempt?.isRoom ?? isRoom;
    if (!target || !body || sending) return;
    setSending(true);
    setLastError(null);
    setLastOk(false);
    setFailedAttempt(null);
    const res = await sendMessage(target, body, room, myAlias);
    setSending(false);
    if (res.ok) {
      const nowEpoch = String(Date.now() / 1000);
      const nowIso = new Date().toISOString();
      onSent?.({
        event_type: "message",
        monitor_ts: nowEpoch,
        ts: nowIso,
        from_alias: myAlias,
        to_alias: to.trim(),
        room_id: isRoom ? to.trim() : undefined,
        content: text.trim(),
      });
      setText("");
      setLastOk(true);
      setTimeout(() => setLastOk(false), 1500);
    } else {
      setLastError(res.error ?? "unknown error");
      setFailedAttempt({ text: body, to: target, isRoom: room });
    }
  }

  function handleTextChange(val: string) {
    setText(val);
    // Clear error when user edits — they're fixing it
    if (lastError) { setLastError(null); setFailedAttempt(null); }
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  }

  function onTargetChange(val: string) {
    const found = targets.find(t => t.value === val);
    setTo(val);
    if (found) setIsRoom(found.room);
  }

  return (
    <div style={{
      borderTop: "1px solid #313244",
      background: "#181825",
      padding: "8px 12px",
      display: "flex",
      gap: 8,
      alignItems: "flex-end",
    }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 4, minWidth: 160 }}>
        <label style={{ fontSize: 10, color: "#585b70" }}>
          to
          {isRoom && to && <span style={{ marginLeft: 6, color: "#89dceb" }}>🏠 room</span>}
          {!isRoom && to && <span style={{ marginLeft: 6, color: "#cba6f7" }}>👤 peer</span>}
        </label>
        <datalist id="compose-targets">
          {targets.map(t => <option key={t.value} value={t.value} />)}
        </datalist>
        <input
          list="compose-targets"
          value={to}
          onChange={e => onTargetChange(e.target.value)}
          placeholder="alias or room-id"
          autoComplete="off"
          style={{ ...INPUT_STYLE, minWidth: 140 }}
        />
      </div>

      <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 4 }}>
        <label style={{ fontSize: 10, color: "#585b70" }}>
          message <span style={{ color: "#45475a" }}>(Enter to send, Shift+Enter for newline)</span>
        </label>
        <textarea
          value={text}
          onChange={e => handleTextChange(e.target.value)}
          onKeyDown={onKeyDown}
          rows={2}
          placeholder={to ? `message to ${isRoom ? "room " : ""}${to}…` : "select a target first"}
          style={{ ...INPUT_STYLE, resize: "none", fontFamily: "monospace" }}
          disabled={!to || sending}
        />
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
        <label style={{ fontSize: 10, color: "transparent" }}>send</label>
        <button
          onClick={() => send()}
          disabled={!to || !text.trim() || sending}
          style={{
            background: sending ? "#45475a" : "#89b4fa",
            border: "none",
            borderRadius: 4,
            color: "#1e1e2e",
            padding: "6px 16px",
            fontWeight: 700,
            fontSize: 13,
            cursor: sending ? "not-allowed" : "pointer",
          }}
        >
          {sending ? "…" : "Send"}
        </button>
        {lastError && (
          <div style={{ fontSize: 10, color: "#f38ba8", maxWidth: 120, wordBreak: "break-word" }}>
            {lastError}
          </div>
        )}
        {failedAttempt && !sending && (
          <button
            onClick={() => send(failedAttempt)}
            style={{
              background: "transparent",
              border: "1px solid #f38ba8",
              borderRadius: 4,
              color: "#f38ba8",
              padding: "2px 8px",
              fontSize: 11,
              cursor: "pointer",
            }}
          >
            retry → {failedAttempt.to}
          </button>
        )}
        {lastOk && (
          <div style={{ fontSize: 10, color: "#a6e3a1" }}>sent ✓</div>
        )}
      </div>
    </div>
  );
}
