#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/types.h>
#include <pty.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

/* prctl(PR_SET_NAME, ...): rename the calling thread's "comm" field
   (visible in `ps` and /proc/<pid>/comm). PR_SET_NAME truncates to
   16 bytes including NUL — OS-level safe, no buffer-overrun risk.
   On non-Linux this is a no-op (no <sys/prctl.h> available). The
   return code is intentionally ignored: prctl never fails on Linux
   for PR_SET_NAME with a valid string, and on other platforms the
   call doesn't happen. */
CAMLprim value caml_c2c_set_proc_name(value vname)
{
    CAMLparam1(vname);
#ifdef __linux__
    (void)prctl(PR_SET_NAME, (unsigned long)String_val(vname), 0, 0, 0);
#else
    (void)vname;
#endif
    CAMLreturn(Val_unit);
}

/* setpgid(2): place the calling process in a new process group.
   OCaml 5.x's Unix module does not expose setpgid, so we bind it here. */
CAMLprim value caml_c2c_setpgid(value vpid, value vpgrp)
{
    int ret = setpgid((pid_t)Int_val(vpid), (pid_t)Int_val(vpgrp));
    if (ret < 0)
        caml_unix_error(errno, "setpgid", Nothing);
    return Val_unit;
}

/* getpgrp(2): return the process group ID of the calling process.
   OCaml's Unix module omits this call. */
CAMLprim value caml_c2c_getpgrp(value unit)
{
    (void)unit;
    return Val_int((int)getpgrp());
}

/* tcsetpgrp(3): set the foreground process group of the terminal.
   Required when we fork+setpgid the managed client in a tmux pane:
   without this, opencode/node detects it's in a background pg and
   exits 109 when reading the TTY. Errors are silently ignored because
   a) SIGTTOU is blocked in the caller to keep the call itself from
   suspending us, and b) the fd may not be a tty (detached launch). */
CAMLprim value caml_c2c_tcsetpgrp(value vfd, value vpgrp)
{
    struct sigaction sa, old_sa;
    sa.sa_handler = SIG_IGN;
    sa.sa_flags = 0;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTTOU, &sa, &old_sa);
    int ret = tcsetpgrp(Int_val(vfd), (pid_t)Int_val(vpgrp));
    sigaction(SIGTTOU, &old_sa, NULL);
    (void)ret; /* intentionally ignore error */
    return Val_unit;
}

/* forkpty_MasterChild: fork a child with a new PTY, return master fd to parent.
   Parent gets master_fd and child_pid; child already has slave as stdin/stdout/stderr.
   Returns pair (master_fd, child_pid). On error raises Unix error. */
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