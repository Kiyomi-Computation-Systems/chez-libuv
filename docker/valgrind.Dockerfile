# The Linux Valgrind memory gate, for developers on a non-Linux box.
#
# WHY THIS EXISTS. ADR-0003 makes Linux Valgrind the SOLE memory gate: macOS
# has no LeakSanitizer on ARM64, so `make test-memory` there checks
# addressability and says nothing whatever about leaks. That is not a
# theoretical gap. v0.5 measured it: four independent ways to leak foreign
# memory in the OS-buffer wrappers -- a mis-ordered validation and each of the
# three `free!` sites -- and every one of them left the suite fully green at
# 23 passes. On the primary development platform there is no local signal for
# the entire defect class, and CI is the first thing that sees it.
#
# This image mirrors ci.yml's linux job closely enough to be that signal.
#
# The Chez version is NOT pinned here. It arrives as a build arg the Makefile
# derives from ci.yml's CHEZ_FLOOR_VERSION, so this file cannot become a
# fourth place the floor is stated and a fourth place it can drift.
FROM debian:bookworm

ARG CHEZ_VERSION
RUN test -n "$CHEZ_VERSION" || (echo "build-arg CHEZ_VERSION is required" >&2; exit 1)

# libuv1-dev supplies the pkg-config acquisition path (ADR-0001). valgrind,
# cmake and build-essential match ci.yml's linux toolchain step.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      valgrind cmake pkg-config build-essential libuv1-dev \
      curl ca-certificates git uuid-dev \
 && rm -rf /var/lib/apt/lists/*

# apt's chezscheme is 9.5.x, below the declared floor, so Chez is built from
# the pinned release tarball exactly as ci.yml does: --disable-x11
# --disable-curses (expeditor otherwise wants X11/ncurses headers), and a
# SERIAL make -- parallel bootstrap races and fails to create nanopass.so.
#
# NOTE the installed binary is `scheme`, and it is deliberately NOT symlinked
# to `chez`. Chez resolves its boot files by argv[0]: invoked through a
# differently-named symlink it aborts in find_boot before running a line,
# and under Valgrind that surfaces as a ~12KB "definitely lost" from the
# aborted boot -- a leak report that has nothing to do with this binding.
# The Makefile target passes CHEZ=scheme for exactly this reason.
RUN curl -fsSL -o /tmp/chez.tar.gz \
      "https://github.com/cisco/ChezScheme/releases/download/v${CHEZ_VERSION}/csv${CHEZ_VERSION}.tar.gz" \
 && tar xzf /tmp/chez.tar.gz -C /tmp \
 && cd "/tmp/csv${CHEZ_VERSION}" \
 && ./configure --disable-x11 --disable-curses --prefix=/usr/local \
 && make \
 && make install \
 && rm -rf "/tmp/csv${CHEZ_VERSION}" /tmp/chez.tar.gz

# CI's ordinary legs run as a NON-ROOT user; only the root lane uses sudo
# (ci.yml's "Root lane (setuid/setgid, sudo)" step). That difference is
# load-bearing, not cosmetic: tests/test-process.sps asserts that setting a
# child's uid as an unprivileged user is REFUSED with EPERM/EACCES. Run this
# image as root and that spawn succeeds instead, the row fails, and the
# spawn-options block whose cleanup only runs on the failure path shows up as
# a 131-byte definite leak -- an environment artifact indistinguishable, at a
# glance, from a real defect in the binding.
RUN useradd --create-home --uid 1000 dev
WORKDIR /work
