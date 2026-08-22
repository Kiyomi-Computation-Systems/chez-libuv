#include "libuv-shim.h"

#include <uv.h>

#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>

int chez_uv_shim_compiled_version(void) {
  return UV_VERSION_HEX;
}

/* ADR-0005: every value below comes from the real macro, enum, sizeof(), or
 * offsetof() -- never a transcribed literal. The name column is this
 * binding's own vocabulary; native.sls looks entries up by name at init
 * time and never assumes an index, an order, or a platform-independent
 * value (spike/FINDINGS.md's sockaddr_in finding is exactly why: the same
 * name resolves to a different offset on Darwin and Linux). */
struct chez_uv_constant_entry {
  const char *name;
  long value;
};

static const struct chez_uv_constant_entry chez_uv_constant_table[] = {
  { "UV_RUN_DEFAULT", UV_RUN_DEFAULT },
  { "UV_RUN_ONCE",    UV_RUN_ONCE },
  { "UV_RUN_NOWAIT",  UV_RUN_NOWAIT },
  { "UV_EOF",         UV_EOF },
  { "AF_INET",        AF_INET },
  { "AF_UNSPEC",      AF_UNSPEC },
  { "AF_INET6",       AF_INET6 },
  { "UV_TCP",         UV_TCP },
  { "UV_TIMER",       UV_TIMER },

  /* uv_req_type tags, needed to call uv_req_size() -- the request-side
   * counterpart of UV_TCP/UV_TIMER above. They come from the enum, not from
   * the position of a #define, for the same reason as everything else here. */
  { "UV_WRITE",       UV_WRITE },
  { "UV_CONNECT",     UV_CONNECT },
  { "UV_SHUTDOWN",    UV_SHUTDOWN },
  { "UV_GETADDRINFO", UV_GETADDRINFO },
  { "UV_GETNAMEINFO", UV_GETNAMEINFO },

  { "SIZEOF_UV_LOOP_T",     (long)sizeof(uv_loop_t) },
  { "SIZEOF_UV_TCP_T",      (long)sizeof(uv_tcp_t) },
  { "SIZEOF_UV_TIMER_T",    (long)sizeof(uv_timer_t) },
  { "SIZEOF_UV_WRITE_T",    (long)sizeof(uv_write_t) },
  { "SIZEOF_UV_CONNECT_T",  (long)sizeof(uv_connect_t) },
  { "SIZEOF_UV_SHUTDOWN_T", (long)sizeof(uv_shutdown_t) },
  { "SIZEOF_UV_GETADDRINFO_T", (long)sizeof(uv_getaddrinfo_t) },
  { "SIZEOF_UV_GETNAMEINFO_T", (long)sizeof(uv_getnameinfo_t) },
  { "SIZEOF_UV_BUF_T",      (long)sizeof(uv_buf_t) },
  { "SIZEOF_SOCKADDR_IN",      (long)sizeof(struct sockaddr_in) },
  { "SIZEOF_SOCKADDR_STORAGE", (long)sizeof(struct sockaddr_storage) },
  { "SIZEOF_ADDRINFO",         (long)sizeof(struct addrinfo) },
  { "SIZEOF_SOCKADDR_IN6",     (long)sizeof(struct sockaddr_in6) },

  { "OFFSETOF_UV_BUF_T_BASE", (long)offsetof(uv_buf_t, base) },
  { "OFFSETOF_UV_BUF_T_LEN",  (long)offsetof(uv_buf_t, len) },
  { "OFFSETOF_SOCKADDR_IN_SIN_PORT",
    (long)offsetof(struct sockaddr_in, sin_port) },
  { "OFFSETOF_SOCKADDR_IN_SIN_FAMILY",
    (long)offsetof(struct sockaddr_in, sin_family) },

  /* struct addrinfo field offsets (design spec v0.2 S5.2). glibc orders
   * ai_addr before ai_canonname; Darwin reverses them. Any declared-layout
   * guess is therefore wrong on one platform, which is why chain walking
   * on the Scheme side reads every field through these offsets and never
   * through an ftype. */
  { "OFFSETOF_ADDRINFO_AI_FLAGS",
    (long)offsetof(struct addrinfo, ai_flags) },
  { "OFFSETOF_ADDRINFO_AI_FAMILY",
    (long)offsetof(struct addrinfo, ai_family) },
  { "OFFSETOF_ADDRINFO_AI_SOCKTYPE",
    (long)offsetof(struct addrinfo, ai_socktype) },
  { "OFFSETOF_ADDRINFO_AI_PROTOCOL",
    (long)offsetof(struct addrinfo, ai_protocol) },
  { "OFFSETOF_ADDRINFO_AI_ADDRLEN",
    (long)offsetof(struct addrinfo, ai_addrlen) },
  { "OFFSETOF_ADDRINFO_AI_ADDR",
    (long)offsetof(struct addrinfo, ai_addr) },
  { "OFFSETOF_ADDRINFO_AI_CANONNAME",
    (long)offsetof(struct addrinfo, ai_canonname) },
  { "OFFSETOF_ADDRINFO_AI_NEXT",
    (long)offsetof(struct addrinfo, ai_next) },
  { "OFFSETOF_SOCKADDR_IN6_SIN6_PORT",
    (long)offsetof(struct sockaddr_in6, sin6_port) },

  /* getaddrinfo hint vocabulary (design spec v0.2 S5.2): socket types,
   * protocols, and the OR-combinable AI_/NI_ flag bits from <netdb.h>.
   * AI_ADDRCONFIG and AI_V4MAPPED are deliberately absent -- outside the
   * closed validation sets they would be unreachable dead weight. */
  { "SOCK_STREAM", SOCK_STREAM },
  { "SOCK_DGRAM",  SOCK_DGRAM },
  { "SOCK_RAW",    SOCK_RAW },
  { "IPPROTO_TCP", IPPROTO_TCP },
  { "IPPROTO_UDP", IPPROTO_UDP },
  { "AI_PASSIVE",     AI_PASSIVE },
  { "AI_CANONNAME",   AI_CANONNAME },
  { "AI_NUMERICHOST", AI_NUMERICHOST },
  { "AI_NUMERICSERV", AI_NUMERICSERV },
  { "NI_NUMERICHOST", NI_NUMERICHOST },
  { "NI_NUMERICSERV", NI_NUMERICSERV },
  { "NI_NAMEREQD",    NI_NAMEREQD },
  { "NI_DGRAM",       NI_DGRAM },

  /* v0.3 process + pipe (THE SPEC §5.3; ADR-0005). */
  { "UV_PROCESS",    UV_PROCESS },
  { "UV_NAMED_PIPE", UV_NAMED_PIPE },
  { "SIZEOF_UV_PROCESS_OPTIONS_T", (long)sizeof(uv_process_options_t) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_EXIT_CB",
    (long)offsetof(uv_process_options_t, exit_cb) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_FILE",
    (long)offsetof(uv_process_options_t, file) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_ARGS",
    (long)offsetof(uv_process_options_t, args) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_ENV",
    (long)offsetof(uv_process_options_t, env) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_CWD",
    (long)offsetof(uv_process_options_t, cwd) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_FLAGS",
    (long)offsetof(uv_process_options_t, flags) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_STDIO_COUNT",
    (long)offsetof(uv_process_options_t, stdio_count) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_STDIO",
    (long)offsetof(uv_process_options_t, stdio) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_UID",
    (long)offsetof(uv_process_options_t, uid) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_GID",
    (long)offsetof(uv_process_options_t, gid) },
  { "SIZEOF_UV_STDIO_CONTAINER_T", (long)sizeof(uv_stdio_container_t) },
  { "OFFSETOF_UV_STDIO_CONTAINER_T_FLAGS",
    (long)offsetof(uv_stdio_container_t, flags) },
  { "OFFSETOF_UV_STDIO_CONTAINER_T_DATA",
    (long)offsetof(uv_stdio_container_t, data) },
  { "UV_PROCESS_SETUID",   UV_PROCESS_SETUID },
  { "UV_PROCESS_SETGID",   UV_PROCESS_SETGID },
  { "UV_PROCESS_DETACHED", UV_PROCESS_DETACHED },
  { "UV_IGNORE",         UV_IGNORE },
  { "UV_CREATE_PIPE",    UV_CREATE_PIPE },
  { "UV_INHERIT_FD",     UV_INHERIT_FD },
  { "UV_INHERIT_STREAM", UV_INHERIT_STREAM },
  { "UV_READABLE_PIPE",  UV_READABLE_PIPE },
  { "UV_WRITABLE_PIPE",  UV_WRITABLE_PIPE },
  { "SIGTERM", SIGTERM },
  { "SIGKILL", SIGKILL },
  { "SIGINT",  SIGINT },
  { "SIGHUP",  SIGHUP },
  { "SIGQUIT", SIGQUIT },
  { "SIGUSR1", SIGUSR1 },
  { "SIGUSR2", SIGUSR2 },
  { "SIGCONT", SIGCONT },
  { "SIGSTOP", SIGSTOP },
  /* v0.4 signal (design spec 2026-08-22 §5.5; ADR-0017). */
  { "UV_SIGNAL", UV_SIGNAL },
};

#define CHEZ_UV_CONSTANT_COUNT \
  (sizeof(chez_uv_constant_table) / sizeof(chez_uv_constant_table[0]))

int chez_uv_constant(const char *name, long *out) {
  size_t i;
  for (i = 0; i < CHEZ_UV_CONSTANT_COUNT; i++) {
    if (strcmp(name, chez_uv_constant_table[i].name) == 0) {
      *out = chez_uv_constant_table[i].value;
      return 1;
    }
  }
  return 0;
}

/* Errno enumeration via libuv's own X-macro (ADR-0005): the name list
 * tracks the pinned libuv header automatically rather than being copied out
 * by hand. Names are the bare UV_ERRNO_MAP token, e.g. "EOF", "ECONNRESET"
 * -- never "UV_EOF". Values go through the UV_<code> enum member, never a
 * literal, since libuv derives several of them (e.g. UV_ECANCELED) from the
 * host errno.h rather than a portable constant (spike/FINDINGS.md Q-1). */
struct chez_uv_errno_entry {
  const char *name;
  int value;
};

#define CHEZ_UV_ERRNO_XX(code, msg) { #code, UV_##code },
static const struct chez_uv_errno_entry chez_uv_errno_table[] = {
  UV_ERRNO_MAP(CHEZ_UV_ERRNO_XX)
};
#undef CHEZ_UV_ERRNO_XX

#define CHEZ_UV_ERRNO_COUNT \
  (sizeof(chez_uv_errno_table) / sizeof(chez_uv_errno_table[0]))

int chez_uv_errno_count(void) {
  return (int)CHEZ_UV_ERRNO_COUNT;
}

const char *chez_uv_errno_name(int i) {
  if (i < 0 || (size_t)i >= CHEZ_UV_ERRNO_COUNT) {
    return NULL;
  }
  return chez_uv_errno_table[i].name;
}

int chez_uv_errno_value(int i) {
  if (i < 0 || (size_t)i >= CHEZ_UV_ERRNO_COUNT) {
    return 0;
  }
  return chez_uv_errno_table[i].value;
}

#ifdef CHEZ_LIBUV_DEBUG_COUNTERS

static long live_loop            = 0;
static long live_tcp             = 0;
static long live_timer           = 0;
static long live_write_req       = 0;
static long live_connect_req     = 0;
static long live_getaddrinfo_req = 0;
static long live_getnameinfo_req = 0;
static long live_read_buffer     = 0;
static long live_pipe            = 0;
static long live_process         = 0;
static long live_spawn_options   = 0;
static long live_signal          = 0;

void chez_uv_count_loop_new(void)  { live_loop += 1; }
void chez_uv_count_loop_free(void) { live_loop -= 1; }
long chez_uv_live_loop(void)       { return live_loop; }

void chez_uv_count_tcp_new(void)  { live_tcp += 1; }
void chez_uv_count_tcp_free(void) { live_tcp -= 1; }
long chez_uv_live_tcp(void)       { return live_tcp; }

void chez_uv_count_timer_new(void)  { live_timer += 1; }
void chez_uv_count_timer_free(void) { live_timer -= 1; }
long chez_uv_live_timer(void)       { return live_timer; }

void chez_uv_count_write_req_new(void)  { live_write_req += 1; }
void chez_uv_count_write_req_free(void) { live_write_req -= 1; }
long chez_uv_live_write_req(void)       { return live_write_req; }

void chez_uv_count_connect_req_new(void)  { live_connect_req += 1; }
void chez_uv_count_connect_req_free(void) { live_connect_req -= 1; }
long chez_uv_live_connect_req(void)       { return live_connect_req; }

void chez_uv_count_getaddrinfo_req_new(void)  { live_getaddrinfo_req += 1; }
void chez_uv_count_getaddrinfo_req_free(void) { live_getaddrinfo_req -= 1; }
long chez_uv_live_getaddrinfo_req(void)       { return live_getaddrinfo_req; }

void chez_uv_count_getnameinfo_req_new(void)  { live_getnameinfo_req += 1; }
void chez_uv_count_getnameinfo_req_free(void) { live_getnameinfo_req -= 1; }
long chez_uv_live_getnameinfo_req(void)       { return live_getnameinfo_req; }

void chez_uv_count_read_buffer_new(void)  { live_read_buffer += 1; }
void chez_uv_count_read_buffer_free(void) { live_read_buffer -= 1; }
long chez_uv_live_read_buffer(void)       { return live_read_buffer; }

void chez_uv_count_pipe_new(void)  { live_pipe += 1; }
void chez_uv_count_pipe_free(void) { live_pipe -= 1; }
long chez_uv_live_pipe(void)       { return live_pipe; }

void chez_uv_count_process_new(void)  { live_process += 1; }
void chez_uv_count_process_free(void) { live_process -= 1; }
long chez_uv_live_process(void)       { return live_process; }

void chez_uv_count_spawn_options_new(void)  { live_spawn_options += 1; }
void chez_uv_count_spawn_options_free(void) { live_spawn_options -= 1; }
long chez_uv_live_spawn_options(void)       { return live_spawn_options; }

void chez_uv_count_signal_new(void)  { live_signal += 1; }
void chez_uv_count_signal_free(void) { live_signal -= 1; }
long chez_uv_live_signal(void)       { return live_signal; }

#else

void chez_uv_count_loop_new(void)  { }
void chez_uv_count_loop_free(void) { }
long chez_uv_live_loop(void)       { return 0; }

void chez_uv_count_tcp_new(void)  { }
void chez_uv_count_tcp_free(void) { }
long chez_uv_live_tcp(void)       { return 0; }

void chez_uv_count_timer_new(void)  { }
void chez_uv_count_timer_free(void) { }
long chez_uv_live_timer(void)       { return 0; }

void chez_uv_count_write_req_new(void)  { }
void chez_uv_count_write_req_free(void) { }
long chez_uv_live_write_req(void)       { return 0; }

void chez_uv_count_connect_req_new(void)  { }
void chez_uv_count_connect_req_free(void) { }
long chez_uv_live_connect_req(void)       { return 0; }

void chez_uv_count_getaddrinfo_req_new(void)  { }
void chez_uv_count_getaddrinfo_req_free(void) { }
long chez_uv_live_getaddrinfo_req(void)       { return 0; }

void chez_uv_count_getnameinfo_req_new(void)  { }
void chez_uv_count_getnameinfo_req_free(void) { }
long chez_uv_live_getnameinfo_req(void)       { return 0; }

void chez_uv_count_read_buffer_new(void)  { }
void chez_uv_count_read_buffer_free(void) { }
long chez_uv_live_read_buffer(void)       { return 0; }

void chez_uv_count_pipe_new(void)  { }
void chez_uv_count_pipe_free(void) { }
long chez_uv_live_pipe(void)       { return 0; }

void chez_uv_count_process_new(void)  { }
void chez_uv_count_process_free(void) { }
long chez_uv_live_process(void)       { return 0; }

void chez_uv_count_spawn_options_new(void)  { }
void chez_uv_count_spawn_options_free(void) { }
long chez_uv_live_spawn_options(void)       { return 0; }

void chez_uv_count_signal_new(void)  { }
void chez_uv_count_signal_free(void) { }
long chez_uv_live_signal(void)       { return 0; }

#endif /* CHEZ_LIBUV_DEBUG_COUNTERS */
