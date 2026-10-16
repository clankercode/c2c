import { afterEach, describe, expect, it, vi } from 'vitest';
import C2CDelivery from '../../data/opencode-plugin/c2c';

describe('host-owned mailbox isolation', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    delete (globalThis as { __c2c_loaded?: boolean }).__c2c_loaded;
  });

  it.each(['C2C_NO_AUTO_REGISTER', 'C2C_MCP_DISABLED', 'C2C_HOST_OWNED_MAILBOX'])(
    '%s disables all plugin startup before reading sidecar or creating hooks',
    async (guard) => {
      vi.stubEnv('C2C_NO_AUTO_REGISTER', '0');
      vi.stubEnv('C2C_MCP_DISABLED', '0');
      vi.stubEnv('C2C_HOST_OWNED_MAILBOX', '0');
      vi.stubEnv(guard, '1');
      // With no native identity, normal startup would read the sidecar and
      // throw. A disabled plugin must not touch its context or claim loading.
      vi.stubEnv('C2C_MCP_SESSION_ID', '');
      vi.stubEnv('C2C_SESSION_ID', '');
      const context = new Proxy({}, {
        get() { throw new Error('disabled plugin accessed its host'); },
      });
      const hooks = await C2CDelivery(context as Parameters<typeof C2CDelivery>[0]);
      expect(hooks).toEqual({});
      expect((globalThis as { __c2c_loaded?: boolean }).__c2c_loaded).toBeUndefined();
    },
  );
});
