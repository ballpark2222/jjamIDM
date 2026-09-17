#!/usr/bin/env bash
# Run every workspace package's tests. Mirrors CI.
set -uo pipefail
DART="${DART:-dart}"
FLUTTER="${FLUTTER:-flutter}"
fail=0
for pkg in packages/* apps/engine-host apps/desktop apps/updater plugin-host test-server; do
  if [ -d "$pkg/test" ] && ls "$pkg/test"/*_test.dart >/dev/null 2>&1; then
    echo "=== $pkg"
    # Widget tests need the Flutter test runner, not `dart test`.
    if grep -q "sdk: flutter" "$pkg/pubspec.yaml" 2>/dev/null; then
      (cd "$pkg" && "$FLUTTER" test) || fail=1
    else
      (cd "$pkg" && "$DART" test) || fail=1
    fi
  fi
done
exit $fail
