# A NON-threaded Chez Scheme, for `make check-nothreads-docker` (#41).
#
# chez-libuv needs a threaded Chez: Chez builds make-mutex and the rest of its
# thread system only into threaded builds, and the binding uses them. Chez 10
# builds threaded by default, so every Chez this project otherwise runs on is
# threaded, and any claim about the other kind is a comment unless something
# runs one. This image is that something: the same pinned release the
# valgrind image builds, configured with --nothreads.
#
# As in valgrind.Dockerfile, the Chez version arrives as a build arg the
# Makefile derives from ci.yml's CHEZ_FLOOR_VERSION.
FROM debian:bookworm

ARG CHEZ_VERSION
RUN test -n "$CHEZ_VERSION" || (echo "build-arg CHEZ_VERSION is required" >&2; exit 1)

# Only what building Chez needs. The pinned thing in this image is the Chez
# release; the toolchain follows bookworm, as valgrind.Dockerfile's does.
# hadolint ignore=DL3008
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates uuid-dev \
 && rm -rf /var/lib/apt/lists/*

# --nothreads is the point. --disable-x11 --disable-curses and the SERIAL make
# are valgrind.Dockerfile's: the expeditor wants headers this image lacks, and
# a parallel bootstrap races. One layer, with a cd rather than a WORKDIR, so
# the source tree never lands in the image.
# hadolint ignore=DL3003
RUN curl -fsSL -o /tmp/chez.tar.gz \
      "https://github.com/cisco/ChezScheme/releases/download/v${CHEZ_VERSION}/csv${CHEZ_VERSION}.tar.gz" \
 && tar xzf /tmp/chez.tar.gz -C /tmp \
 && cd "/tmp/csv${CHEZ_VERSION}" \
 && ./configure --nothreads --disable-x11 --disable-curses --prefix=/usr/local \
 && make \
 && make install \
 && rm -rf "/tmp/csv${CHEZ_VERSION}" /tmp/chez.tar.gz

# The check only reads the mounted sources and writes to /tmp.
RUN useradd --create-home --uid 1000 dev
USER dev
WORKDIR /home/dev
