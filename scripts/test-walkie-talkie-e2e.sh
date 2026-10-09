#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "→ Building vendored Talky-Talky server"
cd "$SCRIPT_DIR/../tests/talky-server"
go build -o "$TEMP_DIR/talky-server" .

echo "→ Initializing server config"
cd "$TEMP_DIR"
./talky-server init --config=config.json --origin=https://test.local > channels.txt

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

cat > "$TEMP_DIR/e2e_test.swift" << 'SWIFT_EOF'
import Foundation

actor WalkieProtocolClient {
    let serverURL: String
    let channelToken: String
    var sessionID: String?
    var sessionToken: String?
    var negotiationID: String?
    var revision: Int = 0
    var currentSSEEvent: String?
    var streamTask: Task<Void, Never>?
    
    init(serverURL: String, accessCode: String) throws {
        self.serverURL = serverURL
        
        // Decode access code to extract the token
        guard let decoded = Data(base64Encoded: accessCode.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"), options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let token = json["token"] as? String else {
            throw TestError.invalidAccessCode
        }
        self.channelToken = token
    }
    
    func connect() async throws -> (sessionID: String, member: String) {
        let url = URL(string: "\(serverURL)/v3/channels/1/events")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(channelToken)", forHTTPHeaderField: "Authorization")
        
        return try await withCheckedThrowingContinuation { continuation in
            streamTask = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResp = response as? HTTPURLResponse else {
                        continuation.resume(throwing: TestError.invalidResponse)
                        return
                    }
                    
                    if httpResp.statusCode == 409 {
                        continuation.resume(throwing: TestError.channelFull)
                        return
                    }
                    
                    guard httpResp.statusCode == 200 else {
                        continuation.resume(throwing: TestError.httpError(httpResp.statusCode))
                        return
                    }
                    
                    var lineCount = 0
                    var hasResumed = false
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
                                guard let token = dict["session_token"] as? String,
                                      let eventDict = dict["event"] as? [String: Any],
                                      let sid = eventDict["session_id"] as? String,
                                      let member = eventDict["member"] as? String else {
                                    continuation.resume(throwing: TestError.invalidJoinEvent)
                                    hasResumed = true
                                    return
                                }
                                
                                await self.setSession(id: sid, token: token)
                                
                                continuation.resume(returning: (sid, member))
                                hasResumed = true
                                // Keep reading to maintain connection
                            } else if localEvent == "state" {
                                // Update negotiation ID from state events
                                if let negotiationID = dict["negotiation_id"] as? String, !negotiationID.isEmpty {
                                    await self.setNegotiationID(negotiationID)
                                }
                            }
                        }
                        
                        if lineCount > 100 && !hasResumed {
                            continuation.resume(throwing: TestError.noJoinEvent)
                            hasResumed = true
                            return
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
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
        
        let body: [String: Any] = [
            "session_id": sessionID,
            "revision": revision,
            "tuned": tuned,
            "transmitting": false,
            "restart_negotiation": false
        ]
        
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
        
        let body: [String: Any] = [
            "session_id": sessionID,
            "negotiation_id": negotiationID,
            "kind": kind,
            "payload": payload
        ]
        
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
    
    func getICE() async throws -> [[String: String]] {
        guard let sessionToken else {
            throw TestError.notConnected
        }
        
        let url = URL(string: "\(serverURL)/v3/channels/1/ice")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpResp = response as? HTTPURLResponse,
              httpResp.statusCode == 200 else {
            throw TestError.iceFailed
        }
        
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = dict["ice_servers"] as? [[String: Any]] else {
            throw TestError.invalidICEResponse
        }
        
        return servers.compactMap { server in
            guard let urls = server["urls"] as? String else { return nil }
            var result = ["urls": urls]
            if let username = server["username"] as? String {
                result["username"] = username
            }
            if let credential = server["credential"] as? String {
                result["credential"] = credential
            }
            return result
        }
    }
    
    func leave() async throws {
        guard let sessionID, let sessionToken else {
            throw TestError.notConnected
        }
        
        let body = ["session_id": sessionID]
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
}

@main
struct E2ETest {
    static func main() async {
        do {
            let serverURL = "http://localhost:8080"
            guard let accessCode = ProcessInfo.processInfo.environment["ACCESS_CODE"] else {
                print("❌ ACCESS_CODE environment variable not set")
                exit(1)
            }
            
            print("✓ Starting E2E test")
            
            // Client A joins
            let clientA = try WalkieProtocolClient(serverURL: serverURL, accessCode: accessCode)
            let (sidA, memberA) = try await clientA.connect()
            print("✓ Client A joined: session=\(sidA), member=\(memberA)")
            
            // Client B joins
            let clientB = try WalkieProtocolClient(serverURL: serverURL, accessCode: accessCode)
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
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
            
            // Client A sends offer
            try await clientA.sendSignal(kind: "offer", payload: ["offer": "{\"type\":\"offer\",\"sdp\":\"v=0...\"}"], negotiationID: negotiationID)
            print("✓ Client A sent offer")
            
            // Client B sends answer
            try await clientB.sendSignal(kind: "answer", payload: ["answer": "{\"type\":\"answer\",\"sdp\":\"v=0...\"}"], negotiationID: negotiationID)
            print("✓ Client B sent answer")
            
            // Client B sends ICE candidate
            try await clientB.sendSignal(kind: "candidate", payload: ["ice_candidate": "{\"candidate\":\"candidate:1 1 UDP...\"}"], negotiationID: negotiationID)
            print("✓ Client B sent ICE candidate")
            
            // Both request ICE servers
            let iceA = try await clientA.getICE()
            print("✓ Client A got ICE servers: \(iceA.count) servers")
            
            let iceB = try await clientB.getICE()
            print("✓ Client B got ICE servers: \(iceB.count) servers")
            
            // Verify TURN credentials exist
            var hasTURN = false
            for server in iceA {
                if let urls = server["urls"], urls.hasPrefix("turn:") {
                    if server["username"] != nil && server["credential"] != nil {
                        hasTURN = true
                        print("✓ ICE servers include TURN with credentials")
                        break
                    }
                }
            }
            
            if !hasTURN {
                print("⚠️  No TURN server with credentials found (STUN-only)")
            }
            
            // Client A leaves
            try await clientA.leave()
            print("✓ Client A left")
            
            // Client B leaves
            try await clientB.leave()
            print("✓ Client B left")
            
            // Third client should succeed now (channel has room)
            let clientC = try WalkieProtocolClient(serverURL: serverURL, accessCode: accessCode)
            let (sidC, memberC) = try await clientC.connect()
            print("✓ Client C joined: session=\(sidC), member=\(memberC)")
            
            // Fourth client joins
            let clientD = try WalkieProtocolClient(serverURL: serverURL, accessCode: accessCode)
            let (sidD, memberD) = try await clientD.connect()
            print("✓ Client D joined: session=\(sidD), member=\(memberD)")
            
            // Fifth client should get 409 (channel full)
            let clientE = try WalkieProtocolClient(serverURL: serverURL, accessCode: accessCode)
            do {
                _ = try await clientE.connect()
                print("❌ Client E should have received 409 but connected successfully")
                exit(1)
            } catch TestError.channelFull {
                print("✓ Client E got 409 (channel full)")
            }
            
            // Cleanup
            try await clientC.leave()
            try await clientD.leave()
            print("✓ Cleanup complete")
            
            print("\n✅ All E2E tests passed")
            exit(0)
            
        } catch {
            print("\n❌ E2E test failed: \(error)")
            exit(1)
        }
    }
}
SWIFT_EOF

echo "→ Running E2E signaling test"
swiftc -parse-as-library -o "$TEMP_DIR/e2e_test" "$TEMP_DIR/e2e_test.swift"
export ACCESS_CODE="$ACCESS_CODE"
"$TEMP_DIR/e2e_test"
