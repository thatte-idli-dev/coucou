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

# Initialize server config
echo "📝 Initializing server configuration..."
CONFIG_FILE="$TALKY_SERVER_DIR/config.json"
ACCESS_CODES_FILE="$TALKY_SERVER_DIR/access_codes.txt"

./talky-server init --config "$CONFIG_FILE" --origin "http://localhost:8080" > "$ACCESS_CODES_FILE" 2>&1

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Failed to create config file"
    exit 1
fi

# Fix config file permissions (must be 0600)
chmod 0600 "$CONFIG_FILE"

# Add TURN configuration to the config file
# The server expects relay_urls and relay_secret in the config JSON
python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)
config['relay_urls'] = ['turn:turn.example.com:3478']
config['relay_secret'] = 'test-secret-key'
with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null || {
    echo "⚠️  Warning: Could not add TURN config (Python not available or failed)"
}

chmod 0600 "$CONFIG_FILE"

# Extract channel 1 access code - both clients will use the same code
# The first to connect becomes seat A, the second becomes seat B
ACCESS_CODE=$(grep "Channel 1:" "$ACCESS_CODES_FILE" | cut -d' ' -f3)

if [ -z "$ACCESS_CODE" ]; then
    echo "❌ Error: Failed to extract access code"
    cat "$ACCESS_CODES_FILE"
    exit 1
fi

echo "✅ Server configured with access code and TURN"
echo

# Start the server
echo "🚀 Starting Talky-Talky server on port 8080..."

./talky-server serve --config "$CONFIG_FILE" --listen "127.0.0.1:8080" &
SERVER_PID=$!

# Ensure server is killed on exit
trap "echo '🛑 Stopping server...'; kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true; rm -f '$CONFIG_FILE' '$ACCESS_CODES_FILE'" EXIT

echo "⏳ Waiting for server to start..."
sleep 2

# Test server is responding (the server doesn't have a /health endpoint, try root)
if ! curl -s http://localhost:8080/ > /dev/null 2>&1; then
    echo "⚠️  Warning: Server may not be ready yet, continuing anyway..."
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

"$TEST_BUILD_DIR/walkie-e2e-test" http://localhost:8080 "$ACCESS_CODE" "$ACCESS_CODE"

TEST_EXIT_CODE=$?

echo
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "✅ All tests passed!"
    exit 0
else
    echo "❌ Tests failed with exit code $TEST_EXIT_CODE"
    exit $TEST_EXIT_CODE
fi
