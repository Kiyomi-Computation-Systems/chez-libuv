/* spike/process/probe-process.c — Stage 0 (v0.3 process) throwaway probe.
 *
 * Prints every libuv/signal constant, struct size, and struct offset the
 * spike/process scripts hardcode, so no enum value or offsetof number is
 * ever transcribed from a header or from memory into a .ss file (ADR-0005's
 * rule, applied to the spike itself — the same role spike/probe.c played for
 * v0.1 and spike/dns/probe-dns.c for v0.2).
 *
 * Build and run (vendored libuv, the pinned v1.52.1 submodule):
 *   make HAVE_PKG=no vendor
 *   cc -Ivendor/libuv/include -o spike/process/probe-process \
 *      spike/process/probe-process.c -Lbuild/vendor -luv \
 *      -Wl,-rpath,$PWD/build/vendor
 *   ./spike/process/probe-process
 *
 * `./spike/process/probe-process --scheme` prints the same values in the
 * machine-readable "NAME value" form (decimal, one per line) that
 * spike/dns/apply-probe-constants.sh consumes, NAME being exactly the
 * Scheme identifier a `(define NAME <int>)` line in
 * spike/process/{07-spawn-failure,08-sigchld-coexist,09-pipe-stdio-gc}.ss
 * uses. That is how the Linux CI leg runs the committed scripts against
 * runner-correct (glibc/x86_64) values instead of the Darwin ones recorded
 * here. This mode is additive: the default (no-flag) output is unchanged.
 *
 * This is spike-only scaffolding. It is committed as evidence, not as a
 * component of the library; the real constants live in the shim (Stage 1,
 * design spec §5.3).
 */

#include <uv.h>
#include <signal.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>

#define P(n, v) printf("%-42s %ld\n", n, (long)(v))
#define S(n, v) printf("%s %ld\n", n, (long)(v))

/* --scheme mode: the Scheme-identifier view of exactly the same numbers. */
static void print_scheme(void) {
  S("UV_PROCESS", UV_PROCESS);
  S("UV_NAMED_PIPE", UV_NAMED_PIPE);
  S("UV_TCP", UV_TCP);
  S("UV_TIMER", UV_TIMER);

  S("SIZEOF_UV_PROCESS_OPTIONS", sizeof(uv_process_options_t));
  S("OFFSETOF_OPT_EXIT_CB", offsetof(uv_process_options_t, exit_cb));
  S("OFFSETOF_OPT_FILE", offsetof(uv_process_options_t, file));
  S("OFFSETOF_OPT_ARGS", offsetof(uv_process_options_t, args));
  S("OFFSETOF_OPT_ENV", offsetof(uv_process_options_t, env));
  S("OFFSETOF_OPT_CWD", offsetof(uv_process_options_t, cwd));
  S("OFFSETOF_OPT_FLAGS", offsetof(uv_process_options_t, flags));
  S("OFFSETOF_OPT_STDIO_COUNT", offsetof(uv_process_options_t, stdio_count));
  S("OFFSETOF_OPT_STDIO", offsetof(uv_process_options_t, stdio));
  S("OFFSETOF_OPT_UID", offsetof(uv_process_options_t, uid));
  S("OFFSETOF_OPT_GID", offsetof(uv_process_options_t, gid));

  S("SIZEOF_UV_STDIO_CONTAINER", sizeof(uv_stdio_container_t));
  S("OFFSETOF_CONTAINER_FLAGS", offsetof(uv_stdio_container_t, flags));
  S("OFFSETOF_CONTAINER_DATA", offsetof(uv_stdio_container_t, data));

  S("UV_IGNORE", UV_IGNORE);
  S("UV_CREATE_PIPE", UV_CREATE_PIPE);
  S("UV_INHERIT_FD", UV_INHERIT_FD);
  S("UV_INHERIT_STREAM", UV_INHERIT_STREAM);
  S("UV_READABLE_PIPE", UV_READABLE_PIPE);
  S("UV_WRITABLE_PIPE", UV_WRITABLE_PIPE);

  S("UV_PROCESS_SETUID", UV_PROCESS_SETUID);
  S("UV_PROCESS_SETGID", UV_PROCESS_SETGID);
  S("UV_PROCESS_DETACHED", UV_PROCESS_DETACHED);

  S("SIGTERM", SIGTERM);
  S("SIGKILL", SIGKILL);

  S("UV_RUN_DEFAULT", UV_RUN_DEFAULT);
  S("UV_RUN_ONCE", UV_RUN_ONCE);
  S("UV_RUN_NOWAIT", UV_RUN_NOWAIT);

  S("UV_WRITE", UV_WRITE);
  S("UV_SHUTDOWN", UV_SHUTDOWN);

  S("SIZEOF_UV_BUF_T", sizeof(uv_buf_t));
  S("OFFSETOF_BUF_BASE", offsetof(uv_buf_t, base));
  S("OFFSETOF_BUF_LEN", offsetof(uv_buf_t, len));

  S("OFFSETOF_PROCESS_PID", offsetof(uv_process_t, pid));
  S("SIZEOF_UV_PROCESS_T", sizeof(uv_process_t));
  S("SIZEOF_UV_PIPE_T", sizeof(uv_pipe_t));

  S("UV_ENOENT", UV_ENOENT);
  S("UV_EINVAL", UV_EINVAL);
  S("UV_EBUSY", UV_EBUSY);
  S("UV_EBADF", UV_EBADF);
  S("UV_EOF", UV_EOF);
  S("UV_ECANCELED", UV_ECANCELED);
  S("UV_EAGAIN", UV_EAGAIN);
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--scheme") == 0) {
    print_scheme();
    return 0;
  }

  printf("%-42s %s\n", "uv_version_string()", uv_version_string());
  printf("\n== the rows spike/process hardcodes ==\n");
  P("UV_PROCESS", UV_PROCESS);
  P("UV_NAMED_PIPE", UV_NAMED_PIPE);
  P("sizeof(uv_process_options_t)", sizeof(uv_process_options_t));
  P("offsetof exit_cb", offsetof(uv_process_options_t, exit_cb));
  P("offsetof file", offsetof(uv_process_options_t, file));
  P("offsetof args", offsetof(uv_process_options_t, args));
  P("offsetof env", offsetof(uv_process_options_t, env));
  P("offsetof cwd", offsetof(uv_process_options_t, cwd));
  P("offsetof flags", offsetof(uv_process_options_t, flags));
  P("offsetof stdio_count", offsetof(uv_process_options_t, stdio_count));
  P("offsetof stdio", offsetof(uv_process_options_t, stdio));
  P("offsetof uid", offsetof(uv_process_options_t, uid));
  P("offsetof gid", offsetof(uv_process_options_t, gid));
  P("sizeof(uv_stdio_container_t)", sizeof(uv_stdio_container_t));
  P("offsetof container flags", offsetof(uv_stdio_container_t, flags));
  P("offsetof container data", offsetof(uv_stdio_container_t, data));
  P("UV_IGNORE", UV_IGNORE);
  P("UV_CREATE_PIPE", UV_CREATE_PIPE);
  P("UV_INHERIT_FD", UV_INHERIT_FD);
  P("UV_INHERIT_STREAM", UV_INHERIT_STREAM);
  P("UV_READABLE_PIPE", UV_READABLE_PIPE);
  P("UV_WRITABLE_PIPE", UV_WRITABLE_PIPE);
  P("UV_PROCESS_SETUID", UV_PROCESS_SETUID);
  P("UV_PROCESS_SETGID", UV_PROCESS_SETGID);
  P("UV_PROCESS_DETACHED", UV_PROCESS_DETACHED);
  P("SIGTERM", SIGTERM);
  P("SIGKILL", SIGKILL);

  printf("\n== additional rows the three scripts need ==\n");
  P("UV_TCP", UV_TCP);
  P("UV_TIMER", UV_TIMER);
  P("uv_handle_size(UV_TIMER)", uv_handle_size(UV_TIMER));
  P("UV_RUN_DEFAULT", UV_RUN_DEFAULT);
  P("UV_RUN_ONCE", UV_RUN_ONCE);
  P("UV_RUN_NOWAIT", UV_RUN_NOWAIT);
  P("UV_WRITE", UV_WRITE);
  P("UV_SHUTDOWN", UV_SHUTDOWN);
  P("sizeof(uv_buf_t)", sizeof(uv_buf_t));
  P("offsetof uv_buf_t.base", offsetof(uv_buf_t, base));
  P("offsetof uv_buf_t.len", offsetof(uv_buf_t, len));
  P("offsetof uv_process_t.pid", offsetof(uv_process_t, pid));
  P("sizeof(uv_process_t)", sizeof(uv_process_t));
  P("sizeof(uv_pipe_t)", sizeof(uv_pipe_t));
  P("uv_handle_size(UV_PROCESS)", uv_handle_size(UV_PROCESS));
  P("uv_handle_size(UV_NAMED_PIPE)", uv_handle_size(UV_NAMED_PIPE));
  P("uv_req_size(UV_WRITE)", uv_req_size(UV_WRITE));
  P("uv_req_size(UV_SHUTDOWN)", uv_req_size(UV_SHUTDOWN));
  P("uv_loop_size()", uv_loop_size());

  printf("\n== errno rows ==\n");
  P("UV_ENOENT", UV_ENOENT);
  P("UV_EINVAL", UV_EINVAL);
  P("UV_EBUSY", UV_EBUSY);
  P("UV_EBADF", UV_EBADF);
  P("UV_EOF", UV_EOF);
  P("UV_ECANCELED", UV_ECANCELED);
  P("UV_EAGAIN", UV_EAGAIN);

  printf("\n== SIGCHLD delivery path compiled into this libuv ==\n");
#ifdef UV_HAVE_KQUEUE
  printf("%-42s %s\n", "child reaping backend", "kqueue EVFILT_PROC (no SIGCHLD handler)");
#else
  printf("%-42s %s\n", "child reaping backend", "SIGCHLD handler + waitpid(WNOHANG)");
#endif
  return 0;
}
