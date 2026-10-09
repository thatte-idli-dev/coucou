#!/bin/bash
set -e

cd "$(dirname "$0")/.."

cat > /tmp/walkie_state_test.swift << 'EOF'
import Foundation

enum WalkieState: Equatable {
    case disconnected
    case connected(tuned: Bool)
    case waiting(started: Date)
    case inCall(mode: CallMode)
    
    enum CallMode: Equatable {
        case pushToTalk(transmitting: Bool)
        case handsFree
    }
}

enum WalkieEvent {
    case pttDown
    case pttUp
    case doubleTap
    case tap
    case peerTuned
    case peerUntuned
    case timeout
}

func nextState(_ current: WalkieState, event: WalkieEvent) -> WalkieState {
    switch (current, event) {
    case (.connected(tuned: false), .pttDown):
        return .waiting(started: Date())
        
    case (.connected(tuned: false), .doubleTap):
        return .waiting(started: Date())
        
    case (.waiting, .pttUp):
        return current
        
    case (.waiting, .peerTuned):
        return .inCall(mode: .pushToTalk(transmitting: false))
        
    case (.waiting, .timeout):
        return .connected(tuned: false)
        
    case (.inCall(.pushToTalk), .pttDown):
        return .inCall(mode: .pushToTalk(transmitting: true))
        
    case (.inCall(.pushToTalk), .pttUp):
        return .inCall(mode: .pushToTalk(transmitting: false))
        
    case (.inCall(.pushToTalk), .doubleTap):
        return .inCall(mode: .handsFree)
        
    case (.inCall, .tap):
        return .connected(tuned: false)
        
    case (.inCall, .peerUntuned):
        return .connected(tuned: false)
        
    default:
        return current
    }
}

func assert(_ condition: Bool, _ message: String) {
    guard condition else {
        print("❌ \(message)")
        exit(1)
    }
}

let testDate = Date()

var state: WalkieState = .connected(tuned: false)
assert(state == .connected(tuned: false), "Initial state should be connected(tuned: false)")

state = nextState(state, event: .pttDown)
if case .waiting = state {} else {
    print("❌ PTT down should transition to waiting")
    exit(1)
}

state = nextState(state, event: .peerTuned)
assert(state == .inCall(mode: .pushToTalk(transmitting: false)), "Peer tuned should start call")

state = nextState(state, event: .pttDown)
assert(state == .inCall(mode: .pushToTalk(transmitting: true)), "PTT down in call should enable transmit")

state = nextState(state, event: .pttUp)
assert(state == .inCall(mode: .pushToTalk(transmitting: false)), "PTT up should disable transmit")

state = nextState(state, event: .doubleTap)
assert(state == .inCall(mode: .handsFree), "Double tap should switch to hands-free")

state = nextState(state, event: .tap)
assert(state == .connected(tuned: false), "Tap should hang up")

state = nextState(state, event: .doubleTap)
if case .waiting = state {} else {
    print("❌ Double tap should start waiting")
    exit(1)
}

state = nextState(state, event: .timeout)
assert(state == .connected(tuned: false), "Timeout should return to connected")

state = nextState(state, event: .pttDown)
if case .waiting = state {} else {
    print("❌ PTT down should start waiting")
    exit(1)
}

state = nextState(state, event: .peerTuned)
assert(state == .inCall(mode: .pushToTalk(transmitting: false)), "Peer tuned should start call")

state = nextState(state, event: .peerUntuned)
assert(state == .connected(tuned: false), "Peer untuned should hang up")

print("✓ All walkie-talkie state transitions passed")
EOF

swiftc -o /tmp/walkie_state_test /tmp/walkie_state_test.swift
/tmp/walkie_state_test
rm /tmp/walkie_state_test /tmp/walkie_state_test.swift
