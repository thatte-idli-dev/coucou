#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "→ Building vendored Talky-Talky server"
cd "$SCRIPT_DIR/../tests/talky-server"
go build -o "$TEMP_DIR/talky-server" .

echo "→ Initializing server config with TURN servers"
cd "$TEMP_DIR"
# Server now allows HTTP for localhost origins (patched for testing)
./talky-server init --config=config.json --origin=http://127.0.0.1:8080 > channels.txt

# Add TURN config
python3 -c "
import json
with open('config.json', 'r') as f:
    config = json.load(f)
config['relay_urls'] = ['turn:127.0.0.1:3478', 'turns:127.0.0.1:5349']
config['relay_secret'] = 'test-turn-secret-key'
with open('config.json', 'w') as f:
    json.dump(config, f, indent=2)
"

echo "→ Extracting channel 1 access code"
ACCESS_CODE=$(grep "Channel 1:" channels.txt | awk '{print $3}')
if [ -z "$ACCESS_CODE" ] || [ "$ACCESS_CODE" == "null" ]; then
    echo "❌ Failed to mint access code"
    exit 1
fi
echo "   Access code: $ACCESS_CODE"

echo "→ Starting server in background"
./talky-server serve --config=config.json --listen=127.0.0.1:8080 &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true; rm -rf $TEMP_DIR" EXIT

sleep 2

echo "→ Compiling E2E test with app protocol source"
cat > "$TEMP_DIR/e2e_test.swift" << 'SWIFT_EOF'
import Foundation

// Use the real app WalkieProtocol (compiled alongside)

actor WalkieTestClient {
    let serverURL: String
    let channelToken: String
    var sessionID: String?
    var sessionToken: String?
    var negotiationID: String?
    var revision: Int = 0
    var streamTask: Task<Void, Never>?
    
    init(accessCode: String) throws {
        guard let components = WalkieProtocol.decodeAccessCode(accessCode) else {
            throw TestError.invalidAccessCode
        }
        self.serverURL = components.origin
        self.channelToken = components.channelToken
    }
    
    func connect() async throws -> (sessionID: String, member: String) {
        let url = URL(string: "\(serverURL)/v3/channels/1/events")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(channelToken)", forHTTPHeaderField: "Authorization")
        
        return try await withCheckedThrowingContinuation { continuation in
            streamTask = Task {
                var hasResumed = false
                
                func resumeOnce(with result: Result<(sessionID: String, member: String), Error>) {
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(with: result)
                }
                
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResp = response as? HTTPURLResponse else {
                        resumeOnce(with: .failure(TestError.invalidResponse))
                        return
                    }
                    
                    if httpResp.statusCode == 409 {
                        resumeOnce(with: .failure(TestError.channelFull))
                        return
                    }
                    
                    guard httpResp.statusCode == 200 else {
                        resumeOnce(with: .failure(TestError.httpError(httpResp.statusCode)))
                        return
                    }
                    
                    var lineCount = 0
                    var localEvent: String?
                    for try await line in bytes.lines {
                        lineCount += 1
                        if line.hasPrefix("event: ") {
                            localEvent = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            let json = String(line.dropFirst(6))
                            guard let data = json.data(using: .utf8),
                                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                continue
                            }
                            
                            if localEvent == "snapshot" && !hasResumed {
                                guard let snapshot = WalkieProtocol.parseSnapshotEvent(dict) else {
                                    resumeOnce(with: .failure(TestError.invalidJoinEvent))
                                    return
                                }
                                
                                await self.setSession(
                                    id: snapshot.sessionID,
                                    token: snapshot.sessionToken
                                )
                                
                                resumeOnce(with: .success((snapshot.sessionID, snapshot.member)))
                            } else if localEvent == "state" {
                                if let stateEvent = WalkieProtocol.parseStateEvent(dict),
                                   let negID = stateEvent.negotiationID {
                                    await self.setNegotiationID(negID)
                                }
                            }
                        }
                        
                        if lineCount > 100 && !hasResumed {
                            resumeOnce(with: .failure(TestError.noJoinEvent))
                            return
                        }
                    }
                    
                    if !hasResumed {
                        resumeOnce(with: .failure(TestError.noJoinEvent))
                    }
                } catch {
                    resumeOnce(with: .failure(error))
                }
            }
        }
    }
    
    private func setSession(id: String, token: String) {
        self.sessionID = id
        self.sessionToken = token
        self.revision = 0
    }
    
    private func setNegotiationID(_ id: String) {
        self.negotiationID = id
    }
    
    func getNegotiationID() -> String? {
        return negotiationID
    }
    
    func sendPresence(tuned: Bool) async throws {
        guard let sessionID, let sessionToken else {
            throw TestError.notConnected
        }
        
        revision += 1
        
        let body = WalkieProtocol.buildPresenceBody(
            sessionID: sessionID,
            revision: revision,
            tuned: tuned,
            transmitting: false,
            restartNegotiation: false
        )
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            throw TestError.encodeFailed
        }
        
        let url = URL(string: "\(serverURL)/v3/channels/1/presence")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let httpResp = response as? HTTPURLResponse,
              httpResp.statusCode == 200 else {
            throw TestError.presenceFailed
        }
    }
    
    func sendSignal(kind: String, payload: [String: String], negotiationID: String) async throws {
        guard let sessionID, let sessionToken else {
            throw TestError.notConnected
        }
        
        let body = WalkieProtocol.buildSignalBody(
            sessionID: sessionID,
            negotiationID: negotiationID,
            kind: kind,
            payload: payload
        )
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            throw TestError.encodeFailed
        }
        
        let url = URL(string: "\(serverURL)/v3/channels/1/signal")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let httpResp = response as? HTTPURLResponse,
              httpResp.statusCode == 200 else {
            throw TestError.signalFailed
        }
    }
    
    func getICE() async throws -> WalkieProtocol.ICEServerConfig? {
        guard let sessionToken else {
            throw TestError.notConnected
        }
        
        let url = URL(string: "\(serverURL)/v3/channels/1/ice")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw TestError.invalidResponse
        }
        
        if httpResp.statusCode == 503 {
            return nil
        }
        
        guard httpResp.statusCode == 200 else {
            throw TestError.iceFailed
        }
        
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = WalkieProtocol.parseICEResponse(dict) else {
            throw TestError.invalidICEResponse
        }
        
        return config
    }
    
    func leave() async throws {
        guard let sessionID, let sessionToken else {
            throw TestError.notConnected
        }
        
        let body = WalkieProtocol.buildLeaveBody(sessionID: sessionID)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            throw TestError.encodeFailed
        }
        
        let url = URL(string: "\(serverURL)/v3/channels/1/session")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let httpResp = response as? HTTPURLResponse,
              httpResp.statusCode == 200 || httpResp.statusCode == 204 else {
            throw TestError.leaveFailed
        }
        
        streamTask?.cancel()
        streamTask = nil
        self.sessionID = nil
        self.sessionToken = nil
        self.revision = 0
    }
}

enum TestError: Error {
    case invalidAccessCode
    case invalidResponse
    case httpError(Int)
    case channelFull
    case invalidJoinEvent
    case noJoinEvent
    case notConnected
    case encodeFailed
    case presenceFailed
    case signalFailed
    case iceFailed
    case invalidICEResponse
    case leaveFailed
    case noTURNCredentials
}

@main
struct WalkieE2ETest {
    static func main() async {
        do {
            let serverURL = "http://127.0.0.1:8080"
            let accessCode = ProcessInfo.processInfo.environment["ACCESS_CODE"]!
            
            print("✓ Starting E2E test")
            
            // Client A joins
            let clientA = try WalkieTestClient(accessCode: accessCode)
            let (sidA, memberA) = try await clientA.connect()
            print("✓ Client A joined: session=\(sidA), member=\(memberA)")
            
            // Client B joins
            let clientB = try WalkieTestClient(accessCode: accessCode)
            let (sidB, memberB) = try await clientB.connect()
            print("✓ Client B joined: session=\(sidB), member=\(memberB)")
            
            if sidA == sidB {
                print("❌ Both clients got same session ID")
                exit(1)
            }
            
            // Both send presence with tuned=true
            try await clientA.sendPresence(tuned: true)
            print("✓ Client A sent presence (tuned=true, revision=1)")
            
            try await clientB.sendPresence(tuned: true)
            print("✓ Client B sent presence (tuned=true, revision=1)")
            
            // Wait for negotiation_id from state events
            var negotiationID: String?
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if let nid = await clientA.getNegotiationID() {
                    negotiationID = nid
                    break
                }
            }
            
            guard let negotiationID else {
                print("❌ No negotiation_id received")
                exit(1)
            }
            print("✓ Negotiation ID: \(negotiationID)")
            
            // Fetch ICE servers before signaling
            guard let iceConfig = try await clientA.getICE() else {
                print("❌ No ICE servers returned (expected TURN)")
                exit(1)
            }
            
            // Verify TURN credentials exist (hard requirement)
            let hasTURN = iceConfig.urls.contains { $0.starts(with: "turn:") || $0.starts(with: "turns:") }
            guard hasTURN, 
                  let username = iceConfig.username, !username.isEmpty,
                  let credential = iceConfig.credential, !credential.isEmpty else {
                print("❌ TURN servers must include valid credentials")
                throw TestError.noTURNCredentials
            }
            print("✓ Client A got ICE with TURN credentials (username: \(username))")
            
            // Client A sends offer
            try await clientA.sendSignal(
                kind: "offer",
                payload: ["offer": "{\"type\":\"offer\",\"sdp\":\"v=0...\"}"],
                negotiationID: negotiationID
            )
            print("✓ Client A sent offer")
            
            // Client B sends answer
            try await clientB.sendSignal(
                kind: "answer",
                payload: ["answer": "{\"type\":\"answer\",\"sdp\":\"v=0...\"}"],
                negotiationID: negotiationID
            )
            print("✓ Client B sent answer")
            
            // Client B sends ICE candidate
            try await clientB.sendSignal(
                kind: "candidate",
                payload: ["ice_candidate": "{\"candidate\":\"candidate:1 1 UDP...\"}"],
                negotiationID: negotiationID
            )
            print("✓ Client B sent ICE candidate")
            
            // Client A leaves
            try await clientA.leave()
            print("✓ Client A left")
            
            // Client B leaves
            try await clientB.leave()
            print("✓ Client B left")
            
            // Third client should succeed now (channel has room)
            let clientC = try WalkieTestClient(accessCode: accessCode)
            let (sidC, memberC) = try await clientC.connect()
            print("✓ Client C joined: session=\(sidC), member=\(memberC)")
            
            // Fourth client joins
            let clientD = try WalkieTestClient(accessCode: accessCode)
            let (sidD, memberD) = try await clientD.connect()
            print("✓ Client D joined: session=\(sidD), member=\(memberD)")
            
            // Fifth client should get 409 (channel full)
            let clientE = try WalkieTestClient(accessCode: accessCode)
            do {
                _ = try await clientE.connect()
                print("❌ Client E should have gotten 409")
                exit(1)
            } catch TestError.channelFull {
                print("✓ Client E got 409 (channel full)")
            }
            
            // Cleanup
            try? await clientC.leave()
            try? await clientD.leave()
            print("✓ Cleanup complete")
            
            print("")
            print("✅ All E2E tests passed")
            
        } catch {
            print("")
            print("❌ E2E test failed: \(error)")
            exit(1)
        }
    }
}
SWIFT_EOF

echo "→ Running E2E signaling test"
cd "$TEMP_DIR"
swiftc \
    -o e2e_test \
    "$SCRIPT_DIR/../NotchBuddy/Sources/App/WalkieProtocol.swift" \
    e2e_test.swift

ACCESS_CODE="$ACCESS_CODE" ./e2e_test
