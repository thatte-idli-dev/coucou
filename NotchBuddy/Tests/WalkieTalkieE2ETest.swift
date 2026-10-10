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
        
        // Test 6: Release PTT while waiting — mic must stay off after peer joins
        try await testHoldReleaseUntunes(serverURL: serverURL, accessCode: accessCode)
        
        // Test 7: Double-tap while waiting — call starts hands-free
        try await testDoubleTapWhileWaitingStartsHandsFree(serverURL: serverURL, accessCode: accessCode)
        
        // Test 8: Answerer mic matches CallMode after the offer
        try await testAnswererMicMatchesCallMode(serverURL: serverURL, accessCode: accessCode)
        
        // Test 9: Third client retries after 409 until a seat frees
        try await testChannelFullRetry(serverURL: serverURL, accessCode: accessCode)
        
        // Test 10: leave-on-quit frees the seat immediately
        try await testLeaveOnQuitFreesSeat(serverURL: serverURL, accessCode: accessCode)
        
        // Test 11: idle SSE stays up — keepalives must refresh liveness
        try await testIdleConnectionHolds(serverURL: serverURL, accessCode: accessCode)
        
        // Test 12: reconnect cancels the old stream and DELETE so the seat is free
        try await testReconnectFreesOldSeat(serverURL: serverURL, accessCode: accessCode)
        
        // Test 13: both clients tuned reach inCall
        try await testBothTunedReachInCall(serverURL: serverURL, accessCode: accessCode)
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
        
        // Determine which client is seat A (offerer) and which is seat B (answerer)
        let linkAIsSeatA = linkA.isAssignedSeatA
        let linkBIsSeatA = linkB.isAssignedSeatA
        
        print("  linkA is seat \(linkAIsSeatA ? "A" : "B"), linkB is seat \(linkBIsSeatA ? "A" : "B")")
        
        // Ensure they have different seats
        guard linkAIsSeatA != linkBIsSeatA else {
            throw TestError("Both clients assigned same seat (A: \(linkAIsSeatA), B: \(linkBIsSeatA))")
        }
        
        // Assert bidirectional SDP exchange based on actual seat assignments
        let (offererAudio, answererAudio) = linkAIsSeatA ? (audioA, audioB) : (audioB, audioA)
        let (offererName, answererName) = linkAIsSeatA ? ("A", "B") : ("B", "A")
        
        guard answererAudio.remoteOffer != nil else {
            throw TestError("Client \(answererName) (answerer) did not receive offer from client \(offererName)")
        }
        guard offererAudio.remoteAnswer != nil else {
            throw TestError("Client \(offererName) (offerer) did not receive answer from client \(answererName)")
        }
        
        print("✓ Bidirectional SDP exchange verified")
        
        // Wait for ICE candidate exchange (candidates are gathered after offer/answer)
        try await Task.sleep(for: .milliseconds(200))
        
        // Assert ICE candidates exchanged
        guard !offererAudio.receivedIceCandidates.isEmpty else {
            throw TestError("Client \(offererName) (offerer) did not receive ICE candidates (received \(offererAudio.receivedIceCandidates.count))")
        }
        guard !answererAudio.receivedIceCandidates.isEmpty else {
            throw TestError("Client \(answererName) (answerer) did not receive ICE candidates (received \(answererAudio.receivedIceCandidates.count))")
        }
        
        print("✓ ICE candidates exchanged (offerer: \(offererAudio.receivedIceCandidates.count), answerer: \(answererAudio.receivedIceCandidates.count))")
        
        // Client A releases PTT
        await linkA.simulatePTTUp()
        try await Task.sleep(for: .milliseconds(200))
        
        // Assert A is still in call with mic off (release PTT doesn't end call)
        guard case .inCall(mode: .pushToTalk(transmitting: false)) = linkA.currentState else {
            throw TestError("Client A should still be in call with mic off after releasing PTT, got \(linkA.currentState)")
        }
        guard !audioA.micEnabled else {
            throw TestError("Client A's mic should be off after releasing PTT")
        }
        
        print("✓ Client A still in call with mic off after PTT release")
        
        // Client B releases PTT
        await linkB.simulatePTTUp()
        try await Task.sleep(for: .milliseconds(200))
        
        // Assert B is still in call with mic off
        guard case .inCall(mode: .pushToTalk(transmitting: false)) = linkB.currentState else {
            throw TestError("Client B should still be in call with mic off after releasing PTT, got \(linkB.currentState)")
        }
        guard !audioB.micEnabled else {
            throw TestError("Client B's mic should be off after releasing PTT")
        }
        
        print("✓ Both clients still in call with mics off")
        
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
    
    // MARK: - Test 6: Hold then release untunes
    
    @MainActor
    static func testHoldReleaseUntunes(serverURL: String, accessCode: String) async throws {
        print("\n🔇 Test 6: Hold then release untunes and stops the mic")
        print("====================================================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .milliseconds(500))
        
        await linkA.simulateTap()
        try await Task.sleep(for: .milliseconds(50))
        guard case .connected(tuned: false) = linkA.currentState else {
            throw TestError("Idle single tap must not latch waiting, got \(linkA.currentState)")
        }
        
        await linkA.simulatePTTDown()
        try await waitUntilWaiting(linkA, label: "Client A")
        guard audioA.micEnabled else {
            throw TestError("Client A's mic should be on while holding")
        }
        
        await linkA.simulatePTTUp()
        try await Task.sleep(for: .milliseconds(100))
        guard case .connected(tuned: false) = linkA.currentState else {
            throw TestError("Hold release must untune waiting, got \(linkA.currentState)")
        }
        guard !audioA.micEnabled else {
            throw TestError("Client A's mic should be off after releasing hold")
        }
        
        print("✓ Hold release untuned; idle tap did not latch")
        
        await linkA.disconnect()
        await linkB.disconnect()
        print("✅ Test 6 passed")
    }
    
    // MARK: - Test 7: Double-tap while waiting starts hands-free
    
    @MainActor
    static func testDoubleTapWhileWaitingStartsHandsFree(serverURL: String, accessCode: String) async throws {
        print("\n✋ Test 7: Double-tap while waiting — call starts hands-free")
        print("==========================================================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .milliseconds(500))
        
        await linkA.simulatePTTDown()
        try await waitUntilWaiting(linkA, label: "Client A")
        
        await linkA.simulateDoubleTap()
        try await Task.sleep(for: .milliseconds(100))
        guard case .waiting = linkA.currentState else {
            throw TestError("Client A should still be waiting after double-tap, got \(linkA.currentState)")
        }
        guard audioA.micEnabled else {
            throw TestError("Client A's mic should be on after double-tap (hands-free)")
        }
        
        print("✓ Client A double-tapped while waiting; mic on")
        
        await linkB.simulatePTTDown()
        try await waitUntilBothInCall(linkA, linkB)
        
        guard case .inCall(mode: .handsFree) = linkA.currentState else {
            throw TestError("Client A should be inCall handsFree after peer joins, got \(linkA.currentState)")
        }
        guard audioA.micEnabled else {
            throw TestError("Client A's mic should stay on in hands-free")
        }
        
        try assertMicMatchesCallMode(state: linkB.currentState, micEnabled: audioB.micEnabled, label: "Client B")
        
        print("✓ Client A in call hands-free with mic on; Client B mic matches CallMode")
        
        await linkA.simulateTap()
        try await Task.sleep(for: .milliseconds(100))
        guard case .connected(tuned: false) = linkA.currentState else {
            throw TestError("Single tap must leave hands-free, got \(linkA.currentState)")
        }
        
        await linkA.disconnect()
        await linkB.disconnect()
        print("✅ Test 7 passed")
    }
    
    // MARK: - Test 8: Answerer mic matches CallMode after offer
    
    @MainActor
    static func testAnswererMicMatchesCallMode(serverURL: String, accessCode: String) async throws {
        print("\n🎧 Test 8: Answerer mic matches CallMode after the offer")
        print("======================================================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .milliseconds(500))
        
        await linkA.simulatePTTDown()
        try await waitUntilWaiting(linkA, label: "Client A")
        await linkB.simulatePTTDown()
        try await waitUntilBothInCall(linkA, linkB)
        
        let (answererLink, answererAudio, answererName): (WalkieTalkieLink, FakeAudioLayer, String) =
            linkA.isAssignedSeatA ? (linkB, audioB, "B") : (linkA, audioA, "A")
        
        guard answererAudio.remoteOffer != nil else {
            throw TestError("Answerer \(answererName) did not receive an offer")
        }
        
        try assertMicMatchesCallMode(
            state: answererLink.currentState,
            micEnabled: answererAudio.micEnabled,
            label: "Answerer \(answererName)"
        )
        
        print("✓ Answerer \(answererName) mic matches CallMode (\(answererLink.currentState))")
        
        await linkA.disconnect()
        await linkB.disconnect()
        print("✅ Test 8 passed")
    }

    @MainActor
    static func testChannelFullRetry(serverURL: String, accessCode: String) async throws {
        print("\n📞 Test 9: Third client retries after 409 until a seat frees")
        print("==========================================================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        let audioC = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        let linkC = WalkieTalkieLink(audioLayer: audioC)
        linkC.channelFullRetrySteps = [0.05]
        linkC.channelFullRetryCap = 0.05
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await waitUntil("A and B hold seats") {
            linkA.hasSession && linkB.hasSession
        }
        
        await linkC.configure(serverURL: serverURL, accessCode: accessCode)
        try await waitUntil("C sees channel full") {
            linkC.isChannelFull && !linkC.hasSession
        }
        
        await linkA.disconnect()
        try await waitUntil("C joined after A left") {
            !linkC.isChannelFull && linkC.hasSession
        }
        
        await linkB.disconnect()
        await linkC.disconnect()
        print("✅ Test 9 passed")
    }

    @MainActor
    static func testLeaveOnQuitFreesSeat(serverURL: String, accessCode: String) async throws {
        print("\n📞 Test 10: leave-on-quit frees the seat immediately")
        print("===================================================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        let audioC = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        let linkC = WalkieTalkieLink(audioLayer: audioC)
        linkC.channelFullRetrySteps = [0.05]
        linkC.channelFullRetryCap = 0.05
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await waitUntil("A and B hold seats") {
            linkA.hasSession && linkB.hasSession
        }
        
        linkA.shutdown()
        guard !linkA.hasSession else {
            throw TestError("A should drop its session on quit")
        }
        await linkC.configure(serverURL: serverURL, accessCode: accessCode)
        try await waitUntil("C connected after A quit") {
            !linkC.isChannelFull && linkC.hasSession
        }
        
        await linkB.disconnect()
        await linkC.disconnect()
        print("✅ Test 10 passed")
    }

    @MainActor
    static func testIdleConnectionHolds(serverURL: String, accessCode: String) async throws {
        print("\n📞 Test 11: Idle connection holds 60s with no reconnect or 409")
        print("============================================================")
        
        let audioA = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        try await waitUntil("A seated") { linkA.hasSession }
        
        let reconnects = linkA.reconnectCount
        let fulls = linkA.channelFullCount
        print("⏳ Holding idle for 60s (reconnects=\(reconnects) fulls=\(fulls))...")
        try await Task.sleep(for: .seconds(60))
        
        guard linkA.hasSession else {
            throw TestError("A lost its session during the 60s idle hold")
        }
        guard linkA.reconnectCount == reconnects else {
            throw TestError("A reconnected during idle (\(linkA.reconnectCount - reconnects) times)")
        }
        guard linkA.channelFullCount == fulls else {
            throw TestError("A saw channel_full during idle")
        }
        guard linkA.currentState != .disconnected else {
            throw TestError("A disconnected during idle")
        }
        
        await linkA.disconnect()
        print("✅ Test 11 passed")
    }

    @MainActor
    static func testReconnectFreesOldSeat(serverURL: String, accessCode: String) async throws {
        print("\n📞 Test 12: Reconnect frees the old seat")
        print("========================================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await waitUntil("A and B hold seats") {
            linkA.hasSession && linkB.hasSession
        }
        
        let fullsBefore = linkA.channelFullCount
        await linkA.forceReconnectForTest()
        try await waitUntil("A reseated after reconnect", timeoutMS: 6000) {
            linkA.hasSession && !linkA.isChannelFull
        }
        
        guard linkB.hasSession else {
            throw TestError("B lost its seat while A reconnected")
        }
        guard linkA.channelFullCount == fullsBefore else {
            throw TestError("A hit 409 on reconnect — old seat was not freed")
        }
        
        await linkA.disconnect()
        await linkB.disconnect()
        print("✅ Test 12 passed")
    }

    @MainActor
    static func testBothTunedReachInCall(serverURL: String, accessCode: String) async throws {
        print("\n📞 Test 13: Both clients tuned reach inCall")
        print("==========================================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        let linkA = WalkieTalkieLink(audioLayer: audioA)
        let linkB = WalkieTalkieLink(audioLayer: audioB)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        try await waitUntil("A and B hold seats") {
            linkA.hasSession && linkB.hasSession
        }
        
        await linkA.simulatePTTDown()
        try await waitUntilWaiting(linkA, label: "Client A")
        await linkB.simulatePTTDown()
        try await waitUntilBothInCall(linkA, linkB)
        
        await linkA.disconnect()
        await linkB.disconnect()
        print("✅ Test 13 passed")
    }
    
    @MainActor
    static func waitUntil(_ label: String, timeoutMS: Int = 4000, _ pred: () -> Bool) async throws {
        var elapsed = 0
        while elapsed < timeoutMS {
            if pred() { return }
            try await Task.sleep(for: .milliseconds(50))
            elapsed += 50
        }
        throw TestError(label)
    }
    
    @MainActor
    static func waitUntilWaiting(_ link: WalkieTalkieLink, label: String) async throws {
        var attempts = 0
        while true {
            if case .waiting = link.currentState { return }
            if attempts >= 20 {
                throw TestError("\(label) should be waiting (state: \(link.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
    }
    
    @MainActor
    static func waitUntilBothInCall(_ linkA: WalkieTalkieLink, _ linkB: WalkieTalkieLink) async throws {
        var attempts = 0
        while true {
            if case .inCall = linkA.currentState, case .inCall = linkB.currentState { return }
            if attempts >= 30 {
                throw TestError("Both should be in call (A: \(linkA.currentState), B: \(linkB.currentState))")
            }
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
    }
    
    static func assertMicMatchesCallMode(state: WalkieState, micEnabled: Bool, label: String) throws {
        switch state {
        case .inCall(.handsFree):
            guard micEnabled else {
                throw TestError("\(label) is hands-free but mic is off")
            }
        case .inCall(.pushToTalk(let transmitting)):
            guard micEnabled == transmitting else {
                throw TestError("\(label) CallMode transmitting=\(transmitting) but micEnabled=\(micEnabled)")
            }
        default:
            throw TestError("\(label) should be in call to match mic, got \(state)")
        }
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
    
    func simulateDoubleTap() async {
        NotificationCenter.default.post(name: .walkieDoubleTap, object: self)
        try? await Task.sleep(for: .milliseconds(50))
    }
}
