import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { EventFeed } from "../EventFeed";
import { MessageEvent } from "../types";

function messageEvent(content: string): MessageEvent {
  return {
    event_type: "message",
    monitor_ts: "1777171000",
    from_alias: "alice",
    to_alias: "me",
    content,
  };
}

describe("EventFeed markdown rendering", () => {
  it("renders markdown in focused chat bubbles", async () => {
    const { container } = render(
      <EventFeed
        events={[messageEvent("**Plan**\n\n```ts\nconst ok = true;\n```\nUse `c2c send`.")]}
        selectedPeer="alice"
        myAlias="me"
      />,
    );

    expect((await screen.findByText("Plan")).tagName).toBe("STRONG");
    expect(container.querySelector("pre code")?.textContent).toContain("const ok = true;");
    expect(screen.getByText("c2c send").tagName).toBe("CODE");
  });

  it("renders markdown when expanding a global message", async () => {
    const longMarkdown = `${"x".repeat(121)}\n\n\`\`\`sh\nc2c list\n\`\`\``;
    const { container } = render(
      <EventFeed events={[messageEvent(longMarkdown)]} myAlias="me" />,
    );

    fireEvent.click(await screen.findByText(/alice → me:/));

    expect(container.querySelector("pre code")?.textContent).toContain("c2c list");
  });
});
