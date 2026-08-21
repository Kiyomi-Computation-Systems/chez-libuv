/* spike/dns/probe-dns.c — Stage 0 (v0.2 DNS) throwaway probe.
 *
 * Prints every libuv/netdb constant, struct size, and struct offset the
 * spike/dns scripts need, so that no enum value or offsetof number is ever
 * transcribed from memory into a .ss file (ADR-0005's rule, applied to the
 * spike itself — same role as spike/probe.c played for v0.1).
 *
 * Build and run:
 *   cc -I/opt/homebrew/opt/libuv/include -o spike/dns/probe-dns \
 *      spike/dns/probe-dns.c -L/opt/homebrew/opt/libuv/lib -luv
 *   ./spike/dns/probe-dns
 *
 * `./spike/dns/probe-dns --scheme` prints the same values in a
 * machine-readable "NAME value" form, one per line, NAME being the exact
 * Scheme (define NAME <int>) identifier the spike/dns .ss scripts use --
 * see print_scheme() below. spike/dns/apply-probe-constants.sh consumes
 * this to rewrite those scripts' constants blocks with runner-correct (e.g.
 * glibc) values on CI. This mode is additive: the default (no-flag) output
 * above is unchanged byte-for-byte.
 *
 * This is spike-only scaffolding. It is committed as evidence, not as a
 * component of the library; the real constants live in the shim (Stage 1,
 * design spec section 5.2).
 */

#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <uv.h>

#define P_INT(name)   printf("%-38s %d\n",  #name, (int)(name))
#define P_HEX(name)   printf("%-38s 0x%06X\n", #name, (unsigned)(name))
#define P_SIZE(name)  printf("%-38s %zu\n", #name, (size_t)(name))

/* --scheme mode: machine-readable "NAME value" lines (decimal, one per
 * line), NAME being exactly the Scheme identifier that appears in a
 * `(define NAME <int>)` line in spike/dns/04-threadpool-gc.ss and
 * spike/dns/06-hermetic-matrix.ss (enumerated via
 * `rg '^\(define [A-Z]' spike/dns/{04-threadpool-gc,06-hermetic-matrix}.ss`).
 * spike/dns/apply-probe-constants.sh consumes exactly this output to
 * substitute runner-correct values into those scripts' constants blocks, so
 * no name translation happens anywhere else. Every value the default output
 * above prints is covered here too, under its Scheme name where the two
 * differ (an `offsetof`/`sizeof` C expression becomes an OFFSETOF_ or
 * SIZEOF_ name); every other constant already shares its C macro name with
 * its Scheme name. Some names below (e.g. IPPROTO_ and UV_EAI_ codes) are
 * not (yet) read by either script's rewriter target, but are harmless to
 * print: apply-probe-constants.sh silently skips any probed NAME that
 * matches no "(define ...)" line in the files it is given.
 */
#define S_INT(name, expr) printf("%s %d\n", name, (int)(expr))

static void print_scheme(void) {
  S_INT("UV_GETADDRINFO", UV_GETADDRINFO);
  S_INT("UV_GETNAMEINFO", UV_GETNAMEINFO);

  S_INT("UV_RUN_DEFAULT", UV_RUN_DEFAULT);
  S_INT("UV_RUN_ONCE", UV_RUN_ONCE);
  S_INT("UV_RUN_NOWAIT", UV_RUN_NOWAIT);

  S_INT("SIZEOF_ADDRINFO", sizeof(struct addrinfo));
  S_INT("OFFSETOF_AI_FLAGS", offsetof(struct addrinfo, ai_flags));
  S_INT("OFFSETOF_AI_FAMILY", offsetof(struct addrinfo, ai_family));
  S_INT("OFFSETOF_AI_SOCKTYPE", offsetof(struct addrinfo, ai_socktype));
  S_INT("OFFSETOF_AI_PROTOCOL", offsetof(struct addrinfo, ai_protocol));
  S_INT("OFFSETOF_AI_ADDRLEN", offsetof(struct addrinfo, ai_addrlen));
  S_INT("OFFSETOF_AI_CANONNAME", offsetof(struct addrinfo, ai_canonname));
  S_INT("OFFSETOF_AI_ADDR", offsetof(struct addrinfo, ai_addr));
  S_INT("OFFSETOF_AI_NEXT", offsetof(struct addrinfo, ai_next));

  S_INT("AF_UNSPEC", AF_UNSPEC);
  S_INT("AF_INET", AF_INET);
  S_INT("AF_INET6", AF_INET6);

  S_INT("SOCK_STREAM", SOCK_STREAM);
  S_INT("SOCK_DGRAM", SOCK_DGRAM);
  S_INT("SOCK_RAW", SOCK_RAW);
  S_INT("IPPROTO_TCP", IPPROTO_TCP);
  S_INT("IPPROTO_UDP", IPPROTO_UDP);

  S_INT("AI_PASSIVE", AI_PASSIVE);
  S_INT("AI_CANONNAME", AI_CANONNAME);
  S_INT("AI_NUMERICHOST", AI_NUMERICHOST);
  S_INT("AI_NUMERICSERV", AI_NUMERICSERV);

  S_INT("NI_NUMERICHOST", NI_NUMERICHOST);
  S_INT("NI_NUMERICSERV", NI_NUMERICSERV);
  S_INT("NI_NAMEREQD", NI_NAMEREQD);
  S_INT("NI_DGRAM", NI_DGRAM);
  S_INT("NI_MAXHOST", NI_MAXHOST);
  S_INT("NI_MAXSERV", NI_MAXSERV);
  S_INT("INET6_ADDRSTRLEN", INET6_ADDRSTRLEN);

  S_INT("UV_EAI_NONAME", UV_EAI_NONAME);
  S_INT("UV_EAI_CANCELED", UV_EAI_CANCELED);
  S_INT("UV_EAI_BADFLAGS", UV_EAI_BADFLAGS);
  S_INT("UV_EAI_SERVICE", UV_EAI_SERVICE);
  S_INT("UV_EINVAL", UV_EINVAL);
  S_INT("UV_EBUSY", UV_EBUSY);
  S_INT("UV_ECANCELED", UV_ECANCELED);
  S_INT("UV_E2BIG", UV_E2BIG);
  S_INT("UV_ENOENT", UV_ENOENT);

  S_INT("SIZEOF_SOCKADDR_IN", sizeof(struct sockaddr_in));
  S_INT("OFFSETOF_SIN_FAMILY", offsetof(struct sockaddr_in, sin_family));
  S_INT("OFFSETOF_SIN_PORT", offsetof(struct sockaddr_in, sin_port));
  S_INT("OFFSETOF_SIN_ADDR", offsetof(struct sockaddr_in, sin_addr));

  S_INT("SIZEOF_SOCKADDR_IN6", sizeof(struct sockaddr_in6));
  S_INT("OFFSETOF_SIN6_FAMILY", offsetof(struct sockaddr_in6, sin6_family));
  S_INT("OFFSETOF_SIN6_PORT", offsetof(struct sockaddr_in6, sin6_port));
  S_INT("OFFSETOF_SIN6_ADDR", offsetof(struct sockaddr_in6, sin6_addr));
  S_INT("OFFSETOF_SIN6_SCOPE", offsetof(struct sockaddr_in6, sin6_scope_id));
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--scheme") == 0) {
    print_scheme();
    return 0;
  }

  printf("== versions ==\n");
  P_HEX(uv_version());
  printf("%-38s %s\n", "uv_version_string()", uv_version_string());

  printf("\n== uv_req_type enum values (DNS kinds) ==\n");
  P_INT(UV_GETADDRINFO);
  P_INT(UV_GETNAMEINFO);

  printf("\n== uv_run_mode enum values ==\n");
  P_INT(UV_RUN_DEFAULT);
  P_INT(UV_RUN_ONCE);
  P_INT(UV_RUN_NOWAIT);

  printf("\n== request sizes ==\n");
  P_SIZE(uv_req_size(UV_GETADDRINFO));
  P_SIZE(uv_req_size(UV_GETNAMEINFO));
  P_SIZE(sizeof(uv_getaddrinfo_t));
  P_SIZE(sizeof(uv_getnameinfo_t));
  P_SIZE(uv_loop_size());

  printf("\n== struct addrinfo layout ==\n");
  P_SIZE(sizeof(struct addrinfo));
  P_SIZE(offsetof(struct addrinfo, ai_flags));
  P_SIZE(offsetof(struct addrinfo, ai_family));
  P_SIZE(offsetof(struct addrinfo, ai_socktype));
  P_SIZE(offsetof(struct addrinfo, ai_protocol));
  P_SIZE(offsetof(struct addrinfo, ai_addrlen));
  P_SIZE(offsetof(struct addrinfo, ai_canonname));
  P_SIZE(offsetof(struct addrinfo, ai_addr));
  P_SIZE(offsetof(struct addrinfo, ai_next));

  printf("\n== address families ==\n");
  P_INT(AF_UNSPEC);
  P_INT(AF_INET);
  P_INT(AF_INET6);

  printf("\n== socket types / protocols ==\n");
  P_INT(SOCK_STREAM);
  P_INT(SOCK_DGRAM);
  P_INT(SOCK_RAW);
  P_INT(IPPROTO_TCP);
  P_INT(IPPROTO_UDP);

  printf("\n== AI_ flags ==\n");
  P_INT(AI_PASSIVE);
  P_INT(AI_CANONNAME);
  P_INT(AI_NUMERICHOST);
  P_INT(AI_NUMERICSERV);

  printf("\n== NI_ flags / buffer sizes ==\n");
  P_INT(NI_NUMERICHOST);
  P_INT(NI_NUMERICSERV);
  P_INT(NI_NAMEREQD);
  P_INT(NI_DGRAM);
  P_INT(NI_MAXHOST);
  P_INT(NI_MAXSERV);
  P_INT(INET6_ADDRSTRLEN);

  printf("\n== uv errno constants used by the dns spike ==\n");
  P_INT(UV_EAI_NONAME);
  P_INT(UV_EAI_CANCELED);
  P_INT(UV_EAI_BADFLAGS);
  P_INT(UV_EAI_SERVICE);
  P_INT(UV_EINVAL);
  P_INT(UV_EBUSY);
  P_INT(UV_ECANCELED);
  P_INT(UV_E2BIG);
  P_INT(UV_ENOENT);

  printf("\n== struct sockaddr_in layout (v0.1 probe re-check) ==\n");
  P_SIZE(sizeof(struct sockaddr_in));
  P_SIZE(offsetof(struct sockaddr_in, sin_family));
  P_SIZE(sizeof(((struct sockaddr_in *)0)->sin_family));
  P_SIZE(offsetof(struct sockaddr_in, sin_port));
  P_SIZE(offsetof(struct sockaddr_in, sin_addr));

  printf("\n== struct sockaddr_in6 layout ==\n");
  P_SIZE(sizeof(struct sockaddr_in6));
  P_SIZE(offsetof(struct sockaddr_in6, sin6_family));
  P_SIZE(sizeof(((struct sockaddr_in6 *)0)->sin6_family));
  P_SIZE(offsetof(struct sockaddr_in6, sin6_port));
  P_SIZE(offsetof(struct sockaddr_in6, sin6_addr));
  P_SIZE(offsetof(struct sockaddr_in6, sin6_scope_id));

  return 0;
}
