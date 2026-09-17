#!/usr/bin/env bash
# Run every workspace package's tests. Mirrors CI.
set -uo pipefail
DART="${DART:-dart}"
fail=0
for pkg in packages/* apps/engine-host apps/desktop apps/updater plugin-host test-server; do
  if [ -d "$pkg/test" ] && ls "$pkg/test"/*_test.dart >/dev/null 2>&1; then
    echo "=== $pkg"
    (cd "$pkg" && "$DART" test) || fail=1
  fi
done
exit $fail
