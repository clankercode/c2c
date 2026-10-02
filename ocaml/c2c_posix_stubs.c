#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <dirent.h>
#include <limits.h>
#include <stdlib.h>
#include <signal.h>
#ifdef __linux__
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#endif

/* Open a lifecycle record without ever following a symlink.  OCaml's Unix
   module does not expose O_NOFOLLOW on all supported versions, while a
   check-then-open pair would leave a symlink replacement race. */
CAMLprim value caml_c2c_open_regular_nofollow(value vpath)
{
    CAMLparam1(vpath);
    const char *path = String_val(vpath);
    struct stat before;
    int initial_lstat_found = 0;
    if (lstat(path, &before) < 0)
        caml_unix_error(errno, "lstat", vpath);
    initial_lstat_found = 1;
    if (!S_ISREG(before.st_mode)) {
        errno = EINVAL;
        caml_unix_error(errno, "lstat", vpath);
    }
    /* Test-only pause used to make the lstat/open replacement window
       deterministic.  The production path is unchanged when these
       variables are absent. */
    const char *ready = getenv("C2C_TEST_OPEN_REGULAR_READY");
    if (ready != NULL && *ready != '\0') {
        int ready_fd = open(ready, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (ready_fd >= 0)
            close(ready_fd);
    }
    const char *pause = getenv("C2C_TEST_OPEN_REGULAR_PAUSE_MS");
    if (pause != NULL && *pause != '\0') {
        char *end = NULL;
        long ms = strtol(pause, &end, 10);
        if (end != pause && ms > 0 && ms < 60000)
            (void)usleep((useconds_t)ms * 1000U);
    }
#ifdef O_NOFOLLOW
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
#else
    int fd = -1;
    errno = ENOSYS;
    caml_unix_error(errno, "open", vpath);
#endif
    if (fd < 0) {
        /* ENOENT from this open is a removal/replacement after the positive
           lstat above, so it is unreadable/unknown.  Only the initial lstat
           is allowed to establish confirmed absence. */
        int saved = errno;
        if (saved == ENOENT && initial_lstat_found)
            saved = EAGAIN;
        errno = saved;
        caml_unix_error(errno, "open", vpath);
    }
    struct stat after;
    int fstat_ok = fstat(fd, &after) == 0;
    if (!fstat_ok || !S_ISREG(after.st_mode)
        || before.st_dev != after.st_dev || before.st_ino != after.st_ino) {
        int saved = fstat_ok ? EAGAIN : errno;
        close(fd);
        errno = saved;
        caml_unix_error(errno, "fstat", vpath);
    }
    CAMLreturn(Val_int(fd));
}

/* Quarantine lifecycle records under an exclusive lock on their parent
   directory. A per-file lock is insufficient: atomic writers replace the
   pathname and do not necessarily open the old lock inode. The operation
   moves the opened inode to a private quarantine name and leaves both the
   quarantine and rollback links in place. There is no safe portable operation
   to consume a pathname after a non-cooperating writer may have replaced it. */
#ifdef __linux__
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif
#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1U << 1)
#endif
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

static int c2c_rename_noreplace_at(int dirfd, const char *from,
                                    const char *to)
{
#ifdef __NR_renameat2
    return (int)syscall(__NR_renameat2, dirfd, from, dirfd, to,
                        RENAME_NOREPLACE);
#else
    (void)dirfd;
    (void)from;
    (void)to;
    errno = ENOSYS;
    return -1;
#endif
}

static int c2c_rename_exchange_at(int dirfd, const char *from,
                                  const char *to)
{
#ifdef __NR_renameat2
    return (int)syscall(__NR_renameat2, dirfd, from, dirfd, to,
                        RENAME_EXCHANGE);
#else
    (void)dirfd;
    (void)from;
    (void)to;
    errno = ENOSYS;
    return -1;
#endif
}

static int c2c_split_path(const char *path, char *parent, size_t parent_len,
                          char *base, size_t base_len)
{
    const char *slash = strrchr(path, '/');
    const char *name = slash == NULL ? path : slash + 1;
    if (*name == '\0' || strlen(name) + 1 > base_len)
        return -1;
    strcpy(base, name);
    if (slash == NULL) {
        if (parent_len < 2) return -1;
        strcpy(parent, ".");
    } else if (slash == path) {
        if (parent_len < 2) return -1;
        strcpy(parent, "/");
    } else {
        size_t n = (size_t)(slash - path);
        if (n + 1 > parent_len) return -1;
        memcpy(parent, path, n);
        parent[n] = '\0';
    }
    return 0;
}

static int c2c_open_locked_parent(const char *path, char *parent,
                                  size_t parent_len, char *base,
                                  size_t base_len)
{
    if (c2c_split_path(path, parent, parent_len, base, base_len) < 0)
        return -1;
    int flags = O_RDONLY;
#ifdef O_DIRECTORY
    flags |= O_DIRECTORY;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    int dirfd = open(parent, flags);
    if (dirfd < 0 || flock(dirfd, LOCK_EX) < 0) {
        if (dirfd >= 0) close(dirfd);
        return -1;
    }
    return dirfd;
}

static int c2c_path_absent_at(int dirfd, const char *name)
{
    struct stat st;
    if (fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0)
        return 0;
    return errno == ENOENT ? 1 : -1;
}

/* Recovery entries are deliberately never removed by this helper.  Once a
   record has been moved to one of these names, a later pathname operation
   cannot prove that the name still denotes the original inode: a
   non-cooperating writer may have replaced it after any fstatat check. */
static int c2c_recovery_artifacts_at(int dirfd, const char *base)
{
    char unlink_prefix[NAME_MAX + 64];
    char rollback_prefix[NAME_MAX + 64];
    int unlink_len = snprintf(unlink_prefix, sizeof(unlink_prefix),
                              ".%s.c2c-unlink.", base);
    int rollback_len = snprintf(rollback_prefix, sizeof(rollback_prefix),
                                ".%s.c2c-rollback.", base);
    if (unlink_len < 0 || rollback_len < 0
        || (size_t)unlink_len >= sizeof(unlink_prefix)
        || (size_t)rollback_len >= sizeof(rollback_prefix))
        return -1;
    int scanfd = dup(dirfd);
    if (scanfd < 0)
        return -1;
    DIR *dir = fdopendir(scanfd);
    if (dir == NULL) {
        close(scanfd);
        return -1;
    }
    int found = 0;
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if ((strncmp(entry->d_name, unlink_prefix, (size_t)unlink_len) == 0
             && entry->d_name[unlink_len] != '\0')
            || (strncmp(entry->d_name, rollback_prefix, (size_t)rollback_len) == 0
                && entry->d_name[rollback_len] != '\0')) {
            found = 1;
            break;
        }
    }
    int scan_error = errno;
    closedir(dir);
    return scan_error != 0 ? -1 : found;
}

/* 0 = canonical path is present; 1 = absent and has no recovery artifact;
   2 = absent but quarantine/rollback recovery exists; 3 = unknown. */
CAMLprim value caml_c2c_lifecycle_path_state(value vpath)
{
    CAMLparam1(vpath);
    char parent[PATH_MAX], base[NAME_MAX + 1];
    if (c2c_split_path(String_val(vpath), parent, sizeof(parent), base,
                       sizeof(base)) < 0)
        CAMLreturn(Val_int(3));
    int dirfd = c2c_open_locked_parent(String_val(vpath), parent,
                                       sizeof(parent), base, sizeof(base));
    if (dirfd < 0)
        CAMLreturn(errno == ENOENT ? Val_int(1) : Val_int(3));
    struct stat st;
    int artifacts = c2c_recovery_artifacts_at(dirfd, base);
    int result;
    /* A recovery artifact makes the public pathname untrustworthy even if a
       non-cooperating writer has since installed a replacement there.  Scan
       artifacts before accepting the pathname as an ordinary present record;
       otherwise callers could read or overwrite the replacement while the
       original inode remains quarantined. */
    if (artifacts < 0) {
        result = 3;
    } else if (artifacts > 0) {
        result = 2;
    } else if (fstatat(dirfd, base, &st, AT_SYMLINK_NOFOLLOW) == 0) {
        result = 0;
    } else if (errno != ENOENT) {
        result = 3;
    } else {
        result = 1;
    }
    flock(dirfd, LOCK_UN);
    close(dirfd);
    CAMLreturn(Val_int(result));
}

static int c2c_quarantine_name(char *out, size_t out_len, const char *base,
                               unsigned int attempt)
{
    int n = snprintf(out, out_len, ".%s.c2c-unlink.%ld.%u", base,
                     (long)getpid(), attempt);
    return n >= 0 && (size_t)n < out_len;
}

/* Once the original has been moved out of [base], occupy [base] with a
   non-empty directory. A regular-file atomic rename cannot replace a
   non-empty directory, so scanners cannot mistake the public name for a
   confirmed regular-file absence while recovery artifacts remain. */
#define C2C_UNLINK_GUARD_CHILD ".c2c-hold"

struct c2c_prepared_unlink {
    int fd;
    struct stat before;
    struct stat guard;
    struct stat guard_child;
    char base[NAME_MAX + 1];
    char quarantine[NAME_MAX + 64];
    char rollback[NAME_MAX + 64];
    int moved;
    int guarded;
    int rollback_created;
    const char *expected;
    size_t expected_len;
    int check_contents;
};

static void c2c_test_unlink_hook(const char *ready_env,
                                 const char *pause_env)
{
    const char *ready = getenv(ready_env);
    if (ready != NULL && *ready != '\0') {
        int fd = open(ready, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0)
            close(fd);
    }
    const char *pause = getenv(pause_env);
    if (pause != NULL && *pause != '\0') {
        char *end = NULL;
        long ms = strtol(pause, &end, 10);
        if (end != pause && ms > 0 && ms < 60000)
            (void)usleep((useconds_t)ms * 1000U);
    }
}

static int c2c_install_unlink_guard(int dirfd, const char *base,
                                    struct c2c_prepared_unlink *p)
{
    if (mkdirat(dirfd, base, 0700) < 0)
        return 0;
    int guardfd = -1;
    int holdfd = -1;
    int flags = O_RDONLY;
#ifdef O_DIRECTORY
    flags |= O_DIRECTORY;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    guardfd = openat(dirfd, base, flags);
    if (guardfd >= 0) {
        int hold_flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_CLOEXEC
        hold_flags |= O_CLOEXEC;
#endif
        holdfd = openat(guardfd, C2C_UNLINK_GUARD_CHILD, hold_flags, 0600);
    }
    if (holdfd >= 0) {
        int identity_ok = fstat(guardfd, &p->guard) == 0
                          && fstatat(guardfd, C2C_UNLINK_GUARD_CHILD,
                                     &p->guard_child, AT_SYMLINK_NOFOLLOW) == 0
                          && S_ISDIR(p->guard.st_mode)
                          && S_ISREG(p->guard_child.st_mode);
        close(holdfd);
        if (!identity_ok)
            holdfd = -1;
    }
    /* Keep the non-empty guard directory non-writable while the quarantined
       inode is being validated and removed.  A same-user writer cannot remove
       the guard and replace the public pathname in that interval.  The
       cleanup path temporarily restores write permission only after the
       quarantined inode has been dealt with. */
    if (guardfd >= 0 && holdfd >= 0 && fchmod(guardfd, 0500) < 0)
        holdfd = -1;
    if (guardfd >= 0)
        close(guardfd);
    if (holdfd >= 0)
        return 1;
    /* The guard pathname may have been replaced after mkdirat/openat.  Never
       remove it by name on this uncertainty path; retaining a possibly
       incomplete guard is safer than deleting a replacement or the last
       recovery artifact. */
    return 0;
}

static int c2c_unlink_guard_intact(int dirfd,
                                   const struct c2c_prepared_unlink *p)
{
    struct stat guard;
    if (fstatat(dirfd, p->base, &guard, AT_SYMLINK_NOFOLLOW) < 0
        || !S_ISDIR(guard.st_mode)
        || guard.st_dev != p->guard.st_dev
        || guard.st_ino != p->guard.st_ino)
        return 0;
    int flags = O_RDONLY;
#ifdef O_DIRECTORY
    flags |= O_DIRECTORY;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    int guardfd = openat(dirfd, p->base, flags);
    if (guardfd < 0)
        return 0;
    struct stat child;
    int ok = fstat(guardfd, &guard) == 0
             && guard.st_dev == p->guard.st_dev
             && guard.st_ino == p->guard.st_ino
             && fstatat(guardfd, C2C_UNLINK_GUARD_CHILD, &child,
                        AT_SYMLINK_NOFOLLOW) == 0
             && S_ISREG(child.st_mode)
             && child.st_dev == p->guard_child.st_dev
             && child.st_ino == p->guard_child.st_ino;
    close(guardfd);
    return ok;
}

static void c2c_restore_prepared(int dirfd, struct c2c_prepared_unlink *p)
{
    (void)dirfd;
    /* Once a pathname has been quarantined, restoration would itself be a
       check-then-rename operation on a replaceable pathname. Keep every
       quarantine, rollback, and guard entry reachable and let the caller
       retain lifecycle state for a later, explicitly audited recovery pass. */
    if (p->fd >= 0) {
        close(p->fd);
        p->fd = -1;
    }
}

static int c2c_rollback_name(char *out, size_t out_len, const char *base,
                              unsigned int attempt)
{
    int n = snprintf(out, out_len, ".%s.c2c-rollback.%ld.%u", base,
                     (long)getpid(), attempt);
    return n >= 0 && (size_t)n < out_len;
}

static int c2c_make_rollback_link(int dirfd, struct c2c_prepared_unlink *p,
                                  unsigned int seed)
{
    struct stat linked;
    for (unsigned int attempt = seed; attempt != seed + 32; ++attempt) {
        if (!c2c_rollback_name(p->rollback, sizeof(p->rollback), p->base,
                               attempt))
            return 0;
        if (linkat(dirfd, p->quarantine, dirfd, p->rollback, 0) == 0) {
            if (fstatat(dirfd, p->rollback, &linked, AT_SYMLINK_NOFOLLOW) == 0
                && S_ISREG(linked.st_mode)
                && linked.st_dev == p->before.st_dev
                && linked.st_ino == p->before.st_ino) {
                p->rollback_created = 1;
                return 1;
            }
            /* The pathname may have been replaced after [linkat]. Preserve
               it on uncertainty; a later recovery pass can classify it. */
            return 0;
        }
        return 0;
    }
    return 0;
}

/* Link the inode already pinned by [p->fd] before touching its pathname.  The
   link is the recovery copy used when a pathname replacement races the
   exchange below. */
static int c2c_make_fd_rollback_link(int dirfd,
                                     struct c2c_prepared_unlink *p,
                                     unsigned int seed)
{
    struct stat linked;
    for (unsigned int attempt = seed; attempt != seed + 32; ++attempt) {
        if (!c2c_rollback_name(p->rollback, sizeof(p->rollback), p->base,
                               attempt))
            return 0;
        if (linkat(p->fd, "", dirfd, p->rollback, AT_EMPTY_PATH) == 0) {
            if (fstatat(dirfd, p->rollback, &linked, AT_SYMLINK_NOFOLLOW) == 0
                && S_ISREG(linked.st_mode)
                && linked.st_dev == p->before.st_dev
                && linked.st_ino == p->before.st_ino) {
                p->rollback_created = 1;
                return 1;
            }
            /* Never unlink an identity-uncertain rollback pathname. */
            return 0;
        }
        return 0;
    }
    return 0;
}

static int c2c_read_fd_equals(int fd, const char *expected,
                              size_t expected_len)
{
    size_t used = 0;
    char buf[256];
    while (used < expected_len) {
        size_t want = expected_len - used;
        if (want > sizeof(buf))
            want = sizeof(buf);
        ssize_t n = read(fd, buf, want);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return 0;
        }
        if (n == 0)
            return 0;
        if (memcmp(buf, expected + used, (size_t)n) != 0)
            return 0;
        used += (size_t)n;
    }
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return 0;
        }
        if (n == 0)
            return 1;
        return 0;
    }
}

/* Prepare an unlink by atomically exchanging the public pathname with a
   non-empty guard directory.  Once the exchange succeeds, an atomic rename
   cannot replace the public pathname, so the inode opened and checked here is
   the only inode that can be finalized.  The pre-exchange rollback link keeps
   that inode durable if a replacement wins the race before the exchange. */
static int c2c_prepare_unlink_exchanged_at(int dirfd, const char *base,
                                           unsigned int seed,
                                           const char *expected,
                                           size_t expected_len,
                                           struct c2c_prepared_unlink *p)
{
    int flags = O_RDONLY;
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    memset(p, 0, sizeof(*p));
    p->fd = -1;
    p->expected = expected;
    p->expected_len = expected_len;
    p->check_contents = 1;
    memcpy(p->base, base, strlen(base) + 1);
    p->fd = openat(dirfd, base, flags);
    if (p->fd < 0)
        return 0;
    struct stat named;
    if (fstat(p->fd, &p->before) < 0 || !S_ISREG(p->before.st_mode)
        || p->before.st_nlink != 1
        || fstatat(dirfd, base, &named, AT_SYMLINK_NOFOLLOW) < 0
        || !S_ISREG(named.st_mode) || named.st_dev != p->before.st_dev
        || named.st_ino != p->before.st_ino
        || !c2c_read_fd_equals(p->fd, expected, expected_len)
        || !c2c_make_fd_rollback_link(dirfd, p, seed + 1000)) {
        c2c_restore_prepared(dirfd, p);
        return 0;
    }
    c2c_test_unlink_hook("C2C_TEST_UNLINK_BEFORE_EXCHANGE",
                         "C2C_TEST_UNLINK_PAUSE_MS");
    for (unsigned int attempt = seed; attempt != seed + 32; ++attempt) {
        if (!c2c_quarantine_name(p->quarantine, sizeof(p->quarantine), base,
                                 attempt))
            break;
        if (c2c_install_unlink_guard(dirfd, p->quarantine, p)) {
            if (c2c_rename_exchange_at(dirfd, base, p->quarantine) == 0) {
                p->moved = 1;
                p->guarded = 1;
                struct stat exchanged;
                if (fstatat(dirfd, p->quarantine, &exchanged,
                            AT_SYMLINK_NOFOLLOW) == 0
                    && S_ISREG(exchanged.st_mode)
                    && exchanged.st_dev == p->before.st_dev
                    && exchanged.st_ino == p->before.st_ino
                    && c2c_unlink_guard_intact(dirfd, p))
                    return 1;
                /* The pathname changed before the exchange. Restore the
                   replacement to its public name, but keep the original
                   rollback link for retry and forensics. */
                c2c_restore_prepared(dirfd, p);
                return 0;
            }
            break;
        } else {
            struct stat collision;
            if (fstatat(dirfd, p->quarantine, &collision,
                        AT_SYMLINK_NOFOLLOW) < 0
                && errno == ENOENT)
                break;
        }
    }
    c2c_restore_prepared(dirfd, p);
    return 0;
}

/* A failed finalization must preserve every pathname that can still reach the
   original inode. Once a record has been quarantined, there is no safe
   pathname operation that can consume either recovery link. */
static void c2c_retain_prepared(int dirfd, struct c2c_prepared_unlink *p)
{
    (void)dirfd;
    if (p->fd >= 0) {
        close(p->fd);
        p->fd = -1;
    }
}

static int c2c_prepare_unlink_at(int dirfd, const char *base, unsigned int seed,
                                 struct c2c_prepared_unlink *p)
{
    int flags = O_RDONLY;
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    memset(p, 0, sizeof(*p));
    p->fd = -1;
    memcpy(p->base, base, strlen(base) + 1);
    p->fd = openat(dirfd, base, flags);
    if (p->fd < 0)
        return errno == ENOENT ? -1 : 0;
    struct stat named, moved;
    if (fstat(p->fd, &p->before) < 0 || !S_ISREG(p->before.st_mode)
        || p->before.st_nlink != 1
        || fstatat(dirfd, base, &named, AT_SYMLINK_NOFOLLOW) < 0
        || !S_ISREG(named.st_mode) || named.st_dev != p->before.st_dev
        || named.st_ino != p->before.st_ino) {
        c2c_restore_prepared(dirfd, p);
        return 0;
    }
    int moved_ok = 0;
    for (unsigned int attempt = seed; attempt != seed + 32; ++attempt) {
        if (!c2c_quarantine_name(p->quarantine, sizeof(p->quarantine), base,
                                 attempt))
            break;
        if (c2c_rename_noreplace_at(dirfd, base, p->quarantine) == 0) {
            p->moved = 1;
            moved_ok = 1;
            break;
        }
        break;
    }
    if (!moved_ok
        || fstatat(dirfd, p->quarantine, &moved, AT_SYMLINK_NOFOLLOW) < 0
        || !S_ISREG(moved.st_mode) || moved.st_dev != p->before.st_dev
        || moved.st_ino != p->before.st_ino
        || c2c_path_absent_at(dirfd, base) != 1) {
        c2c_restore_prepared(dirfd, p);
        return 0;
    }
    c2c_test_unlink_hook("C2C_TEST_UNLINK_QUARANTINED_PATH",
                         "C2C_TEST_UNLINK_PAUSE_MS");
    if (!c2c_install_unlink_guard(dirfd, base, p)) {
        c2c_restore_prepared(dirfd, p);
        return 0;
    }
    p->guarded = 1;
    if (!c2c_make_rollback_link(dirfd, p, seed + 1000)) {
        c2c_restore_prepared(dirfd, p);
        return 0;
    }
    return 1;
}

static int c2c_finish_unlink_at(int dirfd, struct c2c_prepared_unlink *p)
{
    c2c_test_unlink_hook("C2C_TEST_UNLINK_BEFORE_FINISH",
                         "C2C_TEST_UNLINK_PAUSE_MS");
    if (p->check_contents) {
        if (lseek(p->fd, 0, SEEK_SET) < 0
            || !c2c_read_fd_equals(p->fd, p->expected, p->expected_len)) {
            c2c_retain_prepared(dirfd, p);
            return 0;
        }
    }
    struct stat fd_st, quarantine_st, rollback_st;
    if (!p->moved || !p->guarded || !p->rollback_created
        || fstat(p->fd, &fd_st) < 0
        || fd_st.st_dev != p->before.st_dev
        || fd_st.st_ino != p->before.st_ino
        || fstatat(dirfd, p->quarantine, &quarantine_st,
                   AT_SYMLINK_NOFOLLOW) < 0
        || !S_ISREG(quarantine_st.st_mode)
        || quarantine_st.st_dev != p->before.st_dev
        || quarantine_st.st_ino != p->before.st_ino
        || fstatat(dirfd, p->rollback, &rollback_st,
                   AT_SYMLINK_NOFOLLOW) < 0
        || !S_ISREG(rollback_st.st_mode)
        || rollback_st.st_dev != p->before.st_dev
        || rollback_st.st_ino != p->before.st_ino
        || !c2c_unlink_guard_intact(dirfd, p)) {
        c2c_retain_prepared(dirfd, p);
        return 0;
    }
    /* The parent lock and identity-pinned non-empty guard prevent a
       cooperating lifecycle writer from changing these names. Remove the
       public guard first; if a later recovery-link removal fails, at least
       one exact link remains reachable. */
    int guardfd = openat(dirfd, p->base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    struct stat final_guard, final_child;
    if (guardfd < 0
        || fstat(guardfd, &final_guard) < 0
        || final_guard.st_dev != p->guard.st_dev
        || final_guard.st_ino != p->guard.st_ino
        || fstatat(guardfd, C2C_UNLINK_GUARD_CHILD, &final_child,
                   AT_SYMLINK_NOFOLLOW) < 0
        || final_child.st_dev != p->guard_child.st_dev
        || final_child.st_ino != p->guard_child.st_ino
        || fchmod(guardfd, 0700) < 0
        || unlinkat(guardfd, C2C_UNLINK_GUARD_CHILD, 0) < 0) {
        if (guardfd >= 0)
            close(guardfd);
        c2c_retain_prepared(dirfd, p);
        return 0;
    }
    close(guardfd);
    if (unlinkat(dirfd, p->base, AT_REMOVEDIR) < 0) {
        c2c_retain_prepared(dirfd, p);
        return 0;
    }
    if (unlinkat(dirfd, p->quarantine, 0) < 0
        || unlinkat(dirfd, p->rollback, 0) < 0) {
        c2c_retain_prepared(dirfd, p);
        return 0;
    }
    c2c_retain_prepared(dirfd, p);
    return 1;
}

static int c2c_unlink_one_at(int dirfd, const char *base, unsigned int seed)
{
    struct c2c_prepared_unlink p;
    int prepared = c2c_prepare_unlink_at(dirfd, base, seed, &p);
    if (prepared < 0) {
        int artifacts = c2c_recovery_artifacts_at(dirfd, base);
        return artifacts == 0 ? 1 : 0;
    }
    if (!prepared)
        return 0;
    return c2c_finish_unlink_at(dirfd, &p);
}
#else
CAMLprim value caml_c2c_lifecycle_path_state(value vpath)
{
    CAMLparam1(vpath);
    (void)vpath;
    CAMLreturn(Val_int(3));
}
#endif

CAMLprim value caml_c2c_unlink_regular_confirmed(value vpath)
{
    CAMLparam1(vpath);
#if defined(__linux__) && defined(O_NOFOLLOW)
    const char *path = String_val(vpath);
    char parent[PATH_MAX], base[NAME_MAX + 1];
    int dirfd = c2c_open_locked_parent(path, parent, sizeof(parent), base,
                                       sizeof(base));
    if (dirfd < 0)
        CAMLreturn(errno == ENOENT ? Val_true : Val_false);
    int result = c2c_unlink_one_at(dirfd, base, 0);
    flock(dirfd, LOCK_UN);
    close(dirfd);
    CAMLreturn(result == 1 ? Val_true : Val_false);
#else
    CAMLreturn(Val_false);
#endif
}

CAMLprim value caml_c2c_unlink_regular_if_contents_confirmed(value vpath,
                                                              value vexpected)
{
    CAMLparam2(vpath, vexpected);
#ifdef __linux__
    const char *path = String_val(vpath);
    char parent[PATH_MAX], base[NAME_MAX + 1];
    int dirfd = c2c_open_locked_parent(path, parent, sizeof(parent), base,
                                       sizeof(base));
    if (dirfd < 0)
        CAMLreturn(Val_false);
    struct c2c_prepared_unlink prepared;
    int result = 0;
    if (c2c_prepare_unlink_exchanged_at(dirfd, base, 200,
                                        String_val(vexpected),
                                        caml_string_length(vexpected),
                                        &prepared) == 1) {
        result = c2c_finish_unlink_at(dirfd, &prepared);
    }
    flock(dirfd, LOCK_UN);
    close(dirfd);
    CAMLreturn(result ? Val_true : Val_false);
#else
    CAMLreturn(Val_false);
#endif
}

static int c2c_read_exact_long(int fd, long expected)
{
    /* Keep the parser bounded, but read far enough to prove EOF.  A single
       read of 63 bytes incorrectly accepted a valid numeric prefix followed
       by junk beyond the buffer. */
    char buf[64];
    size_t used = 0;
    while (used < sizeof(buf) - 1) {
        ssize_t n = read(fd, buf + used, (sizeof(buf) - 1) - used);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return 0;
        }
        if (n == 0)
            break;
        used += (size_t)n;
    }
    if (used == sizeof(buf) - 1) {
        char extra;
        ssize_t n;
        do {
            n = read(fd, &extra, 1);
        } while (n < 0 && errno == EINTR);
        if (n < 0 || n > 0)
            return 0;
    }
    if (used == 0)
        return 0;
    buf[used] = '\0';
    char *end = NULL;
    long value = strtol(buf, &end, 10);
    if (end == buf)
        return 0;
    while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n') ++end;
    return *end == '\0' && value == expected;
}

/* The paired form is used for PID/start-time records. It holds one parent
   directory lock while checking both exact values and while quarantining both
   entries, so a replacement cannot be mistaken for either half of the pair. */
CAMLprim value caml_c2c_unlink_pid_record_pair_confirmed(value vpid_path,
                                                         value vst_path,
                                                         value vpid,
                                                         value vst)
{
    CAMLparam4(vpid_path, vst_path, vpid, vst);
#ifdef __linux__
    char parent[PATH_MAX], pid_name[NAME_MAX + 1];
    char st_parent[PATH_MAX], st_name[NAME_MAX + 1];
    if (c2c_split_path(String_val(vpid_path), parent, sizeof(parent), pid_name,
                       sizeof(pid_name)) < 0
        || c2c_split_path(String_val(vst_path), st_parent, sizeof(st_parent),
                          st_name, sizeof(st_name)) < 0
        || strcmp(parent, st_parent) != 0)
        CAMLreturn(Val_false);
    int dirfd = c2c_open_locked_parent(String_val(vpid_path), parent,
                                       sizeof(parent), pid_name,
                                       sizeof(pid_name));
    if (dirfd < 0)
        CAMLreturn(Val_false);
    int pid_fd = openat(dirfd, pid_name, O_RDONLY | O_NOFOLLOW);
    int st_fd = openat(dirfd, st_name, O_RDONLY | O_NOFOLLOW);
    int ok = pid_fd >= 0 && st_fd >= 0;
    struct stat pid_st, st_st;
    if (ok)
        ok = fstat(pid_fd, &pid_st) == 0 && fstat(st_fd, &st_st) == 0
             && S_ISREG(pid_st.st_mode) && S_ISREG(st_st.st_mode)
             && pid_st.st_nlink == 1 && st_st.st_nlink == 1
             && c2c_read_exact_long(pid_fd, (long)Int_val(vpid))
             && c2c_read_exact_long(st_fd, Long_val(vst));
    if (pid_fd >= 0) close(pid_fd);
    if (st_fd >= 0) close(st_fd);
    int result = 0;
    if (ok) {
        struct c2c_prepared_unlink pid_record;
        struct c2c_prepared_unlink start_record;
        int pid_prepared = c2c_prepare_unlink_at(dirfd, pid_name, 101,
                                                 &pid_record);
        if (pid_prepared == 1) {
            int start_prepared = c2c_prepare_unlink_at(dirfd, st_name, 102,
                                                      &start_record);
            if (start_prepared == 1
                && c2c_read_exact_long(pid_record.fd, (long)Int_val(vpid))
                && c2c_read_exact_long(start_record.fd, Long_val(vst))
                && c2c_unlink_guard_intact(dirfd, &pid_record)
                && c2c_unlink_guard_intact(dirfd, &start_record)) {
                /* Both guards are installed before either quarantine entry is
                   touched. Rollback links keep both exact original inodes
                   recoverable; neither recovery name is ever consumed. */
                int pid_done = c2c_finish_unlink_at(dirfd, &pid_record);
                int start_done = c2c_finish_unlink_at(dirfd, &start_record);
                result = pid_done && start_done;
            } else {
                if (start_prepared == 1)
                    c2c_restore_prepared(dirfd, &start_record);
                c2c_restore_prepared(dirfd, &pid_record);
            }
        } else if (pid_prepared < 0) {
            /* Both records were opened above, so an absent first half is not
               a confirmed pair absence. Preserve the existing false result. */
            result = 0;
        }
    }
    flock(dirfd, LOCK_UN);
    close(dirfd);
    CAMLreturn(result ? Val_true : Val_false);
#else
    CAMLreturn(Val_false);
#endif
}
#include <sys/types.h>
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <util.h>
#else
#include <pty.h>
#endif
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

/* tcgetpgrp(3): read the terminal's current foreground process group.  The
   caller guards this with isatty and handles the Unix error, so detached/test
   environments retain their existing behavior. */
CAMLprim value caml_c2c_tcgetpgrp(value vfd)
{
    pid_t pgrp = tcgetpgrp(Int_val(vfd));
    if (pgrp < 0)
        caml_unix_error(errno, "tcgetpgrp", Nothing);
    return Val_int((int)pgrp);
}

/* pidfd signalling closes the check-then-kill PID reuse window.  Keep the
   Linux syscall use local to this stub so older libc headers and non-Linux
   builds retain the documented fail-closed behaviour. */
#ifdef __linux__
static int c2c_pidfd_open(pid_t pid)
{
#ifdef __NR_pidfd_open
    return (int)syscall(__NR_pidfd_open, pid, 0);
#else
    (void)pid;
    errno = ENOSYS;
    return -1;
#endif
}

static int c2c_pidfd_send_signal(int pidfd, int sig)
{
#ifdef __NR_pidfd_send_signal
    return (int)syscall(__NR_pidfd_send_signal, pidfd, sig, NULL, 0);
#else
    (void)pidfd;
    (void)sig;
    errno = ENOSYS;
    return -1;
#endif
}

static long c2c_proc_start_ticks(pid_t pid)
{
    char path[64];
    char line[4096];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    FILE *f = fopen(path, "r");
    if (f == NULL || fgets(line, sizeof(line), f) == NULL) {
        if (f != NULL) fclose(f);
        return -1;
    }
    fclose(f);
    char *close = strrchr(line, ')');
    if (close == NULL || close[1] == '\0') return -1;
    char *p = close + 2; /* state is field 3; this is tail[0]. */
    for (int i = 0; i < 19; ++i) {
        while (*p == ' ') ++p;
        char *space = strchr(p, ' ');
        if (space == NULL) return -1;
        p = space + 1;
    }
    while (*p == ' ') ++p;
    char *end = NULL;
    long result = strtol(p, &end, 10); /* tail[19] = field 22. */
    if (end == p) return -1;
    return result;
}
#endif

CAMLprim value caml_c2c_pidfd_supported(value unit)
{
    CAMLparam1(unit);
#ifdef __linux__
    int fd = c2c_pidfd_open(getpid());
    if (fd < 0) CAMLreturn(Val_false);
    int signal_rc = c2c_pidfd_send_signal(fd, 0);
    close(fd);
    CAMLreturn(signal_rc == 0 ? Val_true : Val_false);
#else
    CAMLreturn(Val_false);
#endif
}

CAMLprim value caml_c2c_pidfd_send_signal_if_start_time(value vpid,
                                                          value vstart,
                                                          value vsig)
{
    CAMLparam3(vpid, vstart, vsig);
#ifdef __linux__
    pid_t pid = (pid_t)Long_val(vpid);
    int fd = c2c_pidfd_open(pid);
    if (fd < 0) CAMLreturn(Val_false);
    long actual = c2c_proc_start_ticks(pid);
    if (actual < 0 || actual != Long_val(vstart)) {
        close(fd);
        CAMLreturn(Val_false);
    }
    int signal_kind = Int_val(vsig);
    int signal = signal_kind == 0 ? SIGTERM :
                 (signal_kind == 1 ? SIGKILL : -1);
    if (signal < 0) {
        close(fd);
        CAMLreturn(Val_false);
    }
    int rc = c2c_pidfd_send_signal(fd, signal);
    close(fd);
    CAMLreturn(rc == 0 ? Val_true : Val_false);
#else
    CAMLreturn(Val_false);
#endif
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
