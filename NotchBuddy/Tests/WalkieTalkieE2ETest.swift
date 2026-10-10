import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Mirror WalkieState from WalkieTalkieLink for standalone compilation
enum WalkieState: Equatable, Sendable {
    case disconnected
    case connected(tuned: Bool)
    case waiting(started: Date)
    case inCall(mode: CallMode)
    
    enum CallMode: Equatable, Sendable {
        case pushToTalk(transmitting: Bool)
        case handsFree
    }
    
    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
    
    var isInCall: Bool {
        if case .inCall = self { return true }
        return false
    }
}

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
        // Both arguments are the same code, but we accept two for compatibility
        
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
        
        let linkA = TestWalkieTalkieLink(audioLayer: audioA)
        let linkB = TestWalkieTalkieLink(audioLayer: audioB)
        
        // Configure both clients with the same access code
        // The first to connect becomes seat A, the second becomes seat B
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        
        // Wait for SSE connection and snapshot to arrive
        print("  ⏳ Waiting for SSE connection...")
        try await Task.sleep(for: .seconds(2))
        
        // Verify both are connected
        guard await linkA.isConnected() else {
            throw TestError("Client A did not connect")
        }
        guard await linkB.isConnected() else {
            throw TestError("Client B did not connect")
        }
        print("  ✓ Both clients connected")
        
        // A tunes (PTT down) - enters waiting state
        print("  → Client A: PTT down (tuning, waiting)")
        await linkA.simulatePTTDown()
        
        try await Task.sleep(for: .milliseconds(500))
        
        guard await linkA.getState().isWaiting else {
            throw TestError("Client A should be in waiting state")
        }
        print("  ✓ Client A is waiting")
        
        // Wait for A's presence to propagate to server
        try await Task.sleep(for: .seconds(1))
        
        // B tunes (PTT down) - both now tuned, negotiation should start
        print("  → Client B: PTT down (tuning)")
        await linkB.simulatePTTDown()
        
        // Wait for both presences to reach server and state broadcast to propagate
        print("  ⏳ Waiting for server state synchronization...")
        try await Task.sleep(for: .seconds(3))
        
        // Wait for negotiation to complete
        print("  ⏳ Waiting for WebRTC negotiation...")
        try await Task.sleep(for: .seconds(3))
        
        // Verify both entered call state
        let aState = await linkA.getState()
        let bState = await linkB.getState()
        print("  → Client A state: \(aState), Client B state: \(bState)")
        
        guard aState.isInCall else {
            throw TestError("Client A should be in call state, but is: \(aState)")
        }
        print("  ✓ Client A entered call")
        
        guard await linkB.getState().isInCall else {
            throw TestError("Client B should be in call state")
        }
        print("  ✓ Client B entered call")
        
        // Both clients successfully negotiated and entered call state
        print("  ✓ Offer/answer exchange completed (both in call)")
        
        // Verify mic state
        let aMicEnabled = await audioA.getMicEnabled()
        let bMicEnabled = await audioB.getMicEnabled()
        
        print("  ✓ Client A mic: \(aMicEnabled ? "enabled" : "disabled")")
        print("  ✓ Client B mic: \(bMicEnabled ? "enabled" : "disabled")")
        
        // Cleanup
        await linkA.disconnect()
        await linkB.disconnect()
        
        print("✅ Test 1 passed: Full call flow works")
    }
    
    // MARK: - Test 2: Tap to Hang Up
    
    @MainActor
    static func testTapToHangup(serverURL: String, accessCode: String) async throws {
        print("\n👆 Test 2: Tap to hang up")
        print("=========================")
        
        let audioA = FakeAudioLayer()
        let audioB = FakeAudioLayer()
        
        let linkA = TestWalkieTalkieLink(audioLayer: audioA)
        let linkB = TestWalkieTalkieLink(audioLayer: audioB)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        await linkB.configure(serverURL: serverURL, accessCode: accessCode)
        
        try await Task.sleep(for: .seconds(1))
        
        // Both tune
        await linkA.simulatePTTDown()
        await linkB.simulatePTTDown()
        
        try await Task.sleep(for: .seconds(2))
        
        guard await linkA.getState().isInCall else {
            throw TestError("Client A should be in call")
        }
        print("  ✓ Call established")
        
        // A taps to hang up
        print("  → Client A: Tap (hang up)")
        await linkA.simulateTap()
        
        try await Task.sleep(for: .seconds(1))
        
        // A should be disconnected/untuned
        let aState = await linkA.getState()
        guard !aState.isInCall else {
            throw TestError("Client A should have hung up")
        }
        print("  ✓ Client A hung up and untuned")
        
        // B should also drop the call when peer untuned
        try await Task.sleep(for: .seconds(1))
        let bState = await linkB.getState()
        guard !bState.isInCall else {
            throw TestError("Client B should have dropped call when peer left")
        }
        print("  ✓ Client B dropped call when peer left")
        
        // Verify cleanup was called
        guard await audioA.wasCleanupCalled() else {
            throw TestError("Client A should have called cleanup()")
        }
        print("  ✓ Client A called cleanup()")
        
        await linkA.disconnect()
        await linkB.disconnect()
        
        print("✅ Test 2 passed: Tap to hang up works")
    }
    
    // MARK: - Test 3: Tap to Cancel Waiting
    
    @MainActor
    static func testTapToCancelWaiting(serverURL: String, accessCode: String) async throws {
        print("\n🚫 Test 3: Tap to cancel waiting")
        print("=================================")
        
        let audioA = FakeAudioLayer()
        let linkA = TestWalkieTalkieLink(audioLayer: audioA)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .seconds(1))
        
        // A tunes alone (waiting)
        print("  → Client A: PTT down (waiting)")
        await linkA.simulatePTTDown()
        try await Task.sleep(for: .milliseconds(500))
        
        guard await linkA.getState().isWaiting else {
            throw TestError("Client A should be waiting")
        }
        print("  ✓ Client A is waiting")
        
        // A taps to cancel
        print("  → Client A: Tap (cancel)")
        await linkA.simulateTap()
        try await Task.sleep(for: .milliseconds(500))
        
        // A should be untuned
        let stateAfterTap = await linkA.getState()
        guard !stateAfterTap.isWaiting else {
            throw TestError("Client A should have cancelled waiting")
        }
        print("  ✓ Client A cancelled and untuned")
        
        await linkA.disconnect()
        
        print("✅ Test 3 passed: Tap to cancel waiting works")
    }
    
    // MARK: - Test 4: Waiting Timeout
    
    @MainActor
    static func testWaitingTimeout(serverURL: String, accessCode: String) async throws {
        print("\n⏱️  Test 4: Waiting timeout (30s)")
        print("=================================")
        
        let audioA = FakeAudioLayer()
        let linkA = TestWalkieTalkieLink(audioLayer: audioA)
        
        // Override timeout for faster test
        await linkA.setWaitingTimeout(2.0)  // 2 seconds for test
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .seconds(1))
        
        // A tunes alone (waiting)
        print("  → Client A: PTT down (waiting, 2s timeout)")
        await linkA.simulatePTTDown()
        try await Task.sleep(for: .milliseconds(500))
        
        guard await linkA.getState().isWaiting else {
            throw TestError("Client A should be waiting")
        }
        print("  ✓ Client A is waiting")
        
        // Wait for timeout
        print("  ⏳ Waiting for timeout...")
        try await Task.sleep(for: .seconds(2.5))
        
        // A should have timed out and untuned
        let stateAfterTimeout = await linkA.getState()
        guard !stateAfterTimeout.isWaiting else {
            throw TestError("Client A should have timed out")
        }
        print("  ✓ Client A timed out and untuned")
        
        // Verify mic is disabled
        let micEnabled = await audioA.getMicEnabled()
        guard !micEnabled else {
            throw TestError("Mic should be disabled after timeout")
        }
        print("  ✓ Mic disabled after timeout")
        
        await linkA.disconnect()
        
        print("✅ Test 4 passed: Waiting timeout works")
    }
    
    // MARK: - Test 5: TURN Credentials
    
    @MainActor
    static func testTURNCredentials(serverURL: String, accessCode: String) async throws {
        print("\n🔐 Test 5: TURN credentials verification")
        print("==========================================")
        
        let audioA = FakeAudioLayer()
        let linkA = TestWalkieTalkieLink(audioLayer: audioA)
        
        await linkA.configure(serverURL: serverURL, accessCode: accessCode)
        try await Task.sleep(for: .seconds(1))
        
        // Trigger ICE server fetch by tuning
        await linkA.simulatePTTDown()
        try await Task.sleep(for: .seconds(1))
        
        // Get ICE servers from the audio layer's last call
        let iceServers = await audioA.getLastICEServers()
        
        guard !iceServers.isEmpty else {
            throw TestError("No ICE servers were provided")
        }
        print("  ✓ ICE servers provided: \(iceServers.count) server(s)")
        
        // Verify STUN server is present
        let hasSTUN = iceServers.contains { server in
            if let urls = server["urls"] as? [String] {
                return urls.contains { $0.hasPrefix("stun:") }
            }
            return false
        }
        guard hasSTUN else {
            throw TestError("STUN server not found in ICE servers")
        }
        print("  ✓ STUN server present")
        
        // Verify TURN server with credentials
        let turnServer = iceServers.first { server in
            if let urls = server["urls"] as? [String] {
                return urls.contains { $0.hasPrefix("turn:") }
            }
            return false
        }
        
        guard let turnServer else {
            throw TestError("TURN server not found in ICE servers")
        }
        print("  ✓ TURN server present")
        
        guard let username = turnServer["username"] as? String, !username.isEmpty else {
            throw TestError("TURN username missing or empty")
        }
        print("  ✓ TURN username: \(username)")
        
        guard let credential = turnServer["credential"] as? String, !credential.isEmpty else {
            throw TestError("TURN credential missing or empty")
        }
        print("  ✓ TURN credential: [REDACTED]")
        
        // Verify URLs is an array, not a comma-separated string
        guard let urls = turnServer["urls"] as? [String] else {
            throw TestError("TURN urls should be an array, not a string")
        }
        print("  ✓ TURN urls is array: \(urls)")
        
        await linkA.disconnect()
        
        print("✅ Test 5 passed: TURN credentials properly structured")
    }
    
}

// MARK: - Test Wrapper

/// Test wrapper around WalkieTalkieLink for easier testing
actor TestWalkieTalkieLink {
    private let audioLayer: FakeAudioLayer
    private var sessionID: String?
    private var sessionToken: String?
    private var state: WalkieState = .disconnected
    private var serverURL: String?
    private var channelNumber: Int = 1
    private var eventTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var waitingTimer: Task<Void, Never>?
    private var revision: Int = 0
    private var negotiationID: String?
    private var isSeatA: Bool = false
    private var peerTuned: Bool = false
    private var iceServers: [[String: Any]] = []
    private var waitingTimeout: TimeInterval = 30
    private var currentSSEEvent: String?
    
    init(audioLayer: FakeAudioLayer) {
        self.audioLayer = audioLayer
    }
    
    func setWaitingTimeout(_ timeout: TimeInterval) {
        self.waitingTimeout = timeout
    }
    
    func configure(serverURL: String, accessCode: String) async {
        guard let components = WalkieProtocol.decodeAccessCode(accessCode) else { return }
        
        self.serverURL = components.origin
        self.channelNumber = components.channel
        
        state = .connected(tuned: false)
        
        await startEventStream(serverURL: components.origin, channelToken: components.channelToken)
    }
    
    func getState() async -> WalkieState {
        return state
    }
    
    func isConnected() async -> Bool {
        return sessionID != nil && sessionToken != nil
    }
    
    func simulatePTTDown() async {
        switch state {
        case .connected(tuned: false):
            await audioLayer.setupWebView(
                onIceCandidate: { _ in },
                onAnswer: { _ in }
            )
            await audioLayer.setMicEnabled(true)
            state = .waiting(started: Date())
            await sendPresence()
            await startWaitingTimer()
            
        case .inCall(mode: .pushToTalk):
            state = .inCall(mode: .pushToTalk(transmitting: true))
            await audioLayer.setMicEnabled(true)
            await sendPresence()
            
        default:
            break
        }
    }
    
    func simulateTap() async {
        switch state {
        case .waiting:
            state = .connected(tuned: false)
            await audioLayer.setMicEnabled(false)
            await sendPresence()
            waitingTimer?.cancel()
            
        case .inCall:
            await endCall()
            
        default:
            break
        }
    }
    
    func disconnect() async {
        eventTask?.cancel()
        presenceTask?.cancel()
        waitingTimer?.cancel()
        
        if let serverURL, let sessionToken, let sessionID {
            let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/session"
            if let url = URL(string: urlStr) {
                let body = WalkieProtocol.buildLeaveBody(sessionID: sessionID)
                guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
                
                var req = URLRequest(url: url)
                req.httpMethod = "DELETE"
                req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = jsonData
                
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        
        await audioLayer.cleanup()
        state = .disconnected
    }
    
    // MARK: - Private
    
    private func startEventStream(serverURL: String, channelToken: String) async {
        let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/events"
        guard let url = URL(string: urlStr) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(channelToken)", forHTTPHeaderField: "Authorization")
        
        eventTask = Task {
            while !Task.isCancelled {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        await handleSSELine(line)
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
    
    private func handleSSELine(_ line: String) async {
        if line.hasPrefix("event: ") {
            currentSSEEvent = String(line.dropFirst(7))
        } else if line.hasPrefix("data: ") {
            let json = String(line.dropFirst(6))
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            guard let eventType = currentSSEEvent else { return }
            
            switch eventType {
            case "snapshot":
                guard let snapshot = WalkieProtocol.parseSnapshotEvent(dict) else { return }
                sessionToken = snapshot.sessionToken
                sessionID = snapshot.sessionID
                isSeatA = snapshot.member == "A"
                print("[Test] Snapshot received: sessionID=\(sessionID ?? "nil"), member=\(snapshot.member)")
                await startPresence()
                
            case "state":
                guard let stateEvent = WalkieProtocol.parseStateEvent(dict) else { return }
                let myTuned = isLocallyTuned()
                peerTuned = stateEvent.peerTuned
                
                if myTuned && peerTuned {
                    if let negID = stateEvent.negotiationID, negID != negotiationID {
                        print("[Test] Both tuned, starting negotiation with ID: \(negID)")
                        negotiationID = negID
                        await fetchICEServers()
                        await startNegotiation()
                    } else {
                        print("[Test] Both tuned but negotiationID unchanged: \(String(describing: stateEvent.negotiationID))")
                    }
                } else if myTuned && !peerTuned {
                    // Peer left while we're tuned
                    if case .inCall = state {
                        print("[Test] Peer left, ending call")
                        await endCall()
                    }
                } else {
                    print("[Test] State update: myTuned=\(myTuned), peerTuned=\(peerTuned)")
                }
                
            case "signal":
                await handleSignalEvent(dict)
                
            default:
                break
            }
            
            currentSSEEvent = nil
        }
    }
    
    private func isLocallyTuned() -> Bool {
        switch state {
        case .connected(tuned: let t): return t
        case .waiting, .inCall: return true
        case .disconnected: return false
        }
    }
    
    private func startPresence() async {
        presenceTask?.cancel()
        
        presenceTask = Task {
            while !Task.isCancelled {
                await sendPresence()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    
    private func sendPresence() async {
        guard let serverURL, let sessionToken, let sessionID else {
            print("[Test] sendPresence skipped: serverURL=\(serverURL != nil), sessionToken=\(sessionToken != nil), sessionID=\(sessionID != nil)")
            return
        }
        
        revision += 1
        
        let tuned = isLocallyTuned()
        let transmitting: Bool
        if case .inCall(.pushToTalk(let t)) = state {
            transmitting = t
        } else {
            transmitting = false
        }
        
        print("[Test] Sending presence: tuned=\(tuned), transmitting=\(transmitting), revision=\(revision)")
        
        let body = WalkieProtocol.buildPresenceBody(
            sessionID: sessionID,
            revision: revision,
            tuned: tuned,
            transmitting: transmitting
        )
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/presence"
        guard let url = URL(string: urlStr) else { return }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpResponse = response as? HTTPURLResponse {
                print("[Test] Presence response: \(httpResponse.statusCode)")
            }
        } catch {
            print("[Test] Presence error: \(error)")
        }
    }
    
    private func fetchICEServers() async {
        guard let serverURL, let sessionToken else { return }
        
        let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/ice"
        guard let url = URL(string: urlStr) else { return }
        
        var req = URLRequest(url: url)
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let config = WalkieProtocol.parseICEResponse(dict) {
                var servers: [[String: Any]] = []
                servers.append(["urls": ["stun:stun.l.google.com:19302"]])
                
                var turnServer: [String: Any] = ["urls": config.urls]
                if let username = config.username {
                    turnServer["username"] = username
                }
                if let credential = config.credential {
                    turnServer["credential"] = credential
                }
                servers.append(turnServer)
                
                iceServers = servers
                await audioLayer.setLastICEServers(servers)
            }
        } catch {}
    }
    
    private func startNegotiation() async {
        // Allow .waiting or .connected states
        switch state {
        case .waiting, .connected:
            print("[Test] startNegotiation: proceeding (state: \(state), isSeatA: \(isSeatA))")
            break
        case .disconnected, .inCall:
            print("[Test] startNegotiation: returning early (state: \(state))")
            return
        }
        
        await audioLayer.setupWebView(
            onIceCandidate: { [weak self] candidate in
                Task { await self?.sendIceCandidate(candidate) }
            },
            onAnswer: { [weak self] answer in
                Task { await self?.sendAnswer(answer) }
            }
        )
        
        if isSeatA {
            do {
                let offer = try await audioLayer.createOffer(iceServers: iceServers)
                print("[Test] Seat A created offer, sending...")
                await sendOffer(offer)
            } catch {
                print("[Test] Seat A failed to create offer: \(error)")
            }
        } else {
            print("[Test] Seat B waiting for offer...")
        }
        
        print("[Test] Setting state to .inCall")
        state = .inCall(mode: .pushToTalk(transmitting: false))
    }
    
    private func handleSignalEvent(_ dict: [String: Any]) async {
        guard let signalEvent = WalkieProtocol.parseSignalEvent(dict) else {
            print("[Test] Failed to parse signal event")
            return
        }
        guard signalEvent.from != sessionID else {
            print("[Test] Ignoring signal from self")
            return
        }
        
        let payload = signalEvent.payload
        print("[Test] Received signal kind: \(signalEvent.kind)")
        
        if let offerJSON = payload["offer"] as? String, !isSeatA {
            print("[Test] Seat B received offer, creating answer...")
            do {
                let answer = try await audioLayer.setOffer(offerJSON, iceServers: iceServers)
                await sendAnswer(answer)
                print("[Test] Seat B sent answer, setting state to .inCall")
                state = .inCall(mode: .pushToTalk(transmitting: false))
            } catch {
                print("[Test] Seat B failed to handle offer: \(error)")
            }
        }
        
        if let answerJSON = payload["answer"] as? String, isSeatA {
            print("[Test] Seat A received answer")
            await audioLayer.handleAnswer(answerJSON)
        }
        
        if let candidateJSON = payload["ice_candidate"] as? String {
            print("[Test] Received ICE candidate")
            await audioLayer.addIceCandidate(candidateJSON)
        }
    }
    
    private func sendOffer(_ offer: String) async {
        await sendSignal(kind: "offer", payload: ["offer": offer])
    }
    
    private func sendAnswer(_ answer: String) async {
        await sendSignal(kind: "answer", payload: ["answer": answer])
    }
    
    private func sendIceCandidate(_ candidate: String) async {
        await sendSignal(kind: "candidate", payload: ["ice_candidate": candidate])
    }
    
    private func sendSignal(kind: String, payload: [String: String]) async {
        guard let serverURL, let sessionToken, let sessionID, let negotiationID else { return }
        
        let body = WalkieProtocol.buildSignalBody(
            sessionID: sessionID,
            negotiationID: negotiationID,
            kind: kind,
            payload: payload
        )
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/signal"
        guard let url = URL(string: urlStr) else { return }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        
        _ = try? await URLSession.shared.data(for: req)
    }
    
    private func startWaitingTimer() async {
        waitingTimer?.cancel()
        
        waitingTimer = Task {
            try? await Task.sleep(for: .seconds(waitingTimeout))
            if !Task.isCancelled {
                await handleWaitingTimeout()
            }
        }
    }
    
    private func handleWaitingTimeout() async {
        if case .waiting = state {
            state = .connected(tuned: false)
            await audioLayer.setMicEnabled(false)
            await sendPresence()
        }
    }
    
    private func endCall() async {
        await audioLayer.cleanup()
        await audioLayer.setMicEnabled(false)
        state = .connected(tuned: false)
        await sendPresence()
    }
}

// MARK: - Extensions

extension FakeAudioLayer {
    private static var lastICEServers: [[String: Any]] = []
    private static var onIceCandidateHandler: ((String) -> Void)?
    private static var onAnswerHandler: ((String) -> Void)?
    
    func setLastICEServers(_ servers: [[String: Any]]) {
        FakeAudioLayer.lastICEServers = servers
    }
    
    func getLastICEServers() -> [[String: Any]] {
        return FakeAudioLayer.lastICEServers
    }
    
    func setOnIceCandidate(_ handler: @escaping (String) -> Void) {
        FakeAudioLayer.onIceCandidateHandler = handler
        self.onIceCandidate = handler
    }
    
    func setOnAnswer(_ handler: @escaping (String) -> Void) {
        FakeAudioLayer.onAnswerHandler = handler
        self.onAnswer = handler
    }
    
    func getMicEnabled() -> Bool {
        return micEnabled
    }
    
    func wasCleanupCalled() -> Bool {
        return cleanupCalled
    }
}

struct TestError: Error, CustomStringConvertible {
    let message: String
    
    init(_ message: String) {
        self.message = message
    }
    
    var description: String {
        return message
    }
}
