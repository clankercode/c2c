import { useState, useCallback, useEffect } from "react";
import type { PendingMessage } from "./types";

const OUTBOX_KEY = "c2c_outbox";

function loadOutbox(): PendingMessage[] {
  try {
    const raw = localStorage.getItem(OUTBOX_KEY);
    return raw ? (JSON.parse(raw) as PendingMessage[]) : [];
  } catch {
    return [];
  }
}

function saveOutbox(msgs: PendingMessage[]): void {
  try {
    localStorage.setItem(OUTBOX_KEY, JSON.stringify(msgs));
  } catch {
    // localStorage unavailable — outbox silently disabled
  }
}

export function useOutbox() {
  const [outbox, setOutbox] = useState<PendingMessage[]>(() => loadOutbox());

  // Prune confirmed/failed entries older than 24h on mount
  useEffect(() => {
    const cutoff = Date.now() - 24 * 60 * 60 * 1000;
    setOutbox(prev => {
      const pruned = prev.filter(m => m.status === "pending" || m.sentAt > cutoff);
      if (pruned.length !== prev.length) saveOutbox(pruned);
      return pruned;
    });
  }, []);

  const addOutboxEntry = useCallback((
    toAlias: string,
    content: string,
    isRoom: boolean,
  ): string => {
    const id = `outbox-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    const entry: PendingMessage = {
      id,
      toAlias,
      content,
      isRoom,
      sentAt: Date.now(),
      status: "pending",
    };
    setOutbox(prev => {
      const next = [...prev, entry];
      saveOutbox(next);
      return next;
    });
    return id;
  }, []);

  const confirmOutboxEntry = useCallback((id: string) => {
    setOutbox(prev => {
      const next = prev.map(m => m.id === id ? { ...m, status: "confirmed" as const } : m);
      saveOutbox(next);
      return next;
    });
  }, []);

  const failOutboxEntry = useCallback((id: string) => {
    setOutbox(prev => {
      const next = prev.map(m => m.id === id ? { ...m, status: "failed" as const } : m);
      saveOutbox(next);
      return next;
    });
  }, []);

  const clearOutbox = useCallback(() => {
    setOutbox([]);
    saveOutbox([]);
  }, []);

  return { outbox, addOutboxEntry, confirmOutboxEntry, failOutboxEntry, clearOutbox };
}
