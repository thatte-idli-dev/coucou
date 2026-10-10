import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "Walkie")

extension String {
    func appendToFile(at path: String) throws {
        if let data = self.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                try fileHandle.close()
            } else {
                try data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

enum WalkieState: Equatable, Sendable {
    case disconnected
    case connected(tuned: Bool)
    case waiting(started: Date)
    case inCall(mode: CallMode)
    
    enum CallMode: Equatable, Sendable {
        case pushToTalk(transmitting: Bool)
        case handsFree
    }
}

final class WalkieTalkieLink: @unchecked Sendable {
    @MainActor
    static let shared = WalkieTalkieLink(audioLayer: WalkieTalkieAudio.shared)
    
    private var state: WalkieState = .disconnected {
        didSet {
            if self.state != oldValue {
                logger.info("State: \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)")
            }
        }
    }
    private var sessionID: String?
    private var sessionToken: String?
    private var revision: Int = 0
    private var negotiationID: String?
    private var isSeatA: Bool = false {
        didSet {
            if isSeatA != oldValue {
                logger.info("Seat assignment: \(isSeatA ? "A" : "B", privacy: .public) (session: \(sessionID ?? "unknown", privacy: .public))")
            }
        }
    }
    private var peerTuned: Bool = false
    private var lastStateEventPeerTuned: Bool = false
    private var channelNumber: Int = 1
    
    private var eventTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var waitingTimer: Task<Void, Never>?
    private var iceRefreshTimer: Task<Void, Never>?
    private var streamHealthTimer: Task<Void, Never>?
    
    private var iceServers: [[String: Any]] = []
    private var serverURL: String?
    private var channelToken: String?
    private var channelFull: Bool = false
    private var lastEventTime: Date = Date()
    private var reconnectAttempts: Int = 0
    
    private var waitingAnimationToken: NSObject?
    private var currentSSEEvent: String?
    private var hasPlayedGreet: Bool = false
    
    private var audioLayer: WalkieAudioLayer
    
    var waitingTimeout: TimeInterval = 30  // Injectable for tests
    
    @MainActor
    init(audioLayer: WalkieAudioLayer) {
        self.audioLayer = audioLayer
        
        NotificationCenter.default.addObserver(
            forName: .walkiePTTDown,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            // Only respond if notification is broadcast (nil) or targeted to this instance
            if notification.object == nil || (notification.object as? WalkieTalkieLink) === self {
                Task { await self.handlePTTDown() }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .walkiePTTUp,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if notification.object == nil || (notification.object as? WalkieTalkieLink) === self {
                Task { await self.handlePTTUp() }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .walkieDoubleTap,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if notification.object == nil || (notification.object as? WalkieTalkieLink) === self {
                Task { await self.handleDoubleTap() }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .walkieTap,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if notification.object == nil || (notification.object as? WalkieTalkieLink) === self {
                Task { await self.handleTap() }
            }
        }
    }
    
    var currentState: WalkieState {
        state
    }
    
    var isAssignedSeatA: Bool {
        isSeatA
    }
    
    func configure(serverURL: String?, accessCode: String?) async {
        guard let code = accessCode, !code.isEmpty else {
            self.serverURL = nil
            self.channelToken = nil
            await disconnect()
            return
        }
        
        guard let components = WalkieProtocol.decodeAccessCode(code) else {
            await disconnect()
            return
        }
        
        self.serverURL = components.origin
        self.channelToken = components.channelToken
        self.channelNumber = components.channel
        
        await connectIfNeeded()
    }
    
    private func connectIfNeeded() async {
        guard case .disconnected = state else { return }
        guard let serverURL, let channelToken, !serverURL.isEmpty, !channelToken.isEmpty else { return }
        
        channelFull = false
        state = .connected(tuned: false)
        reconnectAttempts = 0
        
        await startEventStream()
        await startStreamHealthMonitor()
    }
    
    private func startEventStream() async {
        eventTask?.cancel()
        
        guard let serverURL, let channelToken else { return }
        
        let baseURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = "\(baseURL)/v3/channels/\(channelNumber)/events"
        guard let url = URL(string: urlStr) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(channelToken)", forHTTPHeaderField: "Authorization")
        
        logger.info("SSE: Connecting to \(urlStr, privacy: .public)")
        
        eventTask = Task {
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    if let httpResp = response as? HTTPURLResponse {
                        if httpResp.statusCode == 409 {
                            logger.error("SSE: Channel full (409)")
                            channelFull = true
                            await disconnect()
                            return
                        }
                        
                        if httpResp.statusCode == 401 {
                            logger.error("SSE: Authentication failed (401)")
                            await disconnect()
                            return
                        }
                        
                        guard httpResp.statusCode == 200 else {
                            logger.warning("SSE: HTTP \(httpResp.statusCode, privacy: .public), will retry")
                            try? await Task.sleep(for: .seconds(reconnectBackoff()))
                            continue
                        }
                        
                        logger.info("SSE: Connected (200)")
                    }
                    
                    reconnectAttempts = 0
                    lastEventTime = Date()
                    
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        lastEventTime = Date()
                        await handleSSELine(line)
                    }
                    
                    // Stream ended, reset and reconnect
                    if !Task.isCancelled {
                        logger.warning("SSE stream ended, reconnecting...")
                        await reconnect()
                        try? await Task.sleep(for: .seconds(reconnectBackoff()))
                    }
                } catch {
                    if Task.isCancelled { break }
                    logger.error("SSE error: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .seconds(reconnectBackoff()))
                }
            }
        }
    }
    
    private func reconnectBackoff() -> Int {
        reconnectAttempts += 1
        let backoffs = [1, 2, 4, 8, 30]
        return backoffs[min(reconnectAttempts - 1, backoffs.count - 1)]
    }
    
    private func startStreamHealthMonitor() async {
        streamHealthTimer?.cancel()
        
        streamHealthTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(35))
                if Date().timeIntervalSince(lastEventTime) > 35 {
                    logger.warning("Stream dead for 35s, reconnecting...")
                    await reconnect()
                }
            }
        }
    }
    
    private func reconnect() async {
        logger.info("Reconnecting...")
        
        // Reset state per protocol rules
        let wasConnected = state != .disconnected
        sessionID = nil
        sessionToken = nil
        revision = 0
        negotiationID = nil
        peerTuned = false
        hasPlayedGreet = false
        
        await audioLayer.cleanup()
        
        if wasConnected {
            state = .disconnected
            state = .connected(tuned: false)
            await startEventStream()
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
                revision = 0
                await startPresence()
                
            case "state":
                guard let stateEvent = WalkieProtocol.parseStateEvent(dict) else { return }
                // Use server's view of both local and peer tuned state (not local state)
                // This prevents entering call before server confirms both are tuned
                let myTuned = stateEvent.localTuned
                let wasPeerTuned = peerTuned
                peerTuned = stateEvent.peerTuned
                lastStateEventPeerTuned = stateEvent.peerTuned
                
                // Debug trace for CI
                let trace = "[\(Date().timeIntervalSince1970)] state event: local.tuned=\(stateEvent.localTuned) peer.tuned=\(stateEvent.peerTuned) negID=\(stateEvent.negotiationID ?? "nil") currentState=\(state)\n"
                try? trace.appendToFile(at: "/tmp/walkie-trace-\(sessionID ?? "unknown").log")
                
                if myTuned && peerTuned {
                    // Both tuned - start or continue call
                    if case .waiting = state {
                        waitingTimer?.cancel()
                        waitingTimer = nil
                    }
                    
                    if let negID = stateEvent.negotiationID, negID != negotiationID {
                        negotiationID = negID
                        let traceNeg = "[\(Date().timeIntervalSince1970)] calling startNegotiation: negotiationID=\(negID) isSeatA=\(isSeatA) currentState=\(state)\n"
                        try? traceNeg.appendToFile(at: "/tmp/walkie-trace-\(sessionID ?? "unknown").log")
                        await fetchICEServers()
                        await startNegotiation()
                    }
                    
                    // Play greet only on actual peer tune transition
                    if !wasPeerTuned {
                        await playGreetOnce()
                    }
                } else if myTuned && !peerTuned {
                    // Peer left
                    if case .inCall = state {
                        await endCall()
                    }
                } else if !myTuned && peerTuned {
                    // Peer is waiting
                    if case .connected = state {
                        await startWaitingAnimation()
                    }
                } else {
                    // Both untuned - stop wiggle and reset greet
                    await stopWaitingAnimation()
                    hasPlayedGreet = false
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
        guard let serverURL, let sessionToken, let sessionID else { return }
        
        revision += 1
        
        let tuned = isLocallyTuned()
        let transmitting: Bool
        if case .inCall(.pushToTalk(let t)) = state {
            transmitting = t
        } else {
            transmitting = false
        }
        
        let body = WalkieProtocol.buildPresenceBody(
            sessionID: sessionID,
            revision: revision,
            tuned: tuned,
            transmitting: transmitting,
            restartNegotiation: false
        )
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/presence"
        guard let url = URL(string: urlStr) else { return }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        
        logger.info("Presence: rev=\(self.revision, privacy: .public) tuned=\(tuned, privacy: .public) transmitting=\(transmitting, privacy: .public)")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    logger.debug("Presence: HTTP 200")
                } else if httpResp.statusCode == 401 || httpResp.statusCode == 409 {
                    logger.error("Presence: HTTP \(httpResp.statusCode, privacy: .public), reconnecting...")
                    await reconnect()
                } else {
                    logger.warning("Presence: HTTP \(httpResp.statusCode, privacy: .public)")
                }
            }
        } catch {
            logger.error("Presence: error \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func startNegotiation() async {
        // Allow .waiting state - user is PTT-holding
        switch state {
        case .connected, .waiting:
            break
        case .disconnected, .inCall:
            return
        }
        
        let hasPermission = await audioLayer.checkMicPermission()
        logger.info("Mic permission check: \(hasPermission ? "granted" : "denied", privacy: .public)")
        guard hasPermission else {
            await showMicPermissionAlert()
            return
        }
        
        let micEnabled = if case .inCall(.pushToTalk(let t)) = state {
            t
        } else if case .waiting = state {
            true
        } else {
            false
        }
        
        // Set up audio layer and enable mic immediately, even if peer not tuned yet
        await audioLayer.setupWebView(
            onIceCandidate: { [weak self] candidate in
                Task { await self?.sendIceCandidate(candidate) }
            },
            onAnswer: { [weak self] answer in
                Task { await self?.sendAnswer(answer) }
            }
        )
        
        await audioLayer.setMicEnabled(micEnabled)
        
        if isSeatA {
            do {
                let offer = try await audioLayer.createOffer(iceServers: iceServers)
                logger.info("Created offer, sending to peer")
                await sendOffer(offer)
                logger.info("Offer sent")
            } catch {
                logger.error("createOffer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        
        // Double-check peer is still tuned before transitioning to .inCall
        // (conditions may have changed during async audio setup)
        let traceCheck = "[\(Date().timeIntervalSince1970)] startNegotiation end: peerTuned=\(peerTuned) lastStateEventPeerTuned=\(lastStateEventPeerTuned) currentState=\(state)\n"
        try? traceCheck.appendToFile(at: "/tmp/walkie-trace-\(sessionID ?? "unknown").log")
        
        guard peerTuned else {
            // Mic is live, but stay in current state until peer joins
            let trace = "[\(Date().timeIntervalSince1970)] startNegotiation: NOT transitioning to inCall, peerTuned=false\n"
            try? trace.appendToFile(at: "/tmp/walkie-trace-\(sessionID ?? "unknown").log")
            return
        }
        
        let trace = "[\(Date().timeIntervalSince1970)] startNegotiation: transitioning to inCall, peerTuned=\(peerTuned)\n"
        try? trace.appendToFile(at: "/tmp/walkie-trace-\(sessionID ?? "unknown").log")
        
        state = .inCall(mode: .pushToTalk(transmitting: micEnabled))
        await stopWaitingAnimation()
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }
    
    private func handleSignalEvent(_ dict: [String: Any]) async {
        guard let signalEvent = WalkieProtocol.parseSignalEvent(dict) else { return }
        guard signalEvent.from != sessionID else { return }
        
        logger.info("Signal received: kind=\(signalEvent.kind, privacy: .public)")
        
        let payload = signalEvent.payload
        
        // Accept both wrapped and standard SDP formats
        var offerJSON: String?
        var answerJSON: String?
        
        // Check for wrapped format: {offer: "..."}
        if let wrapped = payload["offer"] as? String {
            offerJSON = wrapped
        }
        // Check for standard format: {type: "offer", sdp: "..."}
        else if let type = payload["type"] as? String, type == "offer", let sdp = payload["sdp"] as? String {
            let standardOffer = ["type": "offer", "sdp": sdp]
            offerJSON = try? String(data: JSONSerialization.data(withJSONObject: standardOffer), encoding: .utf8)
        }
        
        if let wrapped = payload["answer"] as? String {
            answerJSON = wrapped
        }
        else if let type = payload["type"] as? String, type == "answer", let sdp = payload["sdp"] as? String {
            let standardAnswer = ["type": "answer", "sdp": sdp]
            answerJSON = try? String(data: JSONSerialization.data(withJSONObject: standardAnswer), encoding: .utf8)
        }
        
        if let offerJSON, !isSeatA {
            logger.info("Received offer from peer, processing...")
            do {
                await fetchICEServers()
                let answer = try await audioLayer.setOffer(offerJSON, iceServers: iceServers)
                logger.info("Created answer, sending to peer")
                await sendAnswer(answer)
                logger.info("Answer sent")
                
                let wasWaiting = if case .waiting = state { true } else { false }
                state = .inCall(mode: .pushToTalk(transmitting: wasWaiting))
                await stopWaitingAnimation()
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch {
                logger.error("handleOffer failed: \(error.localizedDescription, privacy: .public)")
            }
        } else if let offerJSON, isSeatA {
            logger.warning("Received offer but I am seat A (offerer), ignoring")
        }
        
        if let answerJSON, isSeatA {
            logger.info("Received answer from peer, processing...")
            await audioLayer.handleAnswer(answerJSON)
            logger.info("Answer processed")
        } else if let answerJSON, !isSeatA {
            logger.warning("Received answer but I am seat B (answerer), ignoring")
        }
        
        // Accept both wrapped and standard candidate formats
        var candidateJSON: String?
        if let wrapped = payload["ice_candidate"] as? String {
            candidateJSON = wrapped
        }
        else if payload["candidate"] != nil {
            // Standard format already has all fields
            candidateJSON = try? String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)
        }
        
        if let candidateJSON {
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
        
        logger.info("Signal sending: kind=\(kind, privacy: .public)")
        
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
    
    private func handlePTTDown() async {
        if channelFull {
            await showChannelFullAlert()
            return
        }
        
        switch state {
        case .disconnected:
            break
            
        case .connected(tuned: false):
            let hasPermission = await audioLayer.checkMicPermission()
            logger.info("Mic permission check (gesture): \(hasPermission ? "granted" : "denied", privacy: .public)")
            guard hasPermission else {
                await showMicPermissionAlert()
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
            await audioLayer.setMicEnabled(true)
            
            state = .waiting(started: Date())
            await sendPresence()
            await startWaitingTimer()
            await startWaitingAnimation()
            
        case .waiting:
            if case .waiting(started: _) = state {
                state = .waiting(started: Date())
            }
            await audioLayer.setMicEnabled(true)
            
        case .inCall(mode: .pushToTalk):
            state = .inCall(mode: .pushToTalk(transmitting: true))
            await audioLayer.setMicEnabled(true)
            await sendPresence()
            
        case .inCall(mode: .handsFree):
            break
            
        case .connected(tuned: true):
            break
        }
    }
    
    private func handlePTTUp() async {
        switch state {
        case .waiting:
            await audioLayer.setMicEnabled(false)
            
        case .inCall(mode: .pushToTalk):
            state = .inCall(mode: .pushToTalk(transmitting: false))
            await audioLayer.setMicEnabled(false)
            await sendPresence()
            
        default:
            break
        }
    }
    
    private func handleDoubleTap() async {
        if channelFull {
            await showChannelFullAlert()
            return
        }
        
        switch state {
        case .disconnected:
            break
            
        case .connected(tuned: false):
            let hasPermission = await audioLayer.checkMicPermission()
            logger.info("Mic permission check (gesture): \(hasPermission ? "granted" : "denied", privacy: .public)")
            guard hasPermission else {
                await showMicPermissionAlert()
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
            await audioLayer.setMicEnabled(true)
            
            state = .waiting(started: Date())
            await sendPresence()
            await startWaitingTimer()
            await startWaitingAnimation()
            
        case .waiting:
            state = .waiting(started: Date())
            
        case .inCall(mode: .pushToTalk):
            state = .inCall(mode: .handsFree)
            await audioLayer.setMicEnabled(true)
            await sendPresence()
            
        case .inCall(mode: .handsFree):
            break
            
        case .connected(tuned: true):
            break
        }
    }
    
    private func handleTap() async {
        switch state {
        case .waiting:
            // Cancel nudge (untune)
            await stopWaitingAnimation()
            await audioLayer.setMicEnabled(false)
            state = .connected(tuned: false)
            await sendPresence()
            
        case .inCall:
            // Hang up
            await endCall()
            
        default:
            break
        }
    }
    
    private func startWaitingTimer() async {
        waitingTimer?.cancel()
        
        waitingTimer = Task {
            try? await Task.sleep(for: .seconds(waitingTimeout))
            if !Task.isCancelled {
                await waitingTimeout()
            }
        }
    }
    
    private func waitingTimeout() async {
        if case .waiting = state {
            await stopWaitingAnimation()
            state = .connected(tuned: false)
            await audioLayer.setMicEnabled(false)
            await sendPresence()
        }
    }
    
    private func playGreetOnce() async {
        if !hasPlayedGreet {
            hasPlayedGreet = true
            await MainActor.run {
                SoundEngine.shared.play("greet")
            }
        }
    }
    
    private func startWaitingAnimation() async {
        await playGreetOnce()
        NotificationCenter.default.post(name: .botGreet, object: nil)
        
        let token = NSObject()
        waitingAnimationToken = token
        
        Task {
            while waitingAnimationToken === token {
                try? await Task.sleep(for: .seconds(2))
                if waitingAnimationToken === token {
                    NotificationCenter.default.post(name: .botGreet, object: nil)
                }
            }
        }
    }
    
    private func stopWaitingAnimation() async {
        waitingAnimationToken = nil
        waitingTimer?.cancel()
        waitingTimer = nil
    }
    
    private func startICERefreshTimer(seconds: Int = 2700) async {
        iceRefreshTimer?.cancel()
        
        iceRefreshTimer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled {
                await refreshICE()
            }
        }
    }
    
    private func fetchICEServers() async {
        guard let serverURL, let sessionToken else { return }
        
        let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/ice"
        guard let url = URL(string: urlStr) else { return }
        
        var req = URLRequest(url: url)
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse else { return }
            
            // 503 means no TURN servers configured
            guard httpResp.statusCode == 200 else { return }
            
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let config = WalkieProtocol.parseICEResponse(dict) {
                // Build proper ICE servers array with STUN + TURN
                var servers: [[String: Any]] = []
                
                // Add public STUN servers
                servers.append(["urls": ["stun:stun.l.google.com:19302"]])
                
                // Add TURN server with credentials
                var turnServer: [String: Any] = ["urls": config.urls]
                if let username = config.username {
                    turnServer["username"] = username
                }
                if let credential = config.credential {
                    turnServer["credential"] = credential
                }
                servers.append(turnServer)
                
                iceServers = servers
                
                // Schedule refresh before expiry
                if let refreshAfter = config.refreshAfter {
                    await startICERefreshTimer(seconds: refreshAfter)
                }
            }
        } catch {
            logger.error("fetchICEServers failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func refreshICE() async {
        await fetchICEServers()
    }
    
    private func endCall() async {
        iceRefreshTimer?.cancel()
        iceRefreshTimer = nil
        
        await audioLayer.cleanup()
        await audioLayer.setMicEnabled(false)
        
        negotiationID = nil
        hasPlayedGreet = false
        
        state = .connected(tuned: false)
        await sendPresence()
    }
    
    func disconnect() async {
        eventTask?.cancel()
        presenceTask?.cancel()
        waitingTimer?.cancel()
        iceRefreshTimer?.cancel()
        streamHealthTimer?.cancel()
        
        await stopWaitingAnimation()
        await audioLayer.cleanup()
        
        eventTask = nil
        presenceTask = nil
        waitingTimer = nil
        iceRefreshTimer = nil
        streamHealthTimer = nil
        
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
                
                do {
                    let (_, response) = try await URLSession.shared.data(for: req)
                    if let httpResp = response as? HTTPURLResponse {
                        // Accept both 200 and 204
                        guard httpResp.statusCode == 200 || httpResp.statusCode == 204 else { return }
                    }
                } catch {}
            }
        }
        
        sessionID = nil
        sessionToken = nil
        revision = 0
        negotiationID = nil
        peerTuned = false
        hasPlayedGreet = false
        
        state = .disconnected
    }
    
    @MainActor
    private func showMicPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Coucou needs microphone permission to use the walkie-talkie feature. Please enable it in System Settings > Privacy & Security > Microphone."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    @MainActor
    private func showChannelFullAlert() {
        let alert = NSAlert()
        alert.messageText = "Channel Full"
        alert.informativeText = "Channel \(channelNumber) is currently full (2 people connected). Please try again later."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
