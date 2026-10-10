#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swiftc \
  -parse-as-library \
  NotchBuddy/Sources/App/WalkieProtocol.swift \
  NotchBuddy/Tests/WalkieLevelsTest.swift \
  -o /tmp/walkie-levels-test

/tmp/walkie-levels-test
