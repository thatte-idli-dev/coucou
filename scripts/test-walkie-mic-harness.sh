#!/bin/bash
set -euo pipefail

# Compiles a tiny app that uses the production WalkieTalkieAudio + HTML and
# calls probeMic. Default: compile only (CI typecheck).
# On a real Mac, verify capture with:
#   bash scripts/test-walkie-mic-harness.sh --run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/NotchBuddy/Sources/App"

RUN_HARNESS=0
if [[ "${1:-}" == "--run" ]]; then
  RUN_HARNESS=1
fi

echo "🧪 Walkie mic harness"
echo "====================="
echo

if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ swiftc is not available (this script is meant for macOS / CI)."
  exit 1
fi

BUILD_DIR=$(mktemp -d)
cleanup() {
  if [[ "$RUN_HARNESS" -eq 0 ]]; then
    rm -rf "$BUILD_DIR"
  fi
}
trap cleanup EXIT

SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then
  TARGET="x86_64-apple-macosx15.0"
else
  TARGET="arm64-apple-macosx15.0"
fi
echo "🔨 Compiling Walkie mic harness (sdk=$(basename "$SDK") target=$TARGET)..."

swiftc \
    -parse-as-library \
    -o "$BUILD_DIR/WalkieMicHarness" \
    -sdk "$SDK" \
    -target "$TARGET" \
    -strict-concurrency=complete \
    -framework WebKit \
    -framework AppKit \
    -framework AVFoundation \
    "$SOURCE_DIR/WalkieTalkieHTML.swift" \
    "$SOURCE_DIR/WalkieAudioLayer.swift" \
    "$SOURCE_DIR/WalkieProtocol.swift" \
    "$SOURCE_DIR/WalkieTalkieAudio.swift" \
    "$SCRIPT_DIR/WalkieMicHarnessStubs.swift" \
    "$SCRIPT_DIR/WalkieMicHarness.swift"

echo "✅ Compilation successful"
echo

if [[ "$RUN_HARNESS" -eq 0 ]]; then
  echo "Compile-only. On a Mac with a microphone run:"
  echo "  bash scripts/test-walkie-mic-harness.sh --run"
  exit 0
fi

APP="$BUILD_DIR/WalkieMicHarness.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_DIR/WalkieMicHarness" "$APP/Contents/MacOS/WalkieMicHarness"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>fr.louisraille.NotchBuddy.WalkieMicHarness</string>
    <key>CFBundleName</key>
    <string>WalkieMicHarness</string>
    <key>CFBundleExecutable</key>
    <string>WalkieMicHarness</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>WalkieMicHarness probes getUserMedia inside WKWebView.</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

cat > "$BUILD_DIR/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign - --entitlements "$BUILD_DIR/entitlements.plist" "$APP"
echo "Signed $APP"
echo
echo "▶ Running harness (grant Microphone if prompted)..."
echo

# Exec the bundle binary so TCC sees the signed .app identity.
"$APP/Contents/MacOS/WalkieMicHarness"
