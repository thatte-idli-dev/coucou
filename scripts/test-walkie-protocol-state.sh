#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swiftc \
  -parse-as-library \
  NotchBuddy/Sources/App/WalkieProtocol.swift \
  NotchBuddy/Tests/WalkieProtocolParseStateTest.swift \
  -o /tmp/walkie-protocol-state-test

/tmp/walkie-protocol-state-test
