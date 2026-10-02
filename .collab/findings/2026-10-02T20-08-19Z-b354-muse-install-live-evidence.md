# B354 live-install evidence: skill store, plugin extras, cache identity, approve ordering

Date: 2026-10-02T20:08:19Z · Ticket: B354 · Runner: cli-user (B354 implementer)
Parent: `.collab/research/2026-10-02T18-55-00Z-muse-b352-spike-verdicts.md`
(B352 P4 verdicts — this doc extends them with B354 install-path proofs).

Safety: all probes ran under scratch `HOME`/`XDG_CONFIG_HOME`/`XDG_DATA_HOME`
in `/tmp/c2c-b354-*`; the operator's real muse config was never mutated
(one read-only copy of the non-secret feature-config grant
`7075626c6963.json` seeded the scratch gate; one read-only `auth.json`
symlink was NOT needed here — no meta/authed calls were made).

## 1. Owned-file skill at `$CONFIG_DIR/skills/c2c/` is honored (no CLI receipt)

B352 U8 showed user scope aggregates `~/.agents/skills` AND
`~/.claude/skills`, but did not probe `$CONFIG_DIR/skills/` (the
`skills install --scope user` target). B354 probed it:

```
$ # scratch HOME; hand-written skill, NO `skills install`, NO lockfile entry:
$ mkdir -p $FH/.config/muse/skills/c2c-direct   # SKILL.md with frontmatter
$ HOME=$FH ... muse skills list --source user
NAME            SCOPE  ACTIVATION  DESCRIPTION         PATH
c2c-direct      user   on          direct-write probe  $CONFIG_DIR/skills/c2c-direct/SKILL.md
c2c-probe       user   on          probe skill ...     $CONFIG_DIR/skills/c2c-probe/SKILL.md
$ HOME=$FH ... muse skills validate $FH/.config/muse/skills/c2c-direct
valid   c2c-direct
```

And the real install (`c2c install muse` in scratch HOME):

```
$ muse skills list --source user
c2c  user  on  Muse + c2c: use when messaging other AI coding agents, ...  $CONFIG_DIR/skills/c2c/SKILL.md
```

Verdict: the skill is a plain c2c-owned file. No `skills install` shelling,
no lockfile/receipt handling. (`skills install` copies into the same dir;
direct writes are simply not tracked — listing works either way.)

## 2. Plugin manifest extras (`timeoutMs`, `statusMessage`, `compat.source`) validate

The B352 A4 probe used a minimal `{id, event, command}` hook item. B354
ships `timeoutMs: 10000` + `statusMessage` per hook and
`compat: {source: native, manifestDir}` per muse's own
capability-examples contract (shipped in the `muse-core` builtin plugin).
Live validation of the exact bytes `c2c install muse` writes:

```
$ muse plugins validate $HOME/.c2c/clients/muse/plugin
valid   c2c   native   skills=0 commands=0 hooks=3 mcp=0 reminders=0 diagnostics=0
```

Zero diagnostics: the extras are accepted, not merely tolerated.

## 3. Reinstall is idempotent and keeps trust

```
$ muse plugins install $B/c2c            # second install, unchanged bundle
installed  c2c  0.0.0  enabled=true ... cache=.../97329ca3.../package   # SAME hash
$ muse plugins inspect c2c | grep -c trusted_enabled
3
```

Same cache hash, all three capabilities stay `trusted_enabled`.
`c2c install muse` re-runs are therefore safe (no remove-then-add dance).

## 4. `installed.json` shape + cache identity (uninstall fallback targets)

```
$ cat <data>/muse/plugins/installed.json
{"version":1,"plugins":{"c2c":{"id":"c2c",...,
  "source":{"provenance":"native-local","path":"<bundle>"},
  "cache_path":"plugins/cache/local/c2c/<sha256>/package", ...}}}
$ ls <data>/muse/plugins/cache/local/c2c/<sha256>/package/.muse-plugin/plugin.json
```

`plugins remove c2c` is the primary uninstall verb (removes record +
cache). The no-CLI fallback deletes `cache/local/c2c/` (stable parent —
the `<sha256>` dir changes per update) and drops the `plugins.c2c` key.

## 5. `remove` on absent id exits 1 with "is not installed" (clean, not a warning)

```
$ muse plugins remove c2c     # nothing installed
plugin `c2c` is not installed
exit=1
```

Every fallback-path uninstall hits this (no plugin was ever installed), so
`muse_plugin_remove` maps `is not installed` to ok — no spurious warning.

## 6. LOAD-BEARING: any `settings.json` write AFTER approve resets trust to `review_needed`

Found during B354 review-fix (flip test): a fallback install followed by a
gate-open reinstall reported "installed + approved" but `inspect` showed
`review_needed` on all three capabilities. Bisected live:

```
$ muse plugins approve c2c; inspect -> 3 trusted            # baseline
$ echo '{"schema_version":1,"note":"hookless"}' > settings.json
$ inspect -> 0 trusted                                       # HOOKLESS write resets
$ muse plugins approve c2c; <write settings WITH hooks>
$ inspect -> 0 trusted                                       # hooked write resets too
```

Even a hookless write resets. Manual install+approve sequences (no
interleaved c2c settings write) stick 3/3 every time, so the trigger is the
write order, not the spawn shape (stdin/stdout redirect, env, cwd, and
list-before-install were each isolated and ruled out).

Fix (in `setup_muse`): install -> settings merge/strip -> **approve LAST**.
Verified live after the fix: gated->open flip ends with 3 `trusted_enabled`
AND zero stale settings hooks; `--with-mcp` plugin path ends 3/3 as well.
`merge(stripped) = merge(existing)`, so the approve-failure fallback (merge
hooks after a failed approve) composes exactly.
