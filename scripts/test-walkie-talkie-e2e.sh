#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TALKY_SERVER_DIR="$PROJECT_ROOT/tests/talky-server"
TEST_DIR="$PROJECT_ROOT/NotchBuddy/Tests"
SOURCE_DIR="$PROJECT_ROOT/NotchBuddy/Sources/App"

echo "🧪 Walkie-Talkie E2E Integration Test"
echo "======================================"
echo

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "❌ Error: Go is not installed. Please install Go to run the Talky server."
    exit 1
fi

# Check if server source exists
if [ ! -d "$TALKY_SERVER_DIR" ]; then
    echo "❌ Error: Talky server not found at $TALKY_SERVER_DIR"
    echo "   Please ensure the server is vendored under tests/talky-server/"
    exit 1
fi

echo "📦 Building Talky-Talky server..."
cd "$TALKY_SERVER_DIR"

# Build the server
go build -o talky-server .

echo "✅ Server built successfully"
echo

# Start the server with TURN configuration
echo "🚀 Starting Talky-Talky server on port 8080..."
export TALKY_TURN_URLS="turn:turn.example.com:3478"
export TALKY_TURN_USERNAME="testuser"
export TALKY_TURN_PASSWORD="testpassword"

./talky-server --port 8080 &
SERVER_PID=$!

# Ensure server is killed on exit
trap "echo '🛑 Stopping server...'; kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true" EXIT

echo "⏳ Waiting for server to start..."
sleep 2

# Test server is responding
if ! curl -s http://localhost:8080/health > /dev/null; then
    echo "❌ Error: Server did not start properly"
    exit 1
fi

echo "✅ Server is running (PID: $SERVER_PID)"
echo

# Compile the Swift test
echo "🔨 Compiling E2E test..."
cd "$PROJECT_ROOT"

# Create temp directory for compiled test
TEST_BUILD_DIR=$(mktemp -d)
trap "rm -rf $TEST_BUILD_DIR; kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true" EXIT

# Compile the test with all required files
swiftc \
    -o "$TEST_BUILD_DIR/walkie-e2e-test" \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -target arm64-apple-macosx13.0 \
    -I "$SOURCE_DIR" \
    "$SOURCE_DIR/WalkieProtocol.swift" \
    "$SOURCE_DIR/WalkieAudioLayer.swift" \
    "$TEST_DIR/FakeAudioLayer.swift" \
    "$TEST_DIR/WalkieTalkieE2ETest.swift"

if [ $? -ne 0 ]; then
    echo "❌ Compilation failed"
    exit 1
fi

echo "✅ Compilation successful"
echo

# Run the test
echo "🧪 Running E2E test..."
echo "===================="
echo

"$TEST_BUILD_DIR/walkie-e2e-test" http://localhost:8080

TEST_EXIT_CODE=$?

echo
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "✅ All tests passed!"
    exit 0
else
    echo "❌ Tests failed with exit code $TEST_EXIT_CODE"
    exit $TEST_EXIT_CODE
fi
