#!/bin/sh
# Usage: check-nothreads.sh SRC_DIR
#
# Run by `make check-nothreads-docker` inside docker/nothreads.Dockerfile's
# image, as the unprivileged user, on a copy of the repo's src/ that root
# made inside the container: the host checkout's own owner and modes then
# cannot hide files from that user. NOTHREADS_MARKER is the text the
# refusal must print.
#
# chez-libuv needs a threaded Chez (#41). On a --nothreads Chez, importing
# ANY public library must be stopped BY (libuv private require-threaded): a
# non-zero exit, and the first exception printed carries the marker. The
# marker anywhere in the output is not enough. A refusal that only printed
# its message would let the import go on, to fail with the "missing import
# for make-mutex" the refusal exists to pre-empt.
set -u

if [ -z "${NOTHREADS_MARKER:-}" ]; then
  echo "check-nothreads: NOTHREADS_MARKER is not set" >&2
  exit 1
fi
src=${1:-}
if [ -z "$src" ]; then
  echo "check-nothreads: usage: check-nothreads.sh SRC_DIR" >&2
  exit 1
fi

# A green run means something only on a Chez that really is non-threaded.
# Exit 3 is the answer "threaded"; any other failure means Chez did not run
# at all (not on PATH: 127), which must not read as a threaded build.
printf '(exit (if (threaded?) 3 0))\n' | scheme -q
rc=$?
case "$rc" in
  0) echo "precondition holds: (threaded?) is #f in this Chez" ;;
  3) echo "NOT A NON-THREADED CHEZ: (threaded?) is #t here, so this check proves nothing" >&2
     exit 1 ;;
  *) echo "COULD NOT RUN CHEZ: 'scheme -q' exited $rc, so this check proves nothing" >&2
     exit 1 ;;
esac

# Every public library, from the files, so a new one is covered without an
# edit here. A glob that matched nothing stays literal and fails below: an
# empty scan cannot pass.
fail=0
for f in "$src/libuv.sls" "$src"/libuv/*.sls; do
  if [ "$f" = "$src/libuv.sls" ]; then
    lib="(libuv)"
  else
    lib="(libuv $(basename "$f" .sls))"
  fi
  printf '(import %s)\n' "$lib" > /tmp/probe.sps
  CHEZSCHEMELIBDIRS="$src" scheme --program /tmp/probe.sps > /tmp/probe.out 2>&1
  rc=$?
  first=$(grep -m 1 '^Exception' /tmp/probe.out)
  if [ "$rc" -ne 0 ] && printf '%s\n' "$first" | grep -qF "$NOTHREADS_MARKER"; then
    echo "refused by name: $lib"
  else
    echo "NOT REFUSED BY NAME: $lib (exit $rc), which printed:" >&2
    sed 's/^/    /' /tmp/probe.out >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "NOTHREADS REFUSED BY NAME"
else
  echo "NOTHREADS CHECK FAILED"
fi
exit "$fail"
