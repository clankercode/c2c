/**
 * Smoke test: the plugin must be loadable.
 *
 * A syntax error here breaks every managed OpenCode session silently
 * (no DMs, no statefile, no permission relay). This test does the
 * cheapest possible check — it imports the plugin module and asserts
 * a default export exists. If the file fails to parse, this test fails
 * immediately.
 *
 * On 2026-04-22 a brace imbalance slipped in and took down the whole
 * swarm for ~40 minutes. This test is the guardrail so that doesn't
 * recur.
 */
import { describe, it, expect } from 'vitest';

describe('c2c plugin — loadable', () => {
  it('parses and exposes a default export', async () => {
    const mod = await import('../plugins/c2c.ts');
    expect(mod.default).toBeTruthy();
    expect(typeof mod.default).toBe('function');
  });
});
