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
 * This is spike-only scaffolding. It is committed as evidence, not as a
 * component of the library; the real constants live in the shim (Stage 1,
 * design spec section 5.2).
 */

#include <stdio.h>
#include <stddef.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <uv.h>

#define P_INT(name)   printf("%-38s %d\n",  #name, (int)(name))
#define P_HEX(name)   printf("%-38s 0x%06X\n", #name, (unsigned)(name))
#define P_SIZE(name)  printf("%-38s %zu\n", #name, (size_t)(name))

int main(void) {
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
