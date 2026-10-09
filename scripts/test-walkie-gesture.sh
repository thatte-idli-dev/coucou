#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-walkie.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ShortcutLogic.swift \
    tests/WalkieGestureTests.swift -o "$TEST_DIR/walkie-tests"
"$TEST_DIR/walkie-tests"
