import { describe, it, expect, vi, beforeEach } from "vitest";
import { pollInbox, loadHistory, loadRoomHistory, loadPeerHistory } from "../useHistory";

const { mockExecute } = vi.hoisted(() => {
  return { mockExecute: vi.fn<() => Promise<{ code: number; stdout: string; stderr: string }>>() };
});

vi.mock("@tauri-apps/plugin-shell", () => ({
  Command: {
    create: vi.fn().mockImplementation(() => ({
      execute: mockExecute,
      stdout: { on: vi.fn() },
      stderr: { on: vi.fn() },
      on: vi.fn(),
      spawn: vi.fn(),
      env: vi.fn(),
    })),
  } as unknown as typeof import("@tauri-apps/plugin-shell").Command,
}));

describe("useHistory", () => {
  beforeEach(() => {
    mockExecute.mockReset();
  });

  describe("pollInbox", () => {
    it("returns messages on success", async () => {
      const messages = [
        { from_alias: "alice", to_alias: "gui-me", content: "hello" },
        { from_alias: "bob", to_alias: "gui-me", content: "hi" },
      ];
      mockExecute.mockResolvedValue({
        code: 0,
        stdout: JSON.stringify(messages),
        stderr: "",
      });

      const result = await pollInbox("gui-me");
      expect(result).toHaveLength(2);
      expect(result[0].from_alias).toBe("alice");
      expect(result[0].event_type).toBe("message");
    });

    it("returns empty array on non-zero exit", async () => {
      mockExecute.mockResolvedValue({
        code: 1,
        stdout: "",
        stderr: "broker error",
      });

      const result = await pollInbox("gui-me");
      expect(result).toEqual([]);
    });

    it("returns empty array on JSON parse error", async () => {
      mockExecute.mockResolvedValue({
        code: 0,
        stdout: "not json",
        stderr: "",
      });

      const result = await pollInbox("gui-me");
      expect(result).toEqual([]);
    });
  });

  describe("loadHistory", () => {
    it("returns history entries on success", async () => {
      const entries = [
        {
          drained_at: 1234567890,
          from_alias: "alice",
          to_alias: "gui-me",
          content: "hello",
        },
      ];
      mockExecute.mockResolvedValue({
        code: 0,
        stdout: JSON.stringify(entries),
        stderr: "",
      });

      const result = await loadHistory(50, "gui-me");
      expect(result).toHaveLength(1);
      expect(result[0].from_alias).toBe("alice");
    });

    it("returns empty array on non-zero exit", async () => {
      mockExecute.mockResolvedValue({
        code: 1,
        stdout: "",
        stderr: "error",
      });

      const result = await loadHistory(50, "gui-me");
      expect(result).toEqual([]);
    });
  });

  describe("loadRoomHistory", () => {
    it("returns room messages on success", async () => {
      const entries = [
        {
          ts: 1234567890,
          from_alias: "alice",
          to_alias: "swarm-lounge",
          content: "hello room",
        },
      ];
      mockExecute.mockResolvedValue({
        code: 0,
        stdout: JSON.stringify(entries),
        stderr: "",
      });

      const result = await loadRoomHistory("swarm-lounge", 50);
      expect(result).toHaveLength(1);
      expect(result[0].content).toBe("hello room");
    });
  });

  describe("loadPeerHistory", () => {
    it("filters messages between two peers", async () => {
      const entries = [
        {
          drained_at: 1234567890,
          from_alias: "alice",
          to_alias: "gui-me",
          content: "direct to me",
        },
        {
          drained_at: 1234567891,
          from_alias: "charlie",
          to_alias: "gui-me",
          content: "not from alice",
        },
        {
          drained_at: 1234567892,
          from_alias: "gui-me",
          to_alias: "alice",
          content: "my reply to alice",
        },
      ];
      mockExecute.mockResolvedValue({
        code: 0,
        stdout: JSON.stringify(entries),
        stderr: "",
      });

      const result = await loadPeerHistory("alice", "gui-me", 50);
      expect(result).toHaveLength(2);
      expect(result[0].content).toBe("direct to me");
      expect(result[1].content).toBe("my reply to alice");
    });
  });
});
