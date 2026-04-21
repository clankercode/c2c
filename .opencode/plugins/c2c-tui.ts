/**
 * c2c-tui.ts — TUI companion plugin for c2c
 *
 * Purpose: when a new root session is created (e.g. by the c2c server plugin's
 * auto-kickoff flow), automatically navigate the TUI to that session so the
 * user sees activity rather than staring at a blank "New session" banner.
 *
 * This is a TUI plugin (exports `tui:`) and runs in the frontend; it has
 * access to `api.route.navigate` which is not available to the server plugin.
 */

import type { TuiPlugin } from "@opencode-ai/plugin";

export const tui: TuiPlugin = async (api) => {
  // Listen for session.created events; if the new session is a root session
  // (no parentID), navigate the TUI to it automatically.
  const unsub = api.event.on("session.created" as any, (event: any) => {
    const info = event?.properties?.info;
    if (!info?.id) return;
    // Only auto-focus root sessions (not forks/children).
    if (info.parentID) return;
    try {
      api.route.navigate("session", { sessionID: info.id });
    } catch {
      // navigate may throw if the route is unavailable; ignore silently.
    }
  });

  api.lifecycle.onDispose(unsub);
};
