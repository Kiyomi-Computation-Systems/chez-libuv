/* spike/signal/sig-probe.c — Stage 0 (v0.4 signal) throwaway shared library.
 *
 * Loaded INTO the Chez process by the spike scripts (load-shared-object) to
 * read the currently installed disposition of a signal via sigaction(2) —
 * the structural half of SQ-S1. A C helper is required because struct
 * sigaction's layout is platform-dependent; this is exactly the class of
 * problem the shim solves for the shipped binding (ADR-0005), applied here
 * as spike-local scaffolding (ADR-0002 binds the shipped shim only).
 *
 * Build:
 *   cc -shared -fPIC -o spike/signal/sig-probe.so spike/signal/sig-probe.c
 * (macOS: same command; the .so suffix is fine for load-shared-object.)
 *
 * spike_sig_disposition(signum):
 *   0 = SIG_DFL, 1 = SIG_IGN, 2 = plain handler (sa_handler),
 *   3 = SA_SIGINFO handler (sa_sigaction), -1 = sigaction() failed.
 * spike_sig_handler_addr(signum):
 *   the installed handler's address as an integer (0 for DFL/IGN/error) —
 *   used only for identity comparisons (baseline vs libuv vs post-stop),
 *   never dereferenced.
 */

#include <signal.h>

int spike_sig_disposition(int signum) {
  struct sigaction sa;
  if (sigaction(signum, 0, &sa) != 0) return -1;
  if (sa.sa_flags & SA_SIGINFO) return 3;
  if (sa.sa_handler == SIG_DFL) return 0;
  if (sa.sa_handler == SIG_IGN) return 1;
  return 2;
}

unsigned long spike_sig_handler_addr(int signum) {
  struct sigaction sa;
  if (sigaction(signum, 0, &sa) != 0) return 0;
  if (sa.sa_flags & SA_SIGINFO) return (unsigned long)sa.sa_sigaction;
  if (sa.sa_handler == SIG_DFL || sa.sa_handler == SIG_IGN) return 0;
  return (unsigned long)sa.sa_handler;
}
