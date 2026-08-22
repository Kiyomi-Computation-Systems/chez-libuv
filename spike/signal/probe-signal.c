/* spike/signal/probe-signal.c — Stage 0 (v0.4 signal) throwaway probe.
 *
 * Prints every libuv/signal constant, struct size, and struct offset the
 * spike/signal scripts hardcode, so no enum value or offsetof number is
 * ever transcribed from a header or from memory into a .ss file (ADR-0005's
 * rule, applied to the spike itself — the same role spike/process/
 * probe-process.c played for v0.3).
 *
 * Build and run (vendored libuv, the pinned v1.52.1 submodule):
 *   make HAVE_PKG=no vendor
 *   cc -Ivendor/libuv/include -o spike/signal/probe-signal \
 *      spike/signal/probe-signal.c -Lbuild/vendor -luv \
 *      -Wl,-rpath,$PWD/build/vendor
 *   ./spike/signal/probe-signal
 *
 * `./spike/signal/probe-signal --scheme` prints the machine-readable
 * "NAME value" form consumed by spike/dns/apply-probe-constants.sh, NAME
 * being exactly the Scheme identifier a `(define NAME <int>)` line in
 * spike/signal/{10-sigint-coexist,11-oneshot-e2e,12-vendor-microfacts}.ss
 * uses. That is how the Linux CI leg runs the committed scripts against
 * runner-correct (glibc/x86_64) values instead of the Darwin ones recorded
 * here.
 *
 * This is spike-only scaffolding: committed as evidence, not as a component
 * of the library; the real constants live in the shim (ADR-0002/0005).
 */

#include <uv.h>
#include <signal.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>

#define P(n, v) printf("%-38s %ld\n", n, (long)(v))
#define S(n, v) printf("%s %ld\n", n, (long)(v))

static void print_scheme(void) {
  S("UV_SIGNAL", UV_SIGNAL);
  S("UV_TIMER", UV_TIMER);
  S("UV_PROCESS", UV_PROCESS);

  S("UV_RUN_ONCE", UV_RUN_ONCE);
  S("UV_RUN_NOWAIT", UV_RUN_NOWAIT);

  S("SIG_INT", SIGINT);
  S("SIG_TERM", SIGTERM);
  S("SIG_HUP", SIGHUP);
  S("SIG_USR1", SIGUSR1);
  S("SIG_USR2", SIGUSR2);

  S("SIZEOF_UV_PROCESS_OPTIONS", sizeof(uv_process_options_t));
  S("OFFSETOF_OPT_EXIT_CB", offsetof(uv_process_options_t, exit_cb));
  S("OFFSETOF_OPT_FILE", offsetof(uv_process_options_t, file));
  S("OFFSETOF_OPT_ARGS", offsetof(uv_process_options_t, args));
  S("OFFSETOF_OPT_ENV", offsetof(uv_process_options_t, env));
  S("OFFSETOF_OPT_CWD", offsetof(uv_process_options_t, cwd));
  S("OFFSETOF_OPT_FLAGS", offsetof(uv_process_options_t, flags));
  S("OFFSETOF_OPT_STDIO_COUNT", offsetof(uv_process_options_t, stdio_count));
  S("OFFSETOF_OPT_STDIO", offsetof(uv_process_options_t, stdio));
  S("OFFSETOF_PROCESS_PID", offsetof(uv_process_t, pid));

  S("SIZEOF_UV_STDIO_CONTAINER", sizeof(uv_stdio_container_t));
  S("OFFSETOF_CONTAINER_FLAGS", offsetof(uv_stdio_container_t, flags));
  S("OFFSETOF_CONTAINER_DATA", offsetof(uv_stdio_container_t, data));
  S("UV_STDIO_IGNORE", UV_IGNORE);
  S("UV_STDIO_INHERIT_FD", UV_INHERIT_FD);
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--scheme") == 0) {
    print_scheme();
    return 0;
  }

  printf("probe-signal — v0.4 signal spike constants\n");
  printf("uv_version_string()  = %s\n\n", uv_version_string());

  P("UV_SIGNAL (handle type tag)", UV_SIGNAL);
  P("UV_TIMER  (handle type tag)", UV_TIMER);
  P("UV_PROCESS(handle type tag)", UV_PROCESS);
  P("uv_handle_size(UV_SIGNAL)", uv_handle_size(UV_SIGNAL));
  P("uv_loop_size()", uv_loop_size());
  P("UV_RUN_ONCE", UV_RUN_ONCE);
  P("UV_RUN_NOWAIT", UV_RUN_NOWAIT);
  P("SIGINT", SIGINT);
  P("SIGTERM", SIGTERM);
  P("SIGHUP", SIGHUP);
  P("SIGUSR1", SIGUSR1);
  P("SIGUSR2", SIGUSR2);
  P("sizeof(uv_process_options_t)", sizeof(uv_process_options_t));
  P("offsetof(uv_process_t, pid)", offsetof(uv_process_t, pid));
  P("sizeof(uv_stdio_container_t)", sizeof(uv_stdio_container_t));
  P("UV_IGNORE", UV_IGNORE);
  P("UV_INHERIT_FD", UV_INHERIT_FD);
  return 0;
}
