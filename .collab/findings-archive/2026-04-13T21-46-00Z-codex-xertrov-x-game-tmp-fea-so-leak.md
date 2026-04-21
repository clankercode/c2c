# /tmp `.fea*.so` temporary library buildup

- **Symptom:** Claude Code was hitting bash errors while `/tmp` was nearly full. `df -h /tmp` showed the 16G tmpfs at 81% used with only 3.2G free.
- **How discovered:** `du -xhd1 /tmp` did not show a single visible directory accounting for the usage. A direct `find /tmp -xdev -maxdepth 1 -name '.fea*.so'` scan found 2,811 hidden shared-object files totaling about 11.9 GiB.
- **Root cause:** Repeated creation of top-level hidden temporary native library files named `/tmp/.fea*.so`. Exact producer not identified in this cleanup pass, but the files ranged from 2026-04-10 through 2026-04-14 and were each about 4.3 MiB.
- **Fix status:** Deleted `.fea*.so` files older than five minutes with:

  ```bash
  find /tmp -xdev -maxdepth 1 -name '.fea*.so' -type f -mmin +5 -print -delete
  ```

  This removed 2,807 files and reduced `/tmp` usage from 13G used / 3.2G free to 906M used / 15G free. Four recent `.fea*.so` files remained, totaling about 12.8 MiB.
- **Severity:** High operational friction. When `/tmp` fills, shells and agent tool calls can fail in confusing ways.
- **Follow-up:** Identify the producer of `.fea*.so` files and make it reuse or clean its extraction path. A recurring safe cleanup can target stale `/tmp/.fea*.so` files older than a few minutes, but the producer leak should be fixed rather than relying only on janitorial cleanup.
