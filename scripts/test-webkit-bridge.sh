#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/NotchBuddy/Tests"

echo "🧪 WebKit Bridge Test"
echo "====================="
echo

# Compile the WebKit bridge test
echo "🔨 Compiling WebKit bridge test..."
TEST_BUILD_DIR=$(mktemp -d)
trap "rm -rf $TEST_BUILD_DIR" EXIT

swiftc \
    -parse-as-library \
    -o "$TEST_BUILD_DIR/webkit-bridge-test" \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -target arm64-apple-macosx13.0 \
    -framework WebKit \
    -framework AppKit \
    -I "$PROJECT_ROOT/NotchBuddy/Sources/App" \
    "$PROJECT_ROOT/NotchBuddy/Sources/App/WalkieTalkieHTML.swift" \
    "$TEST_DIR/WebKitBridgeTest.swift"

if [ $? -ne 0 ]; then
    echo "❌ Compilation failed"
    exit 1
fi

echo "✅ Compilation successful"
echo

# Run the test
echo "🧪 Running WebKit bridge test..."
echo "================================"
echo

"$TEST_BUILD_DIR/webkit-bridge-test"

TEST_EXIT_CODE=$?

echo
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "✅ WebKit bridge test passed!"
    exit 0
else
    echo "❌ WebKit bridge test failed with exit code $TEST_EXIT_CODE"
    exit $TEST_EXIT_CODE
fi
