import { describe, expect, it } from "vitest";
import { classifySendStdout } from "../useSend";

describe("classifySendStdout", () => {
  it("detects live ok delivery", () => {
    expect(classifySendStdout("ok -> alice (from bob)\n", "")).toBe("delivered");
  });

  it("detects queued offline enqueue", () => {
    expect(classifySendStdout("queued -> alice (offline)\n", "")).toBe("queued");
  });

  it("prefers queued when both tokens appear", () => {
    expect(classifySendStdout("ok -> alice\nqueued offline\n", "")).toBe("queued");
  });

  it("returns unknown when no delivery cue", () => {
    expect(classifySendStdout("", "")).toBe("unknown");
  });
});
