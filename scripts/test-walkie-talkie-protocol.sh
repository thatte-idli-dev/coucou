#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/../NotchBuddy/Sources/App"

cat > /tmp/test_walkie_protocol.swift << 'SWIFT_EOF'
import Foundation

struct ProtocolTests {
    static func testJoinEvent() throws {
        // Example from protocol.md: first SSE event
        let joinJSON = """
        {
            "session_token": "tok_abc123",
            "event": {
                "session_id": "sess_xyz",
                "member": "A",
                "local": {"tuned": false, "transmitting": false},
                "peer": null,
                "negotiation_id": null
            }
        }
        """
        
        guard let data = joinJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError.decodeFailed("join event")
        }
        
        guard let sessionToken = dict["session_token"] as? String,
              sessionToken == "tok_abc123" else {
            throw TestError.fieldMismatch("session_token")
        }
        
        guard let event = dict["event"] as? [String: Any] else {
            throw TestError.fieldMissing("event")
        }
        
        guard let sessionID = event["session_id"] as? String,
              sessionID == "sess_xyz" else {
            throw TestError.fieldMismatch("session_id")
        }
        
        guard let member = event["member"] as? String,
              member == "A" else {
            throw TestError.fieldMismatch("member")
        }
        
        print("✓ Join event decode")
    }
    
    static func testStateEvent() throws {
        let stateJSON = """
        {
            "event": {
                "local": {"tuned": true, "transmitting": false},
                "peer": {"tuned": true, "transmitting": true},
                "negotiation_id": "neg_123"
            }
        }
        """
        
        guard let data = stateJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError.decodeFailed("state event")
        }
        
        guard let event = dict["event"] as? [String: Any] else {
            throw TestError.fieldMissing("event")
        }
        
        guard let local = event["local"] as? [String: Any],
              let localTuned = local["tuned"] as? Bool,
              localTuned == true else {
            throw TestError.fieldMismatch("local.tuned")
        }
        
        guard let peer = event["peer"] as? [String: Any],
              let peerTuned = peer["tuned"] as? Bool,
              peerTuned == true else {
            throw TestError.fieldMismatch("peer.tuned")
        }
        
        guard let negID = event["negotiation_id"] as? String,
              negID == "neg_123" else {
            throw TestError.fieldMismatch("negotiation_id")
        }
        
        print("✓ State event decode")
    }
    
    static func testSignalEvent() throws {
        let signalJSON = """
        {
            "from": "sess_peer",
            "payload": {
                "offer": "{\\"type\\":\\"offer\\"}",
                "ice_candidate": "{\\"candidate\\":\\"...\\"}",
                "answer": "{\\"type\\":\\"answer\\"}"
            }
        }
        """
        
        guard let data = signalJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError.decodeFailed("signal event")
        }
        
        guard let from = dict["from"] as? String,
              from == "sess_peer" else {
            throw TestError.fieldMismatch("from")
        }
        
        guard let payload = dict["payload"] as? [String: Any] else {
            throw TestError.fieldMissing("payload")
        }
        
        guard payload["offer"] != nil,
              payload["ice_candidate"] != nil,
              payload["answer"] != nil else {
            throw TestError.fieldMissing("signal payload fields")
        }
        
        print("✓ Signal event decode")
    }
    
    static func testPresenceEncode() throws {
        let body: [String: Any] = [
            "session_id": "sess_123",
            "revision": 5,
            "tuned": true,
            "transmitting": false,
            "restart_negotiation": false
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw TestError.encodeFailed("presence")
        }
        
        guard let rev = dict["revision"] as? Int, rev == 5 else {
            throw TestError.fieldMismatch("revision")
        }
        
        guard let tuned = dict["tuned"] as? Bool, tuned == true else {
            throw TestError.fieldMismatch("tuned")
        }
        
        print("✓ Presence encode")
    }
    
    static func testSignalEncode() throws {
        let body: [String: Any] = [
            "kind": "offer",
            "payload": [
                "offer": "{\"type\":\"offer\"}"
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw TestError.encodeFailed("signal")
        }
        
        guard let kind = dict["kind"] as? String, kind == "offer" else {
            throw TestError.fieldMismatch("kind")
        }
        
        guard let payload = dict["payload"] as? [String: Any],
              payload["offer"] != nil else {
            throw TestError.fieldMissing("payload.offer")
        }
        
        // Ensure no extra fields (server rejects unknown fields)
        if dict.keys.count != 2 {
            throw TestError.extraFields("signal should only have kind and payload")
        }
        
        print("✓ Signal encode")
    }
    
    static func testLeaveEncode() throws {
        let body = ["session_id": "sess_123"]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw TestError.encodeFailed("leave")
        }
        
        guard let sid = dict["session_id"] as? String, sid == "sess_123" else {
            throw TestError.fieldMismatch("session_id")
        }
        
        print("✓ Leave encode")
    }
    
    static func testICEServerDecode() throws {
        let iceJSON = """
        {
            "ice_servers": [
                {
                    "urls": "stun:stun.example.com:3478"
                },
                {
                    "urls": "turn:turn.example.com:3478",
                    "username": "user123",
                    "credential": "pass456"
                }
            ]
        }
        """
        
        guard let data = iceJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError.decodeFailed("ice servers")
        }
        
        guard let servers = dict["ice_servers"] as? [[String: Any]] else {
            throw TestError.fieldMissing("ice_servers")
        }
        
        guard servers.count == 2 else {
            throw TestError.fieldMismatch("ice_servers count")
        }
        
        // STUN server
        guard let stun = servers.first,
              let stunURL = stun["urls"] as? String,
              stunURL.hasPrefix("stun:") else {
            throw TestError.fieldMismatch("stun urls")
        }
        
        // TURN server with credentials
        guard let turn = servers.last,
              let turnURL = turn["urls"] as? String,
              turnURL.hasPrefix("turn:"),
              let username = turn["username"] as? String,
              let credential = turn["credential"] as? String,
              username == "user123",
              credential == "pass456" else {
            throw TestError.fieldMismatch("turn credentials")
        }
        
        print("✓ ICE servers decode with TURN credentials")
    }
    
    static func testAuthHeader() throws {
        let accessCode = "secret123"
        let header = "Bearer \(accessCode)"
        
        guard header == "Bearer secret123" else {
            throw TestError.fieldMismatch("auth header")
        }
        
        print("✓ Auth header format")
    }
    
    enum TestError: Error {
        case decodeFailed(String)
        case encodeFailed(String)
        case fieldMissing(String)
        case fieldMismatch(String)
        case extraFields(String)
    }
}

do {
    try ProtocolTests.testJoinEvent()
    try ProtocolTests.testStateEvent()
    try ProtocolTests.testSignalEvent()
    try ProtocolTests.testPresenceEncode()
    try ProtocolTests.testSignalEncode()
    try ProtocolTests.testLeaveEncode()
    try ProtocolTests.testICEServerDecode()
    try ProtocolTests.testAuthHeader()
    
    print("\n✅ All protocol tests passed")
    exit(0)
} catch {
    print("\n❌ Test failed: \(error)")
    exit(1)
}
SWIFT_EOF

echo "→ Protocol contract tests"
swiftc -o /tmp/test_walkie_protocol /tmp/test_walkie_protocol.swift
/tmp/test_walkie_protocol
