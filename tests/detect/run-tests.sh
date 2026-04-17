#!/usr/bin/env bash
# run-tests.sh — harness for the detect-distro.sh unit tests.
#
# Discovers every test_*.sh next to this file and runs each in its own
# bash subshell (so tests can't leak state into each other). Each test
# script uses the assert::* helpers exposed by lib.sh.
#
# Exit 0 on all-green, 1 on any failure.

set -euCo pipefail
shopt -s expand_aliases

cd "$(dirname "$(readlink -f "$0")")"

# Export paths to the library and the fixture dir so tests don't compute them.
export DETECT_LIB="$(readlink -f ../../.chezmoitemplates/detect-distro.sh)"
export FIXTURES_DIR="$(readlink -f fixtures)"

export ASSERT_PASS=0
export ASSERT_FAIL=0

# shellcheck disable=SC1091
. ./lib.sh

found=0
passed_files=0
failed_files=0

shopt -s nullglob
for test_file in test_*.sh; do
  found=$((found + 1))
  printf '\n=== %s ===\n' "$test_file"
  if bash -c "
    set -euCo pipefail
    export DETECT_LIB='$DETECT_LIB'
    export FIXTURES_DIR='$FIXTURES_DIR'
    . '$(pwd)/lib.sh'
    . '$(pwd)/$test_file'
    exit \$ASSERT_FAIL_LOCAL
  "; then
    passed_files=$((passed_files + 1))
  else
    failed_files=$((failed_files + 1))
  fi
done

printf '\n======================================\n'
printf 'test files: %d passed, %d failed (of %d)\n' "$passed_files" "$failed_files" "$found"
(( failed_files == 0 ))
