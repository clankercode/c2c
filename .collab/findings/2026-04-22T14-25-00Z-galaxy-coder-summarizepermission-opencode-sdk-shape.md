# galaxy-coder: summarizePermission investigation

**Date**: 2026-04-22
**Issue**: OpenCode plugin supervisor DMs showed "action: unknown" for permission requests

## Root Cause

OpenCode SDK emits permission events with field names `type` and `pattern` (singular):

```typescript
{
  type: 'bash',
  pattern: 'echo hi',
  id: 'perm-123',
  sessionID: 'session-abc'
}
```

But `summarizePermission` expected `permission` and `patterns` (plural):

```typescript
{
  permission: 'bash',
  patterns: ['echo hi'],
  ...
}
```

## Fix

Modified `summarizePermission` in `.opencode/plugins/c2c.ts` to accept both shapes:
- `perm.permission` OR `perm.type` for the permission name
- `perm.patterns` OR `perm.pattern` (as string, wrapped in array) for the action

**Commit**: ce2467c

## Note on Tests

The todo item description said "tests use `type` field but function expects `permission` field" - this was incorrect. The **unit tests** for `summarizePermission` (lines 958-1016 in `c2c-plugin.unit.test.ts`) correctly use `permission` and `patterns`. The **integration tests** (around line 396) use `type`/`pattern` which is the OpenCode SDK shape.

The actual bug was in the function itself, not the tests.
