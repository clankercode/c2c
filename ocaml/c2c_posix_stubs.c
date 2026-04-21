#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <unistd.h>
#include <errno.h>

/* setpgid(2): place the calling process in a new process group.
   OCaml 5.x's Unix module does not expose setpgid, so we bind it here. */
CAMLprim value caml_c2c_setpgid(value vpid, value vpgid)
{
    int ret = setpgid((pid_t)Int_val(vpid), (pid_t)Int_val(vpgid));
    if (ret < 0)
        caml_unix_error(errno, "setpgid", Nothing);
    return Val_unit;
}
