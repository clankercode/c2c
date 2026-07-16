#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/*
 * Minimal waitpid bridge for relay-supervisor.sh (B219).
 *
 * POSIX shells collapse an explicit exit(139) and SIGSEGV into the same wait
 * result.  This helper preserves WIFEXITED/WIFSIGNALED in a private status
 * file without ever printing or persisting the child argv/environment.
 */

static volatile sig_atomic_t child_pid = -1;
static volatile sig_atomic_t pending_signal = 0;

static void forward_signal(int signal_number) {
  pid_t pid = (pid_t)child_pid;
  if (pid > 0) {
    (void)kill(pid, signal_number);
  } else {
    pending_signal = signal_number;
  }
}

static int install_handler(int signal_number) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = forward_signal;
  sigemptyset(&action.sa_mask);
  return sigaction(signal_number, &action, NULL);
}

static int reset_signal(int signal_number) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  return sigaction(signal_number, &action, NULL);
}

static int write_all(int fd, const char *buffer, size_t length) {
  while (length > 0) {
    ssize_t written = write(fd, buffer, length);
    if (written < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    buffer += written;
    length -= (size_t)written;
  }
  return 0;
}

static int write_record(const char *path, const char *format, ...) {
  char record[128];
  va_list arguments;
  va_start(arguments, format);
  int length = vsnprintf(record, sizeof(record), format, arguments);
  va_end(arguments);
  if (length < 0 || (size_t)length >= sizeof(record)) return -1;

  size_t temp_length = strlen(path) + 48;
  char *temp_path = malloc(temp_length);
  if (temp_path == NULL) return -1;
  (void)snprintf(temp_path, temp_length, "%s.tmp.%ld", path, (long)getpid());

  int fd = open(temp_path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) {
    free(temp_path);
    return -1;
  }
  int result = write_all(fd, record, (size_t)length);
  if (result == 0 && fsync(fd) < 0) result = -1;
  if (close(fd) < 0) result = -1;
  if (result == 0 && rename(temp_path, path) < 0) result = -1;
  if (result != 0) (void)unlink(temp_path);
  free(temp_path);
  return result;
}

static void usage(void) {
  fputs("usage: c2c-relay-child-reaper --pid-file PATH --status-file PATH -- COMMAND [ARG ...]\n",
        stderr);
}

int main(int argc, char **argv) {
  if (argc < 7 || strcmp(argv[1], "--pid-file") != 0 ||
      strcmp(argv[3], "--status-file") != 0 || strcmp(argv[5], "--") != 0) {
    usage();
    return 64;
  }
  const char *pid_file = argv[2];
  const char *status_file = argv[4];
  char **child_argv = &argv[6];
  umask(0077);

  sigset_t handled_signals;
  sigset_t previous_mask;
  sigemptyset(&handled_signals);
  sigaddset(&handled_signals, SIGTERM);
  sigaddset(&handled_signals, SIGINT);
  sigaddset(&handled_signals, SIGHUP);

  if (install_handler(SIGTERM) < 0 || install_handler(SIGINT) < 0 ||
      install_handler(SIGHUP) < 0) {
    fputs("c2c-relay-child-reaper: could not install signal handlers\n", stderr);
    return 70;
  }
  if (sigprocmask(SIG_BLOCK, &handled_signals, &previous_mask) < 0) {
    fputs("c2c-relay-child-reaper: could not block handled signals\n", stderr);
    return 70;
  }

  pid_t pid = fork();
  if (pid < 0) {
    (void)write_record(status_file, "helper_error %d\n", errno);
    fputs("c2c-relay-child-reaper: fork failed\n", stderr);
    return 70;
  }
  if (pid == 0) {
    (void)reset_signal(SIGTERM);
    (void)reset_signal(SIGINT);
    (void)reset_signal(SIGHUP);
    pending_signal = 0;
    (void)sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    execvp(child_argv[0], child_argv);
    _exit(127);
  }

  child_pid = (sig_atomic_t)pid;
  if (pending_signal != 0) {
    int signal_number = pending_signal;
    pending_signal = 0;
    (void)kill(pid, signal_number);
  }
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) < 0) {
    (void)kill(pid, SIGTERM);
    fputs("c2c-relay-child-reaper: could not restore signal mask\n", stderr);
  }
  if (write_record(pid_file, "%ld\n", (long)pid) < 0) {
    fputs("c2c-relay-child-reaper: could not persist child pid\n", stderr);
  }

  int wait_status = 0;
  while (waitpid(pid, &wait_status, 0) < 0) {
    if (errno == EINTR) continue;
    (void)write_record(status_file, "helper_error %d\n", errno);
    fputs("c2c-relay-child-reaper: waitpid failed\n", stderr);
    return 70;
  }
  child_pid = -1;

  if (WIFEXITED(wait_status)) {
    int status = WEXITSTATUS(wait_status);
    if (write_record(status_file, "exit %d\n", status) < 0)
      fputs("c2c-relay-child-reaper: could not persist exit status\n", stderr);
    return status;
  }
  if (WIFSIGNALED(wait_status)) {
    int signal_number = WTERMSIG(wait_status);
#ifdef WCOREDUMP
    int core_dumped = WCOREDUMP(wait_status) ? 1 : 0;
#else
    int core_dumped = 0;
#endif
    if (write_record(status_file, "signal %d %d\n", signal_number, core_dumped) < 0)
      fputs("c2c-relay-child-reaper: could not persist signal status\n", stderr);
    return 128 + signal_number;
  }

  (void)write_record(status_file, "helper_error 0\n");
  return 70;
}
