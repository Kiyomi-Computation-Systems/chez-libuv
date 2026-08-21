#!/bin/sh
# spike/dns/apply-probe-constants.sh — substitute probe-dns's per-runner
# values into the "(define NAME <int>)" constants blocks of spike/dns .ss
# scripts, so a CI leg runs the committed scripts against runner-correct
# (e.g. glibc) constants instead of the Darwin values recorded for the
# macOS leg (spike/dns/FINDINGS.md's PENDING-CI recipes).
#
# Usage:
#   apply-probe-constants.sh <probe-binary> <file.ss>...
#
# <probe-binary> --scheme must print "NAME value" lines (decimal, one per
# line; see spike/dns/probe-dns.c). For each such NAME, every
# "(define NAME <int>)" line in every listed file is rewritten in place with
# the probed value substituted for the integer — everything else on the
# line, including alignment whitespace and any trailing comment, is left
# exactly as it was. A NAME with no matching "(define ...)" line in any
# listed file is silently skipped (not every probed constant is necessarily
# used by every script); a "(define ...)" line whose NAME the probe did not
# print is left untouched.
#
# Idempotent: running twice with the same probe output produces no further
# change (the second run's substitution is a no-op, same value for same
# value).
#
# POSIX sh/awk/sed only — this runs both on the ubuntu-latest CI runner and,
# for the local no-op validation, on macOS's BSD awk/sed. No GNU-only sed -i
# (BSD sed's -i has an incompatible, non-optional-argument syntax): each
# file is rewritten via sed writing to a temp file, then the temp file's
# content is copied back over the original with cat, preserving the
# original file's inode/permissions.

set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: apply-probe-constants.sh <probe-binary> <file.ss>..." >&2
  exit 2
fi

probe_bin="$1"
shift

consts="$(mktemp)"
sed_script="$(mktemp)"
trap 'rm -f "$consts" "$sed_script"' EXIT

"$probe_bin" --scheme > "$consts"

# One sed -E substitution per probed NAME. Only the integer between NAME and
# the closing paren is matched (and NOT captured); the two surrounding
# capture groups reproduce everything else on the matched span verbatim, so
# whitespace/alignment before the value and the value's own closing paren
# survive untouched. [[:space:]] (not \t) is used for portability: it is a
# POSIX bracket-expression class, unlike sed's \t which is a GNU extension
# BSD/macOS sed does not support.
awk '
  {
    name = $1
    val  = $2
    printf "s/(\\(define[[:space:]]+%s[[:space:]]+)-?[0-9]+(\\))/\\1%s\\2/\n", name, val
  }
' "$consts" > "$sed_script"

for f in "$@"; do
  tmp="$(mktemp)"
  sed -E -f "$sed_script" "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
done
