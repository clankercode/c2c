# forkpty on Linux (libutil missing) — pty Slice 1

## Date
2026-04-25 UTC

## Problem
Initial pty implementation used `openpty(3)` from `libutil.so`. Build failed with:
```
/usr/bin/ld: undefined reference to `caml_c2c_openpty'
```

Investigation showed:
- `libutil.so` does not exist on CachyOS Linux (glibc 2.43)
- `util.h` header also missing
- `openpty(3)` is not in glibc itself — it's in the separate `libutil` addon library

## Solution
Replaced `openpty` with `forkpty(3)`, which is:
- In libc on all Unix systems (Linux, macOS, BSD)
- Atomically forks AND sets up the PTY (slave → stdin/stdout/stderr of child)
- Returns only to parent: `(master_fd, child_pid)`

```c
// forkpty signature:
pid_t forkpty(int *master, char *slave_name, struct termios *termp, struct winsize *winp);
// Returns child PID to parent, 0 to child, -1 on error
```

## C Stub
```c
CAMLprim value caml_c2c_forkpty_MasterChild(value vunit)
{
    (void)vunit;
    int master;
    pid_t pid = forkpty(&master, NULL, NULL, NULL);
    if (pid < 0)
        caml_unix_error(errno, "forkpty", Nothing);
    value result = caml_alloc_tuple(2);
    Store_field(result, 0, Val_int(master));
    Store_field(result, 1, Val_int(pid));
    return result;
}
```

Note: `forkpty` internally calls `openpty` then `fork` — same underlying functionality, just packaged differently. Requires `#include <pty.h>` (BSD-style) instead of `util.h`.

## Files Affected
- `ocaml/c2c_posix_stubs.c`: added `caml_c2c_forkpty_MasterChild`
- `ocaml/c2c_start.ml`: changed `openpty()` → `forkpty_MasterChild()`, simplified child code (slave already dup'd by forkpty)

## Severity
Build blocker on Linux systems without libutil installed. Medium — most systems have libutil but not guaranteed.