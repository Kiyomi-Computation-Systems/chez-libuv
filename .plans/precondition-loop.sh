#!/bin/sh
# Runs tests/test-level-3.sps N times and prints each run's failures.
n=${1:-10}
i=0
while [ $i -lt $n ]; do
  CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs CHEZ_LIBUV_TEST_CHEZ=$CHEZ \
    $CHEZ --program tests/test-level-3.sps 2>&1 | grep -E "FAIL|actual|# of" | tr "\n" " "
  echo
  i=$((i + 1))
done
