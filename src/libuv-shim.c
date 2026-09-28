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

/* Values are compiler-derived and looked up by name; table order is not ABI. */
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

  /* glibc and Darwin order addrinfo fields differently. */
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

  /* Closed DNS input vocabulary. */
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

  /* Process, pipe, and signal constants. */
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
  { "UV_SIGNAL", UV_SIGNAL },
  { "UV_ASYNC",  UV_ASYNC },

  /* Version-gated bind flag. UV_TCP_REUSEPORT (TCP SO_REUSEPORT with load
   * balancing) is an enum constant, so it is invisible to #ifdef; it is guarded
   * by libuv's version instead, which arrived in 1.49.0 (UV_VERSION_HEX
   * 0x013100). Below that the name is simply absent from this table and
   * chez_uv_constant returns 0 for it, which surfaces in Scheme as
   * &uv-constant-unavailable at the point of use (ADR-0005) -- a named refusal,
   * never a silent bind with the flag dropped. */
#if UV_VERSION_HEX >= 0x013100
  { "UV_TCP_REUSEPORT", UV_TCP_REUSEPORT },
#endif
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

/* Derive errno names and values from libuv's UV_ERRNO_MAP. Names are bare
 * tokens such as "EOF"; values may depend on the host errno definitions. */
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

/* Chez passes an empty bytevector's storage as a non-null pointer, so a zero
 * len reaches memcpy/memset with valid pointers and moves nothing. */
void chez_uv_copy_in(void *dst, const unsigned char *src, size_t start,
                     size_t len) {
  memcpy(dst, src + start, len);
}

void chez_uv_copy_out(unsigned char *dst, const void *src, size_t len) {
  memcpy(dst, src, len);
}

void chez_uv_zero(void *dst, size_t len) {
  memset(dst, 0, len);
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
static long live_async           = 0;

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

void chez_uv_count_async_new(void)  { live_async += 1; }
void chez_uv_count_async_free(void) { live_async -= 1; }
long chez_uv_live_async(void)       { return live_async; }

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

void chez_uv_count_async_new(void)  { }
void chez_uv_count_async_free(void) { }
long chez_uv_live_async(void)       { return 0; }

#endif /* CHEZ_LIBUV_DEBUG_COUNTERS */
