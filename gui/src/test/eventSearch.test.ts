import { describe, expect, it } from "vitest";
import { eventSearchHaystack, matchesSearch } from "../eventSearch";
import { C2cEvent, MessageEvent } from "../types";

function msg(partial: Partial<MessageEvent> & { content: string }): MessageEvent {
  return {
    event_type: "message",
    monitor_ts: "1777171000",
    from_alias: partial.from_alias ?? "alice",
    to_alias: partial.to_alias ?? "bob",
    content: partial.content,
    room_id: partial.room_id,
  };
}

describe("eventSearchHaystack", () => {
  it("includes full message body (not a 120-char preview)", () => {
    const deep = "x".repeat(150) + " UNIQUE_TOKEN_DEEP " + "y".repeat(20);
    const hay = eventSearchHaystack(msg({ content: deep }));
    expect(hay).toContain("UNIQUE_TOKEN_DEEP");
    expect(hay.length).toBeGreaterThan(120);
  });

  it("includes from/to aliases", () => {
    const hay = eventSearchHaystack(msg({ from_alias: "coder-a", to_alias: "coder-b", content: "hi" }));
    expect(hay).toContain("coder-a");
    expect(hay).toContain("coder-b");
  });

  it("indexes peer and room events", () => {
    const peer: C2cEvent = { event_type: "peer.alive", monitor_ts: "1", alias: "grok-x" };
    const room: C2cEvent = { event_type: "room.join", monitor_ts: "1", alias: "me", room_id: "pagtown" };
    expect(eventSearchHaystack(peer)).toContain("grok-x");
    expect(eventSearchHaystack(room)).toContain("pagtown");
  });
});

describe("matchesSearch", () => {
  it("empty query matches all", () => {
    expect(matchesSearch(msg({ content: "hello" }), "")).toBe(true);
    expect(matchesSearch(msg({ content: "hello" }), "   ")).toBe(true);
  });

  it("is case-insensitive", () => {
    expect(matchesSearch(msg({ content: "Hello World" }), "hello")).toBe(true);
    expect(matchesSearch(msg({ content: "Hello World" }), "WORLD")).toBe(true);
  });

  it("matches tokens past the 120-char UI preview truncation", () => {
    const body = "a".repeat(130) + "NEEDLE_PAST_PREVIEW";
    expect(matchesSearch(msg({ content: body }), "NEEDLE_PAST_PREVIEW")).toBe(true);
  });

  it("matches alias substrings", () => {
    expect(matchesSearch(msg({ from_alias: "grok-subtle-nugget", content: "x" }), "subtle")).toBe(true);
  });

  it("rejects non-matching query", () => {
    expect(matchesSearch(msg({ content: "alpha" }), "beta")).toBe(false);
  });
});
