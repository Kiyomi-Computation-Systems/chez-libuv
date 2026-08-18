#include "libuv-shim.h"

#include <uv.h>

#include <netinet/in.h>
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
  { "UV_TCP",         UV_TCP },
  { "UV_TIMER",       UV_TIMER },

  /* uv_req_type tags, needed to call uv_req_size() -- the request-side
   * counterpart of UV_TCP/UV_TIMER above. They come from the enum, not from
   * the position of a #define, for the same reason as everything else here. */
  { "UV_WRITE",       UV_WRITE },
  { "UV_CONNECT",     UV_CONNECT },
  { "UV_SHUTDOWN",    UV_SHUTDOWN },

  { "SIZEOF_UV_LOOP_T",     (long)sizeof(uv_loop_t) },
  { "SIZEOF_UV_TCP_T",      (long)sizeof(uv_tcp_t) },
  { "SIZEOF_UV_TIMER_T",    (long)sizeof(uv_timer_t) },
  { "SIZEOF_UV_WRITE_T",    (long)sizeof(uv_write_t) },
  { "SIZEOF_UV_CONNECT_T",  (long)sizeof(uv_connect_t) },
  { "SIZEOF_UV_SHUTDOWN_T", (long)sizeof(uv_shutdown_t) },
  { "SIZEOF_UV_BUF_T",      (long)sizeof(uv_buf_t) },
  { "SIZEOF_SOCKADDR_IN",      (long)sizeof(struct sockaddr_in) },
  { "SIZEOF_SOCKADDR_STORAGE", (long)sizeof(struct sockaddr_storage) },

  { "OFFSETOF_UV_BUF_T_BASE", (long)offsetof(uv_buf_t, base) },
  { "OFFSETOF_UV_BUF_T_LEN",  (long)offsetof(uv_buf_t, len) },
  { "OFFSETOF_SOCKADDR_IN_SIN_PORT",
    (long)offsetof(struct sockaddr_in, sin_port) },
  { "OFFSETOF_SOCKADDR_IN_SIN_FAMILY",
    (long)offsetof(struct sockaddr_in, sin_family) },
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

static long live_loop        = 0;
static long live_tcp         = 0;
static long live_timer       = 0;
static long live_write_req   = 0;
static long live_connect_req = 0;
static long live_read_buffer = 0;

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

void chez_uv_count_read_buffer_new(void)  { live_read_buffer += 1; }
void chez_uv_count_read_buffer_free(void) { live_read_buffer -= 1; }
long chez_uv_live_read_buffer(void)       { return live_read_buffer; }

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

void chez_uv_count_read_buffer_new(void)  { }
void chez_uv_count_read_buffer_free(void) { }
long chez_uv_live_read_buffer(void)       { return 0; }

#endif /* CHEZ_LIBUV_DEBUG_COUNTERS */
