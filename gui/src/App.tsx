import { useEffect, useRef, useState } from "react";
import { Command, Child } from "@tauri-apps/plugin-shell";
import { C2cEvent } from "./types";
import { EventFeed } from "./EventFeed";

const MAX_EVENTS = 1000;

export function App() {
  const [events, setEvents] = useState<C2cEvent[]>([]);
  const [status, setStatus] = useState<"connecting" | "live" | "error">("connecting");
  const childRef = useRef<Child | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function startMonitor() {
      try {
        const cmd = Command.create("c2c", [
          "monitor", "--all", "--json", "--drains", "--sweeps",
        ]);

        cmd.stdout.on("data", (line: string) => {
          if (cancelled) return;
          const trimmed = line.trim();
          if (!trimmed) return;
          try {
            const event: C2cEvent = JSON.parse(trimmed);
            setEvents(prev => {
              const next = [...prev, event];
              return next.length > MAX_EVENTS ? next.slice(-MAX_EVENTS) : next;
            });
            setStatus("live");
          } catch {
            // ignore non-JSON lines
          }
        });

        cmd.stderr.on("data", () => { /* suppress */ });

        cmd.on("close", () => {
          if (!cancelled) setStatus("error");
        });

        cmd.on("error", () => {
          if (!cancelled) setStatus("error");
        });

        const child = await cmd.spawn();
        childRef.current = child;
      } catch {
        if (!cancelled) setStatus("error");
      }
    }

    startMonitor();

    return () => {
      cancelled = true;
      childRef.current?.kill().catch(() => {});
    };
  }, []);

  const statusColor = { connecting: "#f9e2af", live: "#a6e3a1", error: "#f38ba8" }[status];

  return (
    <div style={{
      display: "flex", flexDirection: "column", height: "100vh",
      background: "#1e1e2e", color: "#cdd6f4",
    }}>
      <div style={{
        padding: "8px 16px", background: "#181825",
        borderBottom: "1px solid #313244",
        display: "flex", alignItems: "center", gap: 12,
      }}>
        <span style={{ fontWeight: 700, letterSpacing: 1 }}>c2c</span>
        <span style={{ fontSize: 11, color: "#585b70" }}>swarm monitor</span>
        <span style={{ marginLeft: "auto", fontSize: 11, color: statusColor }}>
          ● {status}
        </span>
      </div>

      <div style={{ padding: "4px 8px", background: "#11111b", fontSize: 11, color: "#585b70" }}>
        {events.length} events
      </div>

      {events.length === 0 ? (
        <div style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", color: "#585b70" }}>
          Waiting for swarm events…
        </div>
      ) : (
        <EventFeed events={events} />
      )}
    </div>
  );
}
