import { describe, it, expect } from "vitest";

describe("sessionId generation", () => {
  // Session ID format: "gui-" + random36chars split into two parts
  const SESSION_RE = /^gui-[a-z0-9]{7}-[a-z0-9]{7}$/;

  function generateSessionId(): string {
    return (
      "gui-" +
      Math.random().toString(36).slice(2, 9) +
      "-" +
      Math.random().toString(36).slice(2, 9)
    );
  }

  it("generates valid gui-prefixed session IDs", () => {
    const sid = generateSessionId();
    expect(sid).toMatch(SESSION_RE);
  });

  it("generates unique IDs", () => {
    const ids = new Set(Array.from({ length: 100 }, () => generateSessionId()));
    expect(ids.size).toBe(100);
  });

  it("starts with gui- prefix for GUI identification", () => {
    const sid = generateSessionId();
    expect(sid.startsWith("gui-")).toBe(true);
  });
});

describe("localStorage key names", () => {
  const ALIAS_KEY = "c2c-gui-my-alias";
  const SESSION_ID_KEY = "c2c-gui-my-session-id";

  it("uses separate keys for alias and sessionId", () => {
    expect(ALIAS_KEY).not.toBe(SESSION_ID_KEY);
  });

  it("alias key contains 'alias'", () => {
    expect(ALIAS_KEY).toContain("alias");
  });

  it("session key contains 'session'", () => {
    expect(SESSION_ID_KEY).toContain("session");
  });

  it("keys are distinct to prevent accidental overwriting", () => {
    const store: Record<string, string> = {};
    store[ALIAS_KEY] = "my-alias";
    store[SESSION_ID_KEY] = "gui-abc-def";
    expect(store[ALIAS_KEY]).toBe("my-alias");
    expect(store[SESSION_ID_KEY]).toBe("gui-abc-def");
    expect(store[ALIAS_KEY]).not.toBe(store[SESSION_ID_KEY]);
  });
});

describe("alias validation regex", () => {
  // From WelcomeWizard.tsx
  const ALIAS_RE = /^(?!\.)[A-Za-z0-9._-]{1,64}$/;

  it("accepts valid aliases", () => {
    expect(ALIAS_RE.test("alice")).toBe(true);
    expect(ALIAS_RE.test("alice-42")).toBe(true);
    expect(ALIAS_RE.test("alice_smith")).toBe(true);
    expect(ALIAS_RE.test("alice.smith")).toBe(true);
    expect(ALIAS_RE.test("a")).toBe(true);
    expect(ALIAS_RE.test("A" + "a".repeat(62) + "A")).toBe(true); // 64 chars
  });

  it("rejects dot-prefixed aliases", () => {
    expect(ALIAS_RE.test(".alice")).toBe(false);
  });

  it("rejects aliases over 64 chars", () => {
    expect(ALIAS_RE.test("a".repeat(65))).toBe(false);
  });

  it("rejects empty string", () => {
    expect(ALIAS_RE.test("")).toBe(false);
  });
});

describe("history entry to event conversion", () => {
  // Replicates the logic from useHistory.ts
  function entryToEvent(e: {
    drained_at?: number;
    ts?: number;
    from_alias: string;
    to_alias?: string;
    content: string;
  }): unknown {
    const ts = e.drained_at ?? e.ts ?? Date.now() / 1000;
    const rawTo = e.to_alias ?? "";
    const hashIdx = rawTo.indexOf("#");
    const resolvedTo = hashIdx >= 0 ? rawTo.slice(hashIdx + 1) : rawTo;
    const roomId = hashIdx >= 0 ? rawTo.slice(hashIdx + 1) : undefined;
    return {
      event_type: "message",
      monitor_ts: String(ts),
      from_alias: e.from_alias ?? "",
      to_alias: resolvedTo,
      content: e.content ?? "",
      ts: new Date(ts * 1000).toISOString(),
      ...(roomId ? { room_id: roomId } : {}),
      _historical: true,
    };
  }

  it("converts history entry to message event", () => {
    const entry = {
      drained_at: 1234567890,
      from_alias: "alice",
      to_alias: "bob",
      content: "hello",
    };
    const event = entryToEvent(entry) as Record<string, unknown>;
    expect(event.event_type).toBe("message");
    expect(event.from_alias).toBe("alice");
    expect(event.to_alias).toBe("bob");
    expect(event.content).toBe("hello");
    expect(event._historical).toBe(true);
  });

  it("extracts room_id from # delimited to_alias", () => {
    const entry = {
      drained_at: 1234567890,
      from_alias: "alice",
      to_alias: "gui-user#swarm-lounge",
      content: "hello room",
    };
    const event = entryToEvent(entry) as Record<string, unknown>;
    expect(event.room_id).toBe("swarm-lounge");
    expect(event.to_alias).toBe("swarm-lounge");
  });

  it("handles missing drained_at by falling back to ts", () => {
    const entry = {
      ts: 1234567890,
      from_alias: "alice",
      content: "hello",
    };
    const event = entryToEvent(entry) as Record<string, unknown>;
    expect(event.monitor_ts).toBe("1234567890");
  });
});

describe("peer history filtering", () => {
  function filterPeerMessages(
    entries: Array<{ from_alias: string; to_alias: string; content: string }>,
    peer: string,
    myAlias: string,
  ) {
    return entries.filter((e) => {
      return (
        (e.from_alias === peer && e.to_alias === myAlias) ||
        (e.from_alias === myAlias && e.to_alias === peer)
      );
    });
  }

  it("returns messages to/from the peer", () => {
    const entries = [
      { from_alias: "alice", to_alias: "me", content: "1" },
      { from_alias: "charlie", to_alias: "me", content: "2" },
      { from_alias: "me", to_alias: "alice", content: "3" },
      { from_alias: "bob", to_alias: "me", content: "4" },
    ];
    const result = filterPeerMessages(entries, "alice", "me");
    expect(result).toHaveLength(2);
    expect(result[0].content).toBe("1");
    expect(result[1].content).toBe("3");
  });

  it("returns empty array when no messages with peer", () => {
    const entries = [
      { from_alias: "charlie", to_alias: "me", content: "1" },
    ];
    const result = filterPeerMessages(entries, "alice", "me");
    expect(result).toHaveLength(0);
  });
});
