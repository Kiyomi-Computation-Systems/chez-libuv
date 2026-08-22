# chez-libuv

CHEZ        ?= chez
CC          ?= cc
UNAME_S     := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
  SHLIB_EXT := dylib
  SHLIB_LDFLAGS := -dynamiclib
  CFLAGS_POSIX :=
else
  SHLIB_EXT := so
  SHLIB_LDFLAGS := -shared -fPIC
  # glibc hides POSIX types behind feature-test macros under -std=c99's
  # strict mode -- notably pthread_rwlock_t, which libuv's own
  # <uv/unix.h> uses and which our -std=c99 (kept deliberately strict,
  # see CFLAGS_BASE below) would otherwise leave undeclared. macOS's
  # headers expose it regardless of -std, which is why this was invisible
  # until Linux CI's glibc caught it. _POSIX_C_SOURCE=200809L (POSIX.1-2008)
  # is what pthread_rwlock_t needs; _DEFAULT_SOURCE restores the other
  # glibc/BSD extensions a bare _POSIX_C_SOURCE would otherwise suppress.
  CFLAGS_POSIX := -D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L
endif

BUILD_DIR   := build
LIB_DIR     := $(BUILD_DIR)/lib
SHIM        := $(LIB_DIR)/libchezlibuv.$(SHLIB_EXT)
CONFIG_SLS  := src/libuv/private/config.sls
VENDOR_DIR  := vendor/libuv
VENDOR_BUILD:= $(BUILD_DIR)/vendor

CFLAGS_BASE := -std=c99 -Wall -Wextra -Werror -Wconversion -Wshadow -Wpointer-arith -fPIC $(CFLAGS_POSIX)
CFLAGS_DEV  := $(CFLAGS_BASE) -g -O0 -DCHEZ_LIBUV_DEBUG_COUNTERS
CFLAGS_PROD := $(CFLAGS_BASE) -O2

# Which flags link the shim. dev is the default, so `make build` and
# `make test` behave exactly as they always have; `prod` re-enters make with
# FLAVOR=prod so the whole graph -- shim, config.sls, stamps -- agrees on one
# flavor. GUARDED, because this variable's one failure mode is a typo silently
# falling back to dev and shipping a debug build under a release name.
FLAVOR ?= dev
ifeq ($(FLAVOR),dev)
  CFLAGS_SHIM := $(CFLAGS_DEV)
else ifeq ($(FLAVOR),prod)
  CFLAGS_SHIM := $(CFLAGS_PROD)
else
  $(error FLAVOR must be dev or prod, got '$(FLAVOR)')
endif

# --- version floor / supported range (ADR-0001's "both must fall inside the
# version range validated at init") ---------------------------------------
# UV_RANGE_LO/HI are DERIVED from UV_FLOOR_MAJOR/MINOR below, in one place --
# no second copy of the packed-hex number exists anywhere else in this repo.
# The hex digits are built once (UV_RANGE_LO_HEX/UV_RANGE_HI_HEX) and reused
# for both the shell/C "0x..." spelling used by check-pins and the Scheme
# "#x..." spelling written into config.sls.
UV_FLOOR_MAJOR  := 1
UV_FLOOR_MINOR  := 44
UV_FLOOR_DOTTED := $(UV_FLOOR_MAJOR).$(UV_FLOOR_MINOR).0

UV_RANGE_LO_HEX := $(shell printf '%02x%02x00' $(UV_FLOOR_MAJOR) $(UV_FLOOR_MINOR))
UV_RANGE_HI_HEX := $(shell printf '%02xffff' $(UV_FLOOR_MAJOR))
UV_RANGE_LO     := 0x$(UV_RANGE_LO_HEX)
UV_RANGE_HI     := 0x$(UV_RANGE_HI_HEX)

# --- native dependency discovery (ADR-0001) --------------------------
HAVE_PKG := $(shell pkg-config --exists libuv && echo yes || echo no)

ifeq ($(HAVE_PKG),yes)
  UV_CFLAGS := $(shell pkg-config --cflags libuv)
  UV_LIBS   := $(shell pkg-config --libs libuv)
  UV_LIBDIR := $(shell pkg-config --variable=libdir libuv)
  # ONE library on this path -- libuv ships a single shared object, unlike
  # cmark-gfm's core+extensions split, so there is no CMARK_CLI-shaped
  # second artifact and no differential-testing variable to carry over.
  UV_DLLS   := $(UV_LIBDIR)/libuv.$(SHLIB_EXT)
else
  UV_CFLAGS := -I$(VENDOR_DIR)/include
  # libuv's CMake drops the built shared object at the BUILD ROOT (no
  # per-target lib/ subdirectory the way cmark-gfm's split src/+extensions/
  # tree does), so there is exactly one vendored libdir, not two.
  UV_VENDOR_LIBDIR := $(abspath $(VENDOR_BUILD))
  UV_LIBS   := -L$(UV_VENDOR_LIBDIR) -luv -Wl,-rpath,$(UV_VENDOR_LIBDIR)
  UV_DLLS   := $(UV_VENDOR_LIBDIR)/libuv.$(SHLIB_EXT)
endif

SRFI_SRC     := vendor/chez-srfi
SRFI_LIBS    := $(BUILD_DIR)/scheme-libs
CHEZ_LIBDIRS := src:tests:$(SRFI_LIBS)

# The root lane (design spec v0.3 §9.4): privileged-but-deterministic
# setuid/setgid tests, run ONLY by an explicit `sudo make test-root` --
# never by the default suite, never under the memory gate. The filter-out
# below is what keeps a `tests/test-*.sps` wildcard from silently running
# it unprivileged (where it would loudly exit 1 and fail `make test`).
ROOT_TESTS   := tests/test-process-setuid.sps

TESTS        := $(filter-out $(ROOT_TESTS),$(wildcard tests/test-*.sps))
MEMORY_TESTS := $(TESTS)

# check-purity poisons CHEZ_LIBUV_SHIM and runs every test file that MUST
# stay free of native imports. Two suites qualify: test-conditions.sps
# (v0.1 Task 5) and test-addrinfo.sps (v0.2 Stage 4). Each imports (rnrs),
# (srfi :64), and pure private libraries only -- (libuv private conditions)
# imports (rnrs) alone, (libuv private addrinfo) imports (rnrs) plus
# conditions -- so neither chain ever reaches (libuv private native).
# test-native.sps and test-shim-loading.sps are deliberately NOT here --
# both import native code by design, and test-shim-loading.sps sets
# CHEZ_LIBUV_SHIM itself in its children.
#
# This is an explicit, per-suite list, NOT a tests/test-*.sps wildcard: the
# default for a new suite must be "not claimed pure", so adding a genuinely
# pure suite is a deliberate edit here. $(wildcard) is kept only so a
# DELETED file drops out silently instead of failing the target.
PURE_TESTS   := $(wildcard tests/test-conditions.sps tests/test-addrinfo.sps)

.PHONY: all build deps relink-guard check-pins check-purity check-prod check-help help dev test test-root test-memory vendor clean prod deps-info

.DEFAULT_GOAL := help

# relink-guard has to run BEFORE anything stats $(SHIM), and make is free to
# run independent prerequisites in either order (or at once, under -j).
# Nothing in this file is parallelisable anyway -- the one long build,
# vendored libuv, parallelises inside `cmake --build -j` -- so the ordering
# this file depends on is made real here instead of assumed.
.NOTPARALLEL:

# Self-documenting help: every target below carries a trailing `## `
# description; this just collects them. Keeping the description ON the
# target line (enforced by check-help) means a target can never go
# undocumented without also going unbuildable-looking, i.e. it is a check,
# not a comment (AGENTS.md).
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# A target dropped from its own `## ` line, or renamed without updating
# .PHONY, silently stops being discoverable via `make help`. This is the
# comment-vs-check AGENTS.md rule applied to the help system itself.
check-help: ## Fail if any .PHONY target is undocumented in `make help`
	@missing=0; \
	targets=$$(awk '/^\.PHONY:/ { $$1 = ""; print }' Makefile); \
	for t in $$targets; do \
	  grep -qE "^$$t:.*## " Makefile || { \
	    echo "check-help: target '$$t' has no '## ' description on its own line" >&2; \
	    missing=1; \
	  }; \
	done; \
	exit $$missing

deps-info: ## Report which libuv acquisition path and artifacts are active
	@echo "libuv source : $(if $(filter yes,$(HAVE_PKG)),pkg-config,vendored)"
	@echo "shim         : $(SHIM)"
	@echo "uv dlls      : $(UV_DLLS)"
	@echo "version range: [$(UV_RANGE_LO),$(UV_RANGE_HI)] (floor $(UV_FLOOR_DOTTED))"

all: build ## Alias for build

# relink-guard FIRST, and the order is load-bearing: it deletes a shim whose
# provenance no longer matches what was asked for, and make only stats
# $(SHIM) when it reaches it -- after that recipe has run. See the guard's
# own comment for why the stamps cannot do this on their own.
build: relink-guard $(SHIM) $(CONFIG_SLS) ## Build the shim and generate config.sls

# Scheme dependencies. chez-srfi is vendored as a submodule pinned to the SAME
# commit Akku.lock names (7879b52). Keep them equal: bumping the Akku dependency
# without re-pinning the submodule means consumers and CI test different code,
# and nothing here would notice. Akku itself is
# deliberately NOT on this path: it has no prebuilt binary, and its downloader
# fails on some hosts with CURLE_URL_MALFORMED. Akku.manifest/Akku.lock remain
# the consumer-facing declaration.
#
# chez-srfi ships Akku's percent-encoded filenames (%3a64.sls). Chez resolves
# (srfi :64) only from the decoded spelling, so link both into a build tree and
# leave the submodule's own working tree untouched.
# The submodule pin and Akku.lock name the same chez-srfi commit, and nothing
# else enforces that. They drifted within minutes of the rule being written: a
# `git submodule update --init` (from `deps`, below) resets the working tree to
# the RECORDED gitlink, silently undoing a manual detach that had not been
# staged yet. So this is a check, not a comment.
#
# Always relinks rather than using a stamp file: a stamp keyed on nothing the
# submodule pin touches would leave stale symlinks after a re-pin. `ln -sfn` is
# idempotent and the whole loop is well under a second.
deps: ## Vendor chez-srfi and symlink it (plus %3a-decoded names) into build/scheme-libs
	git submodule update --init $(SRFI_SRC)
	mkdir -p $(SRFI_LIBS)/srfi
	src=$(abspath $(SRFI_SRC)); dst=$(abspath $(SRFI_LIBS))/srfi; \
	for f in $$src/*; do \
	  b=$$(basename "$$f"); \
	  ln -sfn "$$f" "$$dst/$$b"; \
	  d=$$(printf '%s' "$$b" | sed 's/%3a/:/g'); \
	  [ "$$d" = "$$b" ] || ln -sfn "$$f" "$$dst/$$d"; \
	done

check-pins: ## Verify chez-srfi submodule <-> Akku.lock, vendored libuv version, and README floor all agree
	@rec=$$(git ls-files -s $(SRFI_SRC) | awk '{print $$2}'); \
	lock=$$(sed -n 's/.*akku\.[0-9]*\.\([a-f0-9]*\)_repack.*/\1/p' Akku.lock | head -1); \
	if [ -z "$$rec" ] || [ -z "$$lock" ]; then \
	  echo "check-pins: could not read both pins (submodule='$$rec' lock='$$lock')" >&2; \
	  exit 1; \
	fi; \
	case "$$rec" in \
	  "$$lock"*) echo "pins agree: chez-srfi $$lock" ;; \
	  *) echo "PIN DRIFT: submodule $$rec but Akku.lock names $$lock." >&2; \
	     echo "Consumers install what Akku.lock names; CI tests the submodule." >&2; \
	     exit 1 ;; \
	esac
	@if [ ! -f $(VENDOR_DIR)/include/uv/version.h ]; then \
	  echo "check-pins: run: git submodule update --init $(VENDOR_DIR)" >&2; \
	  exit 1; \
	fi; \
	maj=$$(awk '/^#define UV_VERSION_MAJOR/ {print $$3}' $(VENDOR_DIR)/include/uv/version.h); \
	min=$$(awk '/^#define UV_VERSION_MINOR/ {print $$3}' $(VENDOR_DIR)/include/uv/version.h); \
	pat=$$(awk '/^#define UV_VERSION_PATCH/ {print $$3}' $(VENDOR_DIR)/include/uv/version.h); \
	hex=$$(printf '0x%02x%02x%02x' $$maj $$min $$pat); \
	if [ $$(( $$hex )) -lt $$(( $(UV_RANGE_LO) )) ] || [ $$(( $$hex )) -gt $$(( $(UV_RANGE_HI) )) ]; then \
	  echo "PIN OUT OF RANGE: vendored libuv $$maj.$$min.$$pat ($$hex) outside [$(UV_RANGE_LO),$(UV_RANGE_HI)]" >&2; \
	  exit 1; \
	fi; \
	echo "vendored libuv pin ok: $$maj.$$min.$$pat ($$hex) in [$(UV_RANGE_LO),$(UV_RANGE_HI)]"
	@grep -q "libuv $(UV_FLOOR_DOTTED)" README.org || { \
	  echo "PIN DRIFT: README.org does not state the libuv floor ($(UV_FLOOR_DOTTED))" >&2; \
	  exit 1; \
	}
	@echo "README states the libuv floor ($(UV_FLOOR_DOTTED))"

# Nothing outside private/ may see a raw uv_* symbol or pointer (design spec
# section 3). test-conditions.sps exercises the pure &uv-* condition
# hierarchy only, so its import chain must never reach
# (libuv private native), which loads a shared object. Poisoning
# CHEZ_LIBUV_SHIM with a path that looks absolute but does not exist is the
# probe: if nothing in the suite's import chain ever reaches native.sls, the
# variable is never even read and the suite passes untouched; if anything
# does, native.sls's library body raises &uv-shim-unavailable at IMPORT
# time, before a single test runs, and the suite fails outright.
#
# Runs over PURE_TESTS (see its definition above); adding a pure suite is
# an edit to that list, never here -- this recipe only iterates it.
check-purity: build deps ## Verify pure test suites import no native code (poisons CHEZ_LIBUV_SHIM)
	@fail=0; \
	for t in $(PURE_TESTS); do \
	  echo "=== check-purity: $$t, CHEZ_LIBUV_SHIM poisoned ==="; \
	  if CHEZ_LIBUV_SHIM=/nonexistent CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) \
	      $(CHEZ) --program $$t; then \
	    echo "purity holds: $$t pulled in no native code"; \
	  else \
	    echo "PURITY VIOLATED: $$t failed with CHEZ_LIBUV_SHIM poisoned" >&2; \
	    echo "to a nonexistent path. Its import chain now reaches" >&2; \
	    echo "(libuv private native), which loads a shared object -- check" >&2; \
	    echo "what it (or something it imports) just started pulling in." >&2; \
	    fail=1; \
	  fi; \
	done; \
	exit $$fail

$(LIB_DIR):
	mkdir -p $(LIB_DIR)

ifeq ($(HAVE_PKG),no)
$(SHIM): vendor
endif

# Which acquisition path last built the shim. The name encodes the mode, so
# flipping HAVE_PKG makes the prerequisite change identity and forces a relink.
# Without this, `make HAVE_PKG=no build && make build` leaves the vendored-linked
# shim in place -- make sees the .c unchanged and skips it -- so the two exit-gate
# runs would silently test the same artifact twice.
ACQ_MODE  := $(if $(filter yes,$(HAVE_PKG)),pkgconfig,vendored)
ACQ_STAMP := $(BUILD_DIR)/.acquisition-$(ACQ_MODE)

$(ACQ_STAMP): | $(LIB_DIR)
	rm -f $(BUILD_DIR)/.acquisition-*
	touch $@

# The same mechanism for the build FLAVOR: which flavor the artifact in
# build/lib was linked as, recorded as a filename so that flipping FLAVOR
# changes this prerequisite's identity. What is at stake is that `make prod
# && make test` must not run the dev suites' counter rows against a
# counters-free prod shim, that `make build` after `make prod` must not leave
# a release artifact in place for dev callers, and that `make prod &&
# package` must not ship whatever the last link happened to be.
#
# THIS STAMP RECORDS; IT DOES NOT ENFORCE. Being a prerequisite is not enough
# to force the relink -- see `relink-guard` below, which is the half that
# works.
FLAVOR_STAMP := $(BUILD_DIR)/.flavor-$(FLAVOR)

$(FLAVOR_STAMP): | $(LIB_DIR)
	rm -f $(BUILD_DIR)/.flavor-*
	touch $@

$(SHIM): src/libuv-shim.c src/libuv-shim.h $(ACQ_STAMP) $(FLAVOR_STAMP) | $(LIB_DIR)
	$(CC) $(CFLAGS_SHIM) $(UV_CFLAGS) $(SHLIB_LDFLAGS) \
	      -o $@ src/libuv-shim.c $(UV_LIBS)

# THE STAMPS ABOVE RECORD THE PROVENANCE; THIS TARGET ENFORCES IT. Depending
# on them was not enough, and that was MEASURED rather than assumed:
#
#   make 3.81 -- the make macOS ships, and therefore the one that runs
#   `make prod && make test` here -- compares mtimes at ONE-SECOND
#   granularity and treats "equal" as up to date. A flavor flip recreates the
#   stamp in the same second as the previous link often enough to matter
#   (`make prod && make test` is exactly that shape), and the shim is then
#   NOT relinked: the dev suites run against the release artifact, or a
#   release is packaged from a dev relink -- the failure the whole mechanism
#   exists to prevent. Observed directly: `make prod` followed immediately by
#   `make test` recreated build/.flavor-dev, skipped the link, and failed 45
#   counter rows across five suites against the -O2 shim. make 4.x compares
#   sub-second timestamps and gets it right, so the defect is invisible on
#   Linux and live on macOS.
#
# Removing the artifact is not subject to any of that. A missing shim is
# rebuilt whatever the clock said.
relink-guard: ## Delete the shim when the build flavor or acquisition path changed
	@if [ -f $(SHIM) ] && \
	   { [ ! -f $(FLAVOR_STAMP) ] || [ ! -f $(ACQ_STAMP) ]; }; then \
	  echo "relink-guard: shim provenance changed (flavor=$(FLAVOR), acquisition=$(ACQ_MODE)); relinking"; \
	  rm -f $(SHIM); \
	fi

# config.sls carries the shim's ABSOLUTE path so the loader never searches.
# Kept as a canned recipe from when `prod` linked the shim itself and had to
# generate this file without recursing via `$(MAKE) $(CONFIG_SLS)` -- that
# recursion re-evaluated $(SHIM)'s rule at the default flavor and relinked the
# release artifact as a debug build. `prod` now re-enters `build` with
# FLAVOR=prod instead, so the rule below is the only caller; see `prod`'s own
# comment for why that history is worth keeping written down.
define GEN_CONFIG_SLS
	@mkdir -p $(dir $(CONFIG_SLS))
	@printf '%s\n' \
	  '#!r6rs' \
	  ';; GENERATED by make -- do not edit, do not commit.' \
	  '(library (libuv private config)' \
	  '  (export shim-path uv-library-paths uv-supported-version-range)' \
	  '  (import (rnrs))' \
	  '  (define shim-path "$(abspath $(SHIM))")' \
	  '  ;; libuv'"'"'s shared object, loaded explicitly before the shim. On' \
	  '  ;; Linux a dlopen'"'"'d library'"'"'s dependencies are NOT in the global' \
	  '  ;; symbol namespace, so binding uv_* entry points through the shim' \
	  '  ;; alone fails there while working on macOS (ADR-0002).' \
	  '  (define uv-library-paths (quote ($(foreach l,$(UV_DLLS),"$(l)"))))' \
	  '  (define uv-supported-version-range (quote (#x$(UV_RANGE_LO_HEX) . #x$(UV_RANGE_HI_HEX)))))' \
	  > $(CONFIG_SLS)
endef

# Depends on the Makefile too: this file's contents are generated by
# $(GEN_CONFIG_SLS) above, so a change here must regenerate it. Without
# that, editing the recipe leaves a stale config.sls that looks correct and
# describes the previous build.
$(CONFIG_SLS): $(SHIM) Makefile
	$(GEN_CONFIG_SLS)

# ENABLE_CLANG_TIDY defaults ON in libuv 1.52.x's own CMakeLists.txt. Leaving
# it on breaks the configure step on any machine without clang-tidy
# installed -- the common case in CI and on a fresh checkout -- with an
# error that names clang-tidy, not this Makefile, so it is easy to mistake
# for an unrelated toolchain problem. Explicitly OFF here.
#
# -DCMAKE_POLICY_VERSION_MINIMUM=3.5 is NOT carried over from cmark-gfm's
# Makefile: that flag works around cmark-gfm's CMakeLists declaring an old
# cmake_minimum_required that trips a policy-version warning under newer
# CMake. libuv's own CMakeLists requires cmake >= 3.10 and does not hit
# that warning, so the flag has nothing to work around here.
vendor: ## Build the vendored libuv fallback (used when HAVE_PKG=no)
	git submodule update --init --recursive
	cmake -S $(VENDOR_DIR) -B $(VENDOR_BUILD) \
	  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	  -DLIBUV_BUILD_SHARED=ON -DBUILD_TESTING=OFF -DLIBUV_BUILD_TESTS=OFF \
	  -DLIBUV_BUILD_BENCH=OFF -DENABLE_CLANG_TIDY=OFF
	cmake --build $(VENDOR_BUILD) -j

dev: build deps ## Start a REPL with the shim and dependencies on the library path
	CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) $(CHEZ)

# Each suite sets its own exit status. Keep going after a failure so one
# broken suite cannot hide the others, then fail the target if any failed.
# $(TESTS) is a $(wildcard), so a later task's new tests/test-*.sps file is
# picked up automatically -- no edit needed here, same reasoning as
# PURE_TESTS above.
test: build deps check-pins ## Run every tests/test-*.sps suite (keep-going, aggregate exit)
	@fail=0; \
	for t in $(TESTS); do \
	  echo "=== $$t ==="; \
	  CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) CHEZ_LIBUV_TEST_CHEZ=$(CHEZ) $(CHEZ) --program $$t || fail=1; \
	done; \
	if [ $$fail -eq 0 ]; then echo "ALL SUITES PASSED"; \
	else echo "SUITE FAILED"; fi; \
	exit $$fail

# Refusal is the SUITE's job (it checks euid itself and exits 1 with a
# message), so a bare `make test-root` fails loudly rather than skipping.
#
# NO `build deps` PREREQUISITES, deliberately: this target runs under sudo,
# and on the vendored path $(SHIM) depends on the PHONY `vendor`, so a
# `build` prerequisite relinked the shim -- as root -- on EVERY run,
# leaving root-owned artifacts in build/ (plus root-owned symlinks from
# `deps`). The recipe's first stanza is a CHECK, not a rebuild (AGENTS.md):
# every artifact `build deps` would have made must already exist, and the
# two provenance stamps must match THIS invocation's FLAVOR/HAVE_PKG --
# the same identity relink-guard enforces, asserted here instead of acted
# on. A stale-but-present shim is accepted; the lane trades staleness for
# never writing to the tree as root. check-pins stays: it only reads.
test-root: check-pins ## Run the root-gated setuid/setgid suite (needs sudo; `make build deps` unprivileged first)
	@missing=""; \
	[ -f $(SHIM) ]           || missing="$$missing $(SHIM)"; \
	[ -f $(CONFIG_SLS) ]     || missing="$$missing $(CONFIG_SLS)"; \
	[ -f $(FLAVOR_STAMP) ]   || missing="$$missing $(FLAVOR_STAMP)"; \
	[ -f $(ACQ_STAMP) ]      || missing="$$missing $(ACQ_STAMP)"; \
	[ -d $(SRFI_LIBS)/srfi ] || missing="$$missing $(SRFI_LIBS)/srfi"; \
	if [ -n "$$missing" ]; then \
	  echo "test-root: missing or provenance-mismatched artifacts:$$missing" >&2; \
	  echo "test-root deliberately does not build (under sudo, the phony" >&2; \
	  echo "vendor prerequisite would relink the shim as root). Run" >&2; \
	  echo "'make build deps' unprivileged first, with the same FLAVOR and" >&2; \
	  echo "HAVE_PKG as this invocation." >&2; \
	  exit 1; \
	fi
	@for t in $(ROOT_TESTS); do \
	  echo "=== $$t (root lane) ==="; \
	  CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) $(CHEZ) --program $$t || exit 1; \
	done; \
	echo "ROOT LANE PASSED"

# Where the macOS arm of test-memory looks for clang's ASan runtime. A
# variable (deferred, so xcrun never runs on Linux) rather than an inline
# substitution, for one reason: it makes the empty-glob guard below testable.
# `make test-memory ASAN_DYLIB_PATTERN=/nonexistent/x.dylib` must fail loudly.
ASAN_DYLIB_PATTERN ?= $(dir $(shell xcrun --find clang))../lib/clang/*/lib/darwin/libclang_rt.asan_osx_dynamic.dylib

test-memory: build deps check-pins ## Run suites under Valgrind (Linux) or ASan (macOS, no leak claim)
ifeq ($(UNAME_S),Linux)
# UV_USE_IO_URING=0: an escape hatch, not a default. Some CI kernels (older
# seccomp profiles, containers that disallow the io_uring syscalls) reject
# setup calls Valgrind's syscall emulation does not model, producing
# failures that have nothing to do with this binding's own memory
# behaviour. io_uring stays ON for the normal `make test` run; only this
# Valgrind leg forces libuv's epoll fallback.
#
# --errors-for-leak-kinds=definite (alongside --show-leak-kinds=definite):
# Valgrind's own default for THIS flag is definite,possible, and a GC
# runtime's interior pointers -- Chez's own, not this binding's -- routinely
# classify as "possibly lost". Left at the default, the gate would exit 9 on
# Chez's own runtime while not even displaying why, since --show-leak-kinds
# alone controls what gets PRINTED, not what --error-exitcode reacts to.
#
# --undef-value-errors=no: NOT a weakening of the leak gate -- ADR-0003
# scopes this gate to leaks, and undefined-value tracking is a DIFFERENT
# Memcheck check (Value 4, not the allocation-tracking Leak checks this
# target exists for). Confirmed on real CI output: with it on, Chez's own
# JIT-generated code (anonymous frames inside S_call_help) throws hundreds
# of "Conditional jump or move depends on uninitialised value(s)" reports
# from ONE context, none of them in this binding's own allocations --
# Memcheck's def/undef shadow bits are not designed to survive machine code
# a JIT emits at runtime with no debug info of its own, so the check is
# structurally unable to tell a real bug from JIT noise here. Addressability
# checking (invalid read/write, use-after-free, the leak checks above) stays
# fully enabled and gating -- only the undefined-value class is scoped out.
# See ADR-0003's amendment for the fuller record.
#
# CHEZ_LIBUV_UNDER_VALGRIND=1: tells tests/test-native.sps's dirty-memory
# seed it is running under Memcheck, whose freelist (--freelist-vol,
# default ~20MB) DELIBERATELY delays reusing a freed block -- exactly to
# catch use-after-free -- so an alloc-after-free there can never observe the
# just-freed block's leftover bytes. The property that seed exists to prove
# (a plain allocator hands back dirty memory) is unobservable under Memcheck
# by design, not by a bug in the seed; see the seed's own comment and the
# stage-1 mutation log addendum for what that costs.
	@for t in $(MEMORY_TESTS); do \
	  UV_USE_IO_URING=0 \
	  CHEZ_LIBUV_UNDER_VALGRIND=1 \
	  CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) CHEZ_LIBUV_TEST_CHEZ=$(CHEZ) valgrind --error-exitcode=9 \
	    --leak-check=full --show-leak-kinds=definite \
	    --errors-for-leak-kinds=definite \
	    --undef-value-errors=no \
	    $(CHEZ) --program $$t || exit 1; \
	done
else
	@echo "macOS: ASan preload only; LeakSanitizer is unsupported on arm64."
	@echo "Leak claims must come from Linux CI (ADR-0003)."
# MallocNanoZone=0: macOS's Nano allocator validates a freed block's own
# metadata and can SIGTRAP on a double-free before ASan's interposed free()
# gets a chance to run its check -- an unattributed crash (bare "Trace/BPT
# trap") instead of the diagnostic this target exists to provide. Carried
# over from chez-cmark-gfm, which observed this on this exact recipe.
#
# The dylib is resolved FIRST and required non-empty: if the clang resource
# dir glob ever misses (a new Xcode layout, a renamed runtime), an empty
# DYLD_INSERT_LIBRARIES would run every suite with no sanitizer at all and
# still exit 0 -- this target staying green while checking nothing. `test -n`
# turns that into a loud failure naming the pattern that missed.
	@asan="$$(command ls $(ASAN_DYLIB_PATTERN) 2>/dev/null | head -1)"; \
	test -n "$$asan" || { \
	  echo "test-memory: no ASan runtime matched $(ASAN_DYLIB_PATTERN); refusing to run un-sanitized" >&2; \
	  exit 1; \
	}; \
	echo "test-memory: ASan runtime $$asan"; \
	CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) CHEZ_LIBUV_TEST_CHEZ=$(CHEZ) \
	  DYLD_INSERT_LIBRARIES="$$asan" \
	  ASAN_OPTIONS=detect_leaks=0 \
	  MallocNanoZone=0 \
	  sh -c 'for t in $(MEMORY_TESTS); do $(CHEZ) --program $$t || exit 1; done'
endif

# prod = the SAME graph as `build`, run at FLAVOR=prod after a clean, and
# then judged by a program instead of by inspection. Each step is an explicit
# recipe line, run by a sub-make, rather than a prerequisite list:
#
#   - it used to compile directly with $(CFLAGS_PROD), duplicating the link
#     line, because $(SHIM)'s own rule hard-coded $(CFLAGS_DEV). The flavor
#     stamp above removes that reason: one rule now links either flavor, and
#     a flip forces the relink.
#   - it must NOT recurse via `$(MAKE) $(CONFIG_SLS)` after linking. That
#     recursion re-evaluated $(SHIM)'s rule at the DEFAULT flavor and
#     silently relinked the release artifact with dev flags one step after
#     producing it -- `make prod` exited 0 having shipped a debug build.
#     (Caught by comparing the shim's md5 immediately after the -O2 link
#     against its md5 once the target finished; they must be identical.)
#     `build` in the sub-make below carries FLAVOR=prod through to
#     config.sls, so there is nothing left to do afterwards.
#   - `clean` is an explicit step rather than a prerequisite: as `prod: clean`
#     plus a conditional `prod: vendor` the two merged into ONE prerequisite
#     list ordered by where each stanza sat in this file -- vendor built
#     build/vendor and clean then deleted it, out from under the link. The
#     vendored gate now needs no prod-specific rule at all: $(SHIM) already
#     depends on `vendor` when HAVE_PKG=no, inside the sub-make, after clean
#     has finished.
prod: ## Rebuild the shim with optimizations and verify the release artifact
	$(MAKE) clean
	$(MAKE) build FLAVOR=prod
	$(MAKE) check-prod

# Proves the artifact that survived to the end of `make prod` is the prod one
# (a check beats a comment, AGENTS.md): a shim carrying
# -DCHEZ_LIBUV_DEBUG_COUNTERS reports live allocation counts while a loop and
# a bound tcp handle are alive, a prod shim's queries are a constant 0
# (src/libuv-shim.c). tests/check-prod.sps establishes that the scope really
# was live using two witnesses that do not go through the counters, so
# all-zero cannot also mean "the probe allocated nothing".
#
# DELIBERATELY DEPENDS ON NOTHING. `build` here would relink the shim at the
# default flavor and the check would then judge the artifact it had just
# replaced; `deps` is unnecessary because the probe imports no SRFI. It reads
# what the last build left, and says so when there is nothing there.
#
# `env -u` so an exported CHEZ_LIBUV_SHIM cannot point the probe at a
# different shim from the one config.sls names.
check-prod: ## Verify the built shim is a release (counters-free) build
	@test -f $(SHIM) || { echo "check-prod: $(SHIM) is missing; run 'make prod' (or 'make build FLAVOR=prod') first" >&2; exit 1; }
	@test -f $(CONFIG_SLS) || { echo "check-prod: $(CONFIG_SLS) is missing; run 'make prod' first" >&2; exit 1; }
	env -u CHEZ_LIBUV_SHIM CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) \
	  $(CHEZ) --program tests/check-prod.sps

clean: ## Remove build/ and the generated config.sls
	rm -rf $(BUILD_DIR) $(CONFIG_SLS)
