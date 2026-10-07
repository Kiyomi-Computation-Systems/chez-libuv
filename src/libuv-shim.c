#include "libuv-shim.h"

#include <uv.h>

#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
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
  /* Where uv_read_start keeps the alloc callback: tests/test-tcp.sps reads it
   * back to check that libuv holds chez_uv_alloc_cb. */
  { "OFFSETOF_UV_STREAM_T_ALLOC_CB", (long)offsetof(uv_stream_t, alloc_cb) },
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

/* A zero len moves nothing between valid pointers. Chez passes even an empty
 * bytevector's storage as a non-null address (test-native.sps pins it), and
 * the foreign side is a live block at every call site, empty writes
 * included. */
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

/* The type libuv's alloc callback must have. chez_uv_alloc_cb is declared
 * with it, so its definition must match it, and one object is declared both
 * as this type and as libuv's uv_alloc_cb, so the two declarations conflict
 * unless the types are the same. That fails the build under any compiler
 * flags (measured: clang 21, gcc 12 and 13, with -w as well as -Werror).
 * Scheme hands libuv only the address, so no call site would catch a
 * mismatch. */
typedef void chez_uv_alloc_cb_fn(uv_handle_t *handle, size_t suggested_size,
                                 uv_buf_t *buf);
chez_uv_alloc_cb_fn chez_uv_alloc_cb;
extern uv_alloc_cb chez_uv_alloc_cb_type_check;
extern chez_uv_alloc_cb_fn *chez_uv_alloc_cb_type_check;

/* A stream's descriptor lives in its handle block, after libuv's handle, and
 * data points at it from the stream's creation. It is empty until the first
 * read start fills it, and emptied again before the read buffer is freed.
 * libuv itself never reads or writes a handle's data. */
void chez_uv_alloc_cb(uv_handle_t *handle, size_t suggested_size,
                      uv_buf_t *buf) {
  const uv_buf_t *descriptor = (const uv_buf_t *)handle->data;
  (void)suggested_size;
  if (descriptor == NULL) {
    buf->base = NULL;
    buf->len = 0;
  } else {
    *buf = *descriptor;
  }
}

#ifdef CHEZ_LIBUV_DEBUG_COUNTERS

/* Each loop's thread updates these counters, and a program can run a loop
 * on each of several threads (#70). So every update is one atomic add:
 * with plain += and -=, two loop threads lost updates, and the counts no
 * longer balanced (tests/test-loop-threads.sps's balance row). Relaxed
 * order is enough, as a count orders nothing else. GCC and Clang have these
 * builtins under -std=c99. */
#if !defined(__GNUC__) && !defined(__clang__)
#error "CHEZ_LIBUV_DEBUG_COUNTERS needs the __atomic builtins of GCC or Clang"
#endif

static void count_add(long *counter, long delta) {
  (void)__atomic_fetch_add(counter, delta, __ATOMIC_RELAXED);
}

static long count_read(long *counter) {
  return __atomic_load_n(counter, __ATOMIC_RELAXED);
}

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

void chez_uv_count_loop_new(void)  { count_add(&live_loop, 1); }
void chez_uv_count_loop_free(void) { count_add(&live_loop, -1); }
long chez_uv_live_loop(void)       { return count_read(&live_loop); }

void chez_uv_count_tcp_new(void)  { count_add(&live_tcp, 1); }
void chez_uv_count_tcp_free(void) { count_add(&live_tcp, -1); }
long chez_uv_live_tcp(void)       { return count_read(&live_tcp); }

void chez_uv_count_timer_new(void)  { count_add(&live_timer, 1); }
void chez_uv_count_timer_free(void) { count_add(&live_timer, -1); }
long chez_uv_live_timer(void)       { return count_read(&live_timer); }

void chez_uv_count_write_req_new(void)  { count_add(&live_write_req, 1); }
void chez_uv_count_write_req_free(void) { count_add(&live_write_req, -1); }
long chez_uv_live_write_req(void)       { return count_read(&live_write_req); }

void chez_uv_count_connect_req_new(void)  { count_add(&live_connect_req, 1); }
void chez_uv_count_connect_req_free(void) { count_add(&live_connect_req, -1); }
long chez_uv_live_connect_req(void)       { return count_read(&live_connect_req); }

void chez_uv_count_getaddrinfo_req_new(void)  { count_add(&live_getaddrinfo_req, 1); }
void chez_uv_count_getaddrinfo_req_free(void) { count_add(&live_getaddrinfo_req, -1); }
long chez_uv_live_getaddrinfo_req(void)       { return count_read(&live_getaddrinfo_req); }

void chez_uv_count_getnameinfo_req_new(void)  { count_add(&live_getnameinfo_req, 1); }
void chez_uv_count_getnameinfo_req_free(void) { count_add(&live_getnameinfo_req, -1); }
long chez_uv_live_getnameinfo_req(void)       { return count_read(&live_getnameinfo_req); }

void chez_uv_count_read_buffer_new(void)  { count_add(&live_read_buffer, 1); }
void chez_uv_count_read_buffer_free(void) { count_add(&live_read_buffer, -1); }
long chez_uv_live_read_buffer(void)       { return count_read(&live_read_buffer); }

void chez_uv_count_pipe_new(void)  { count_add(&live_pipe, 1); }
void chez_uv_count_pipe_free(void) { count_add(&live_pipe, -1); }
long chez_uv_live_pipe(void)       { return count_read(&live_pipe); }

void chez_uv_count_process_new(void)  { count_add(&live_process, 1); }
void chez_uv_count_process_free(void) { count_add(&live_process, -1); }
long chez_uv_live_process(void)       { return count_read(&live_process); }

void chez_uv_count_spawn_options_new(void)  { count_add(&live_spawn_options, 1); }
void chez_uv_count_spawn_options_free(void) { count_add(&live_spawn_options, -1); }
long chez_uv_live_spawn_options(void)       { return count_read(&live_spawn_options); }

void chez_uv_count_signal_new(void)  { count_add(&live_signal, 1); }
void chez_uv_count_signal_free(void) { count_add(&live_signal, -1); }
long chez_uv_live_signal(void)       { return count_read(&live_signal); }

void chez_uv_count_async_new(void)  { count_add(&live_async, 1); }
void chez_uv_count_async_free(void) { count_add(&live_async, -1); }
long chez_uv_live_async(void)       { return count_read(&live_async); }

static long live_block = 0;
long chez_uv_live_block(void) { return count_read(&live_block); }

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

long chez_uv_live_block(void) { return 0; }

#endif /* CHEZ_LIBUV_DEBUG_COUNTERS */

/* calloc, not malloc and a separate memset: the zeroing is in the one call,
 * and a fresh mapping comes back zero without being written. */
void *chez_uv_alloc(size_t n) {
  void *p = calloc(1, n);
#ifdef CHEZ_LIBUV_DEBUG_COUNTERS
  if (p != NULL) {
    count_add(&live_block, 1);
  }
#endif
  return p;
}

void chez_uv_free(void *p) {
#ifdef CHEZ_LIBUV_DEBUG_COUNTERS
  if (p != NULL) {
    count_add(&live_block, -1);
  }
#endif
  free(p);
}
