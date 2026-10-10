import Foundation
import AppKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct WalkieTalkieE2ETest {
    static func main() async {
        guard CommandLine.arguments.count > 3 else {
            print("❌ Usage: walkie-e2e-test <server-url> <access-code> <access-code>")
            print("   (Both clients use the same access code - first becomes seat A, second becomes seat B)")
            exit(1)
        }
        
        let serverURL = CommandLine.arguments[1]
        let accessCode = CommandLine.arguments[2]
        
        print("🔗 Testing against server: \(serverURL)")
        print("🎫 Using shared access code (first=A, second=B)")
        
        do {
            try await runAllTests(serverURL: serverURL, accessCode: accessCode)
            print("\n✅ All E2E tests passed!")
            exit(0)
        } catch {
            print("\n❌ Test failed: \(error)")
            exit(1)
        }
    }
    
    static func runAllTests(serverURL: String, accessCode: String) async throws {
        // Test 1: Full call flow with signaling
        try await testFullCallFlow(serverURL: serverURL, accessCode: accessCode)
        
        // Test 2: Tap to hang up
        try await testTapToHangup(serverURL: serverURL, accessCode: accessCode)
        
        // Test 3: Tap to cancel waiting
        try await testTapToCancelWaiting(serverURL: serverURL, accessCode: accessCode)
        
        // Test 4: Waiting timeout
        try await testWaitingTimeout(serverURL: serverURL, accessCode: accessCode)
        
        // Test 5: TURN credentials verification
        try await testTURNCredentials(serverURL: serverURL, accessCode: accessCode)
    }
    
    // MARK: - Test 1: Full Call Flow
    
    @MainActor
    static func testFullCallFlow(serverURL: String, accessCode: String) async throws {
        print("\n📞 Test 1: Full call flow with bidirectional signaling")
        print("=====================================================")
        
        // Create two link instances with fake audio layers
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        
        // Configure both clients with the same access code
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        
        // Wait for both to connect
        try await Task.sleep(for: .milliseconds(500))
        
        guard linkA.currentState != .disconnected, linkB.currentState != .disconnected else {
            throw TestError("Failed to connect to server")
        }
        
        print("✓ Both clients connected")
        
        // Client A presses PTT
        await linkA.simulatePTTDown()
        
        // Wait for state transition (PTT handling is async)
        var attempts = 0
        while true {
            if case .waiting = linkA.currentState {
                break
            }
            if attempts >= 20 {
                // Print debug traces to diagnose premature .inCall transition
                let fm = FileManager.default
                print("\n=== Diagnostic traces ===")
                if let files = try? fm.contentsOfDirectory(atPath: "/tmp").filter({ $0.hasPrefix("walkie-trace-") }) {
                    for file in files {
                        if let content = try? String(contentsOfFile: "/tmp/\(file)") {
                            print("Trace \(file):")
                            print(content)
                        }
                    }
                } else {
                    print("No trace files found in /tmp")
                }
                print("=== End traces ===\n")
                throw TestError("Client A should be waiting (state: \(linkA.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        
        print("✓ Client A is waiting")
        
        // Assert that A's mic is enabled even while waiting (before peer joins)
        guard audioA.micEnabled else {
            throw TestError("Client A's mic should be enabled while waiting for peer")
        }
        
        print("✓ Client A's mic is live while waiting")
        
        // Client B presses PTT
        await linkB.simulatePTTDown()
        
        // Wait for negotiation and both clients to be in call
        var callAttempts = 0
        while true {
            if case .inCall = linkA.currentState, case .inCall = linkB.currentState {
                break
            }
            if callAttempts >= 30 {
                throw TestError("Both should be in call (A: \(linkA.currentState), B: \(linkB.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            callAttempts += 1
        }
        
        print("✓ Both clients in call")
        
        // Assert bidirectional SDP exchange
        guard audioB.remoteOffer != nil else {
            throw TestError("Client B did not receive A's offer")
        }
        guard audioA.remoteAnswer != nil else {
            throw TestError("Client A did not receive B's answer")
        }
        
        print("✓ Bidirectional SDP exchange verified")
        
        // Assert ICE candidates exchanged
        guard !audioA.receivedIceCandidates.isEmpty else {
            throw TestError("Client A did not receive ICE candidates")
        }
        guard !audioB.receivedIceCandidates.isEmpty else {
            throw TestError("Client B did not receive ICE candidates")
        }
        
        print("✓ ICE candidates exchanged")
        
        // Client A releases PTT
        await linkA.simulatePTTUp()
        try await Task.sleep(for: .milliseconds(500))
        
        // Client B releases PTT
        await linkB.simulatePTTUp()
        try await Task.sleep(for: .milliseconds(500))
        
        // Both should return to connected/untuned
        let stateA = linkA.currentState
        let stateB = linkB.currentState
        guard case .connected(tuned: false) = stateA else {
            throw TestError("Client A should be connected/untuned, got \(stateA)")
        }
        guard case .connected(tuned: false) = stateB else {
            throw TestError("Client B should be connected/untuned, got \(stateB)")
        }
        
        print("✓ Both clients returned to untuned")
        
        // Cleanup
        await linkA.disconnect()
        await linkB.disconnect()
        
        print("✅ Test 1 passed")
    }
    
    // MARK: - Test 2: Tap to Hang Up
    
    @MainActor
    static func testTapToHangup(serverURL: String, accessCode: String) async throws {
        print("\n👆 Test 2: Tap to hang up")
        print("=========================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .milliseconds(500))
        
        // Establish call
        await linkA.simulatePTTDown()
        await linkB.simulatePTTDown()
        
        // Wait for call establishment
        var callAttempts = 0
        while true {
            if case .inCall = linkA.currentState, case .inCall = linkB.currentState {
                break
            }
            if callAttempts >= 30 {
                throw TestError("Failed to establish call (A: \(linkA.currentState), B: \(linkB.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            callAttempts += 1
        }
        
        print("✓ Call established")
        
        // Client A taps to hang up
        await linkA.simulateTap()
        
        // Wait for hangup
        var hangupAttempts = 0
        while true {
            if case .connected(tuned: false) = linkA.currentState {
                break
            }
            if hangupAttempts >= 10 {
                throw TestError("Client A should have hung up (state: \(linkA.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            hangupAttempts += 1
        }
        
        print("✓ Client A hung up")
        
        // Client B should end call when peer leaves
        try await Task.sleep(for: .milliseconds(500))
        guard case .connected = linkB.currentState else {
            throw TestError("Client B should have ended call")
        }
        
        print("✓ Client B ended call when peer left")
        
        await linkA.disconnect()
        await linkB.disconnect()
        
        print("✅ Test 2 passed")
    }
    
    // MARK: - Test 3: Tap to Cancel Waiting
    
    @MainActor
    static func testTapToCancelWaiting(serverURL: String, accessCode: String) async throws {
        print("\n🚫 Test 3: Tap to cancel waiting")
        print("=================================")
        
        let audioA = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .milliseconds(500))
        
        // Client A presses PTT and starts waiting
        await linkA.simulatePTTDown()
        
        var waitAttempts = 0
        while true {
            if case .waiting = linkA.currentState {
                break
            }
            if waitAttempts >= 10 {
                throw TestError("Client A should be waiting (state: \(linkA.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            waitAttempts += 1
        }
        
        print("✓ Client A is waiting")
        
        // Client A taps to cancel
        await linkA.simulateTap()
        
        var cancelAttempts = 0
        while true {
            if case .connected(tuned: false) = linkA.currentState {
                break
            }
            if cancelAttempts >= 10 {
                throw TestError("Client A should have cancelled (state: \(linkA.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            cancelAttempts += 1
        }
        
        print("✓ Client A cancelled waiting")
        
        await linkA.disconnect()
        
        print("✅ Test 3 passed")
    }
    
    // MARK: - Test 4: Waiting Timeout
    
    @MainActor
    static func testWaitingTimeout(serverURL: String, accessCode: String) async throws {
        print("\n⏰ Test 4: Waiting timeout")
        print("==========================")
        
        let audioA = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        linkA.waitingTimeout = 2.0 // Short timeout for testing
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .milliseconds(500))
        
        // Client A starts waiting
        await linkA.simulatePTTDown()
        
        var waitAttempts = 0
        while true {
            if case .waiting = linkA.currentState {
                break
            }
            if waitAttempts >= 10 {
                throw TestError("Client A should be waiting (state: \(linkA.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            waitAttempts += 1
        }
        
        print("✓ Client A is waiting")
        
        // Wait for timeout (2s + margin)
        print("  Waiting for timeout (2s)...")
        try await Task.sleep(for: .seconds(2.5))
        
        // Should have timed out and returned to untuned
        guard case .connected(tuned: false) = linkA.currentState else {
            throw TestError("Client A should have timed out")
        }
        
        print("✓ Client A timed out correctly")
        
        await linkA.disconnect()
        
        print("✅ Test 4 passed")
    }
    
    // MARK: - Test 5: TURN Credentials
    
    @MainActor
    static func testTURNCredentials(serverURL: String, accessCode: String) async throws {
        print("\n🔐 Test 5: TURN credentials verification")
        print("=========================================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .milliseconds(500))
        
        // Establish call to trigger ICE server fetch
        await linkA.simulatePTTDown()
        await linkB.simulatePTTDown()
        
        // Wait for call establishment
        var callAttempts = 0
        while true {
            if case .inCall = linkA.currentState, case .inCall = linkB.currentState {
                break
            }
            if callAttempts >= 30 {
                throw TestError("Failed to establish call (A: \(linkA.currentState), B: \(linkB.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            callAttempts += 1
        }
        
        print("✓ Call established")
        
        // Verify ICE servers were provided to audio layer
        guard let iceServers = audioB.iceServersUsed, !iceServers.isEmpty else {
            throw TestError("No ICE servers provided to audio layer")
        }
        
        print("✓ ICE servers provided: \(iceServers.count) server(s)")
        
        // Verify TURN server is present
        var hasTurnServer = false
        var hasCredentials = false
        
        for server in iceServers {
            if let urls = server["urls"] as? [String] {
                for url in urls {
                    if url.hasPrefix("turn:") {
                        hasTurnServer = true
                        print("  Found TURN URL: \(url)")
                    }
                }
            }
            
            if server["username"] != nil && server["credential"] != nil {
                hasCredentials = true
                print("  Found credentials: username=\(server["username"] ?? "nil"), credential=[REDACTED]")
            }
        }
        
        guard hasTurnServer else {
            throw TestError("No TURN server found in ICE servers")
        }
        
        print("✓ TURN server verified")
        
        guard hasCredentials else {
            throw TestError("No credentials found for TURN server")
        }
        
        print("✓ TURN credentials verified")
        
        await linkA.disconnect()
        await linkB.disconnect()
        
        print("✅ Test 5 passed")
    }
}

struct TestError: Error, CustomStringConvertible {
    let message: String
    
    init(_ message: String) {
        self.message = message
    }
    
    var description: String {
        message
    }
}

// MARK: - WalkieTalkieLink Test Extensions

extension WalkieTalkieLink {
    func simulatePTTDown() async {
        NotificationCenter.default.post(name: .walkiePTTDown, object: self)
        try? await Task.sleep(for: .milliseconds(50))
    }
    
    func simulatePTTUp() async {
        NotificationCenter.default.post(name: .walkiePTTUp, object: self)
        try? await Task.sleep(for: .milliseconds(50))
    }
    
    func simulateTap() async {
        NotificationCenter.default.post(name: .walkieTap, object: self)
        try? await Task.sleep(for: .milliseconds(50))
    }
}
