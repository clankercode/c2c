/**
 * Unit tests for the c2c-tui.ts companion plugin.
 *
 * Regression tests for #58 (TUI session focus gap): the plugin must call
 * api.route.navigate("session", { sessionID }) whenever a new root session
 * is created, so the TUI focuses it automatically without user interaction.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

// ---------------------------------------------------------------------------
// Minimal TuiPluginApi mock
// ---------------------------------------------------------------------------

function makeTuiApi() {
  const navigateSpy = vi.fn();
  const disposeSpy = vi.fn();
  const eventHandlers: Map<string, (event: unknown) => void> = new Map();

  const api = {
    route: {
      navigate: navigateSpy,
      register: vi.fn(),
      current: {},
    },
    event: {
      on: vi.fn((type: string, handler: (event: unknown) => void) => {
        eventHandlers.set(type, handler);
        return () => eventHandlers.delete(type);
      }),
    },
    lifecycle: {
      signal: new AbortController().signal,
      onDispose: vi.fn((fn: () => void) => {
        disposeSpy.mockImplementation(fn);
        return () => {};
      }),
    },
  };

  function fireEvent(type: string, payload: unknown) {
    const handler = eventHandlers.get(type);
    if (handler) handler(payload);
  }

  return { api, navigateSpy, disposeSpy, fireEvent };
}

// ---------------------------------------------------------------------------
// Import the TUI plugin under test
// ---------------------------------------------------------------------------

import { tui as tuiPlugin } from '../plugins/c2c-tui.ts';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('c2c-tui plugin — #58 TUI focus regression', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('calls route.navigate("session", { sessionID }) when a root session.created fires', async () => {
    const { api, navigateSpy, fireEvent } = makeTuiApi();

    await tuiPlugin(api as any, undefined, {} as any);

    fireEvent('session.created', {
      type: 'session.created',
      properties: { info: { id: 'ses_abc123' } },
    });

    expect(navigateSpy).toHaveBeenCalledOnce();
    expect(navigateSpy).toHaveBeenCalledWith('session', { sessionID: 'ses_abc123' });
  });

  it('does NOT call route.navigate for child sessions (parentID set)', async () => {
    const { api, navigateSpy, fireEvent } = makeTuiApi();

    await tuiPlugin(api as any, undefined, {} as any);

    fireEvent('session.created', {
      type: 'session.created',
      properties: { info: { id: 'ses_child', parentID: 'ses_parent' } },
    });

    expect(navigateSpy).not.toHaveBeenCalled();
  });

  it('does NOT call route.navigate for events without an id', async () => {
    const { api, navigateSpy, fireEvent } = makeTuiApi();

    await tuiPlugin(api as any, undefined, {} as any);

    fireEvent('session.created', {
      type: 'session.created',
      properties: { info: {} },
    });

    expect(navigateSpy).not.toHaveBeenCalled();
  });

  it('navigates on each new root session (not just the first)', async () => {
    const { api, navigateSpy, fireEvent } = makeTuiApi();

    await tuiPlugin(api as any, undefined, {} as any);

    fireEvent('session.created', {
      type: 'session.created',
      properties: { info: { id: 'ses_first' } },
    });
    fireEvent('session.created', {
      type: 'session.created',
      properties: { info: { id: 'ses_second' } },
    });

    expect(navigateSpy).toHaveBeenCalledTimes(2);
    expect(navigateSpy).toHaveBeenNthCalledWith(1, 'session', { sessionID: 'ses_first' });
    expect(navigateSpy).toHaveBeenNthCalledWith(2, 'session', { sessionID: 'ses_second' });
  });

  it('survives a navigate() exception (plugin must not crash)', async () => {
    const { api, fireEvent } = makeTuiApi();
    api.route.navigate = vi.fn(() => { throw new Error('route unavailable'); });

    await tuiPlugin(api as any, undefined, {} as any);

    // Should not throw
    expect(() => {
      fireEvent('session.created', {
        type: 'session.created',
        properties: { info: { id: 'ses_erroring' } },
      });
    }).not.toThrow();
  });

  it('registers a dispose handler to unsubscribe the event listener', async () => {
    const { api } = makeTuiApi();

    await tuiPlugin(api as any, undefined, {} as any);

    expect(api.lifecycle.onDispose).toHaveBeenCalledOnce();
  });
});
