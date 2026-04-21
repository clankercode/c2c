import { useState, KeyboardEvent } from "react";
import { sendMessage } from "./useSend";

interface Props {
  peers: string[];
  rooms: string[];
  myAlias: string;
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

export function ComposeBar({ peers, rooms, myAlias }: Props) {
  const [to, setTo] = useState("");
  const [isRoom, setIsRoom] = useState(false);
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [lastError, setLastError] = useState<string | null>(null);
  const [lastOk, setLastOk] = useState(false);

  const targets = [
    ...peers.map(p => ({ label: `👤 ${p}`, value: p, room: false })),
    ...rooms.map(r => ({ label: `🏠 ${r}`, value: r, room: true })),
  ];

  async function send() {
    if (!to.trim() || !text.trim() || sending) return;
    setSending(true);
    setLastError(null);
    setLastOk(false);
    const res = await sendMessage(to.trim(), text.trim(), isRoom, myAlias);
    setSending(false);
    if (res.ok) {
      setText("");
      setLastOk(true);
      setTimeout(() => setLastOk(false), 1500);
    } else {
      setLastError(res.error ?? "unknown error");
    }
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
        <label style={{ fontSize: 10, color: "#585b70" }}>to</label>
        <select
          value={to}
          onChange={e => onTargetChange(e.target.value)}
          style={{ ...INPUT_STYLE, minWidth: 140 }}
        >
          <option value="">— pick target —</option>
          {targets.length === 0 && <option disabled>no peers yet</option>}
          {targets.map(t => (
            <option key={t.value} value={t.value}>{t.label}</option>
          ))}
        </select>
        <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
          <input
            type="checkbox"
            id="is-room"
            checked={isRoom}
            onChange={e => setIsRoom(e.target.checked)}
          />
          <label htmlFor="is-room" style={{ fontSize: 11, color: "#585b70", cursor: "pointer" }}>
            room
          </label>
        </div>
      </div>

      <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 4 }}>
        <label style={{ fontSize: 10, color: "#585b70" }}>
          message <span style={{ color: "#45475a" }}>(Enter to send, Shift+Enter for newline)</span>
        </label>
        <textarea
          value={text}
          onChange={e => setText(e.target.value)}
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
          onClick={send}
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
        {lastOk && (
          <div style={{ fontSize: 10, color: "#a6e3a1" }}>sent ✓</div>
        )}
      </div>
    </div>
  );
}
