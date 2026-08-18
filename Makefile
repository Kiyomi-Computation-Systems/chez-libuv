# chez-libuv

CHEZ        ?= chez
CC          ?= cc
UNAME_S     := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
  SHLIB_EXT := dylib
  SHLIB_LDFLAGS := -dynamiclib
else
  SHLIB_EXT := so
  SHLIB_LDFLAGS := -shared -fPIC
endif

BUILD_DIR   := build
LIB_DIR     := $(BUILD_DIR)/lib
SHIM        := $(LIB_DIR)/libchezlibuv.$(SHLIB_EXT)
CONFIG_SLS  := src/libuv/private/config.sls
VENDOR_DIR  := vendor/libuv
VENDOR_BUILD:= $(BUILD_DIR)/vendor

CFLAGS_BASE := -std=c99 -Wall -Wextra -Werror -Wconversion -Wshadow -Wpointer-arith -fPIC
CFLAGS_DEV  := $(CFLAGS_BASE) -g -O0 -DCHEZ_LIBUV_DEBUG_COUNTERS
CFLAGS_PROD := $(CFLAGS_BASE) -O2

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
TESTS        := $(wildcard tests/test-*.sps)
MEMORY_TESTS := $(TESTS)

# check-purity poisons CHEZ_LIBUV_SHIM and runs every test file that MUST
# stay free of native imports. Only test-conditions.sps qualifies (Task 4);
# it does not exist yet, so this wildcard is empty today and the target
# below succeeds vacuously over an empty loop -- not because of a hardcoded
# list that would need editing when Task 4 lands, but because $(wildcard)
# only ever names files that actually exist.
PURE_TESTS   := $(wildcard tests/test-conditions.sps)

.PHONY: all build deps check-pins check-purity check-help help dev test test-memory vendor clean prod deps-info

.DEFAULT_GOAL := help

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

build: $(SHIM) $(CONFIG_SLS) ## Build the shim and generate config.sls

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
# Runs over PURE_TESTS, which is empty until Task 4 adds
# tests/test-conditions.sps -- see the wildcard's definition above for why
# that makes this target pass vacuously rather than needing an edit later.
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

$(SHIM): src/libuv-shim.c src/libuv-shim.h $(ACQ_STAMP) | $(LIB_DIR)
	$(CC) $(CFLAGS_DEV) $(UV_CFLAGS) $(SHLIB_LDFLAGS) \
	      -o $@ src/libuv-shim.c $(UV_LIBS)

# config.sls carries the shim's ABSOLUTE path so the loader never searches.
# Factored into a canned recipe (rather than living directly in the
# $(CONFIG_SLS) rule below) so `prod` can invoke it directly too, without
# recursing via `$(MAKE) $(CONFIG_SLS)` -- that recursion used to
# re-evaluate $(SHIM)'s own rule, including its $(ACQ_STAMP) prerequisite,
# and silently relink $(SHIM) with $(CFLAGS_DEV) after `prod`'s $(CFLAGS_PROD)
# link had already produced the release artifact. See `prod`'s own comment.
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
# Zero suites exist before Task 4 lands -- $(TESTS) is then empty, the loop
# body never runs, fail stays 0, and this reports ALL SUITES PASSED
# vacuously rather than needing special-casing.
test: build deps check-pins ## Run every tests/test-*.sps suite (keep-going, aggregate exit)
	@fail=0; \
	for t in $(TESTS); do \
	  echo "=== $$t ==="; \
	  CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) $(CHEZ) --program $$t || fail=1; \
	done; \
	if [ $$fail -eq 0 ]; then echo "ALL SUITES PASSED"; \
	else echo "SUITE FAILED"; fi; \
	exit $$fail

test-memory: build deps check-pins ## Run suites under Valgrind (Linux) or ASan (macOS, no leak claim)
ifeq ($(UNAME_S),Linux)
# UV_USE_IO_URING=0: an escape hatch, not a default. Some CI kernels (older
# seccomp profiles, containers that disallow the io_uring syscalls) reject
# setup calls Valgrind's syscall emulation does not model, producing
# failures that have nothing to do with this binding's own memory
# behaviour. io_uring stays ON for the normal `make test` run; only this
# Valgrind leg forces libuv's epoll fallback.
	@for t in $(MEMORY_TESTS); do \
	  UV_USE_IO_URING=0 \
	  CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) valgrind --error-exitcode=9 \
	    --leak-check=full --show-leak-kinds=definite \
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
	CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) \
	  DYLD_INSERT_LIBRARIES="$$(command ls $$(dirname $$(xcrun --find clang))/../lib/clang/*/lib/darwin/libclang_rt.asan_osx_dynamic.dylib | head -1)" \
	  ASAN_OPTIONS=detect_leaks=0 \
	  MallocNanoZone=0 \
	  sh -c 'for t in $(MEMORY_TESTS); do $(CHEZ) --program $$t || exit 1; done'
endif

# prod compiles directly with $(CFLAGS_PROD) rather than reusing $(SHIM)'s
# own rule -- that rule is gated by $(ACQ_STAMP) and always links with
# $(CFLAGS_DEV), so depending on it here would silently produce a dev build
# under a release name. It also does NOT recurse via `$(MAKE) $(CONFIG_SLS)`
# after linking: that recursion re-evaluates $(SHIM)'s rule too, and since
# `clean` had just deleted $(ACQ_STAMP), the sub-make recreates it fresher
# than the shim `prod` just linked -- so $(SHIM) looked out of date and got
# silently relinked with $(CFLAGS_DEV), overwriting the release build one
# step after producing it. (Caught by comparing the shim's md5 immediately
# after the -O2 link against its md5 once the target finished -- they must
# be identical.) $(GEN_CONFIG_SLS) is invoked directly instead.
#
# `clean` and `vendor` (HAVE_PKG=no only) are explicit, ordered recipe
# steps rather than ordinary prerequisites on this target: declaring them as
# `prod: clean` plus a conditional `prod: vendor` used to merge into ONE
# prerequisite list in the order the two rule stanzas appeared in this file
# -- vendor built build/vendor, and THEN clean deleted it, out from under
# the link line below that references it. Explicit steps make the order
# unconditional instead of a function of where each stanza sits in the file.
prod: ## Rebuild the shim with optimizations, for a release
	$(MAKE) clean
ifeq ($(HAVE_PKG),no)
	$(MAKE) vendor
endif
	mkdir -p $(LIB_DIR)
	$(CC) $(CFLAGS_PROD) $(UV_CFLAGS) $(SHLIB_LDFLAGS) \
	      -o $(SHIM) src/libuv-shim.c $(UV_LIBS)
	$(GEN_CONFIG_SLS)

clean: ## Remove build/ and the generated config.sls
	rm -rf $(BUILD_DIR) $(CONFIG_SLS)
