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

/// Walkie session state machine. Isolated on the main actor so hotkeys, SSE
/// state updates, NotificationCenter posts and AppState/BotEngine touches
/// never hop off-main (that crashed SwiftUI TimelineView isolation checks).
@MainActor
final class WalkieTalkieLink {
    static let shared = WalkieTalkieLink(audioLayer: WalkieTalkieAudio.shared)
    
    private var state: WalkieState = .disconnected {
        didSet {
            if self.state != oldValue {
                logger.info("State: \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)")
                publishIsland()
            }
        }
    }
    private var sessionID: String?
    private var sessionToken: String?
    private var revision: Int = 0
    private var negotiationID: String?
    private var isSeatA: Bool = false {
        didSet {
            if self.isSeatA != oldValue {
                logger.info("Seat assignment: \(self.isSeatA ? "A" : "B", privacy: .public) (session: \(self.sessionID ?? "unknown", privacy: .public))")
            }
        }
    }
    private var peerTuned: Bool = false
    private var lastStateEventPeerTuned: Bool = false
    private var channelNumber: Int = 1
    
    private var eventTask: Task<Void, Never>?
    private var eventSession: URLSession?
    private var streamGeneration: Int = 0
    private var presenceTask: Task<Void, Never>?
    private var waitingTimer: Task<Void, Never>?
    private var iceRefreshTimer: Task<Void, Never>?
    private var streamHealthTimer: Task<Void, Never>?
    private var bothTunedWatchdog: Task<Void, Never>?
    private(set) var reconnectCount: Int = 0
    private(set) var channelFullCount: Int = 0
    var streamDeadAfter: TimeInterval = WalkieSSE.streamDeadAfter
    
    private var iceServers: [[String: Any]] = []
    private var serverURL: String?
    private var channelToken: String?
    private var channelFull: Bool = false {
        didSet {
            if self.channelFull != oldValue {
                logger.info("Channel full: \(self.channelFull, privacy: .public)")
                publishIsland()
            }
        }
    }
    private var channelFullAttempts: Int = 0
    var channelFullRetrySteps: [TimeInterval] = [2, 4, 8]
    var channelFullRetryCap: TimeInterval = 15
    private var lastEventTime: Date = Date()
    private var reconnectAttempts: Int = 0
    
    private var waitingAnimationToken: NSObject?
    private var currentSSEEvent: String?
    private var hasPlayedGreet: Bool = false
    private var isHeld: Bool = false
    private var handsFree: Bool = false
    private var negotiationMediaReady: Bool = false
    private var peerUntunedGraceTask: Task<Void, Never>?
    
    private var audioLayer: WalkieAudioLayer
    
    private var intendedMicEnabled: Bool {
        handsFree || isHeld
    }
    
    private var intendedCallMode: WalkieState.CallMode {
        if handsFree { return .handsFree }
        return .pushToTalk(transmitting: isHeld)
    }
    
    private func resetTalkIntent() {
        isHeld = false
        handsFree = false
    }
    
    private func applyTalkIntent() {
        audioLayer.setMicEnabled(intendedMicEnabled)
    }
    
    var waitingTimeout: TimeInterval = 30  // Injectable for tests
    
    init(audioLayer: WalkieAudioLayer) {
        self.audioLayer = audioLayer
        observeWalkieNotification(.walkiePTTDown, action: .pttDown)
        observeWalkieNotification(.walkiePTTUp, action: .pttUp)
        observeWalkieNotification(.walkieDoubleTap, action: .doubleTap)
        observeWalkieNotification(.walkieTap, action: .tap)
    }
    
    private enum WalkieHotkeyAction: Sendable {
        case pttDown, pttUp, doubleTap, tap
    }
    
    private func observeWalkieNotification(_ name: Notification.Name, action: WalkieHotkeyAction) {
        NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let targetID = (notification.object as AnyObject?).map { ObjectIdentifier($0) }
            Task { @MainActor in
                guard let self else { return }
                guard targetID == nil || targetID == ObjectIdentifier(self) else { return }
                switch action {
                case .pttDown:
                    logger.info("Walkie gesture: holdStart")
                    await self.handlePTTDown()
                case .pttUp:
                    logger.info("Walkie gesture: holdEnd")
                    await self.handlePTTUp()
                case .doubleTap:
                    logger.info("Walkie gesture: doubleTap")
                    await self.handleDoubleTap()
                case .tap:
                    logger.info("Walkie gesture: singleTap")
                    await self.handleTap()
                }
            }
        }
    }
    
    var currentState: WalkieState {
        state
    }

    var isChannelFull: Bool {
        channelFull
    }

    var hasSession: Bool {
        sessionID != nil
    }

    func forceReconnectForTest() async {
        await reconnect()
    }

    private func publishIsland() {
        if channelFull {
            WalkieIslandState.shared.applyChannelFull()
            NotificationCenter.default.post(name: .hookReveal, object: nil)
            return
        }
        WalkieIslandState.shared.apply(state)
        switch state {
        case .waiting, .inCall:
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        default:
            break
        }
    }
    
    var isAssignedSeatA: Bool {
        isSeatA
    }
    
    func configure(serverURL: String?, accessCode: String?) async {
        // Leave the current seat before applying a new (or empty) code.
        await disconnect()
        
        guard let code = accessCode, !code.isEmpty else {
            logger.info("configure: early return, no access code")
            self.serverURL = nil
            self.channelToken = nil
            return
        }
        
        guard let components = WalkieProtocol.decodeAccessCode(code) else {
            logger.error("configure: early return, access code decode failed")
            self.serverURL = nil
            self.channelToken = nil
            return
        }
        
        self.serverURL = components.origin
        self.channelToken = components.channelToken
        self.channelNumber = components.channel
        logger.info("configure: origin=\(components.origin, privacy: .public) channel=\(components.channel, privacy: .public)")
        
        await connectIfNeeded()
    }
    
    private func connectIfNeeded() async {
        guard case .disconnected = state else {
            logger.info("connectIfNeeded: early return, already \(String(describing: self.state), privacy: .public)")
            return
        }
        guard let serverURL, let channelToken, !serverURL.isEmpty, !channelToken.isEmpty else {
            let hasURL = !(serverURL ?? "").isEmpty
            logger.error("connectIfNeeded: early return, missing \(hasURL ? "channel token" : "server URL", privacy: .public)")
            return
        }
        
        logger.info("connectIfNeeded: connecting to \(serverURL, privacy: .public) channel=\(self.channelNumber, privacy: .public)")
        channelFull = false
        channelFullAttempts = 0
        reconnectCount = 0
        channelFullCount = 0
        state = .connected(tuned: false)
        reconnectAttempts = 0
        
        await startEventStream()
        await startStreamHealthMonitor()
    }
    
    private func makeEventsRequest() -> URLRequest? {
        guard let serverURL, let channelToken else { return nil }
        let baseURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = "\(baseURL)/v3/channels/\(channelNumber)/events"
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(channelToken)", forHTTPHeaderField: "Authorization")
        return request
    }
    
    private func startEventStream() async {
        eventTask?.cancel()
        eventSession?.invalidateAndCancel()
        eventSession = nil
        
        guard let request = makeEventsRequest() else { return }
        streamGeneration += 1
        let generation = streamGeneration
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7 * 24 * 3600
        config.timeoutIntervalForResource = 7 * 24 * 3600
        let session = URLSession(configuration: config)
        eventSession = session
        
        lastEventTime = Date()
        logger.info("SSE: Connecting to \(request.url?.absoluteString ?? "", privacy: .public)")
        
        // I/O stays off the main actor. Read raw bytes so `: keepalive`
        // comments refresh liveness (bytes.lines dropped those).
        eventTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let currentGen = await self?.streamGeneration
                if currentGen != generation { return }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let status = (response as? HTTPURLResponse)?.statusCode {
                        switch await self?.consumeEventHTTPStatus(status) ?? .stop {
                        case .stop:
                            return
                        case .retry(let seconds):
                            try? await Task.sleep(for: .seconds(seconds))
                            continue
                        case .proceed:
                            break
                        }
                    }
                    
                    var buffer = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        buffer.append(byte)
                        if byte == 0x0A {
                            await self?.noteSSEBytes()
                            let lines = WalkieSSE.pullLines(from: &buffer)
                            for line in lines {
                                await self?.handleSSELine(line)
                            }
                        }
                    }
                    
                    if !Task.isCancelled {
                        let stillCurrent = await self?.streamGeneration == generation
                        if stillCurrent {
                            await self?.noteSSEStreamEnded()
                            if let backoff = await self?.nextReconnectBackoff() {
                                try? await Task.sleep(for: .seconds(backoff))
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    let stillCurrent = await self?.streamGeneration == generation
                    if !stillCurrent { return }
                    await self?.noteSSEError(error)
                    if let backoff = await self?.nextReconnectBackoff() {
                        try? await Task.sleep(for: .seconds(backoff))
                    }
                }
            }
        }
    }
    
    private enum EventStreamDisposition {
        case stop
        case retry(seconds: TimeInterval)
        case proceed
    }
    
    private func consumeEventHTTPStatus(_ status: Int) async -> EventStreamDisposition {
        if status == 409 {
            channelFullCount += 1
            channelFullAttempts += 1
            let delay = WalkieProtocol.channelFullBackoff(
                attempt: channelFullAttempts,
                steps: channelFullRetrySteps,
                cap: channelFullRetryCap
            )
            logger.error("SSE: Channel full (409), retrying in \(delay, privacy: .public)s")
            channelFull = true
            return .retry(seconds: delay)
        }
        if status == 401 {
            logger.error("SSE: Authentication failed (401)")
            await disconnect()
            return .stop
        }
        guard status == 200 else {
            logger.warning("SSE: HTTP \(status, privacy: .public), will retry")
            return .retry(seconds: TimeInterval(nextReconnectBackoff()))
        }
        logger.info("SSE: Connected (200)")
        channelFull = false
        channelFullAttempts = 0
        reconnectAttempts = 0
        lastEventTime = Date()
        return .proceed
    }
    
    private func noteSSEStreamEnded() async {
        logger.warning("SSE stream ended, reconnecting...")
        await reconnect()
    }
    
    private func noteSSEError(_ error: Error) {
        logger.error("SSE error: \(error.localizedDescription, privacy: .public)")
    }
    
    private func nextReconnectBackoff() -> Int {
        reconnectAttempts += 1
        let backoffs = [1, 2, 4, 8, 30]
        return backoffs[min(reconnectAttempts - 1, backoffs.count - 1)]
    }
    
    private func startStreamHealthMonitor() async {
        streamHealthTimer?.cancel()
        
        streamHealthTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if self.channelFull { continue }
                let age = Date().timeIntervalSince(self.lastEventTime)
                if age > self.streamDeadAfter {
                    logger.warning("Stream dead for \(age, privacy: .public)s, reconnecting...")
                    await self.reconnect()
                }
            }
        }
    }
    
    private func reconnect() async {
        reconnectCount += 1
        logger.info("Reconnecting...")
        lastEventTime = Date()
        
        let wasConnected = state != .disconnected
        // Close the old SSE and DELETE the seat before opening a new /events.
        cancelWalkieTasks()
        audioLayer.cleanup()
        await leaveSession()
        
        sessionID = nil
        sessionToken = nil
        revision = 0
        negotiationID = nil
        negotiationMediaReady = false
        peerTuned = false
        hasPlayedGreet = false
        bothTunedWatchdog?.cancel()
        bothTunedWatchdog = nil
        
        if wasConnected {
            state = .connected(tuned: false)
            await startEventStream()
            await startStreamHealthMonitor()
        }
    }

    private func noteSSEBytes() {
        lastEventTime = Date()
    }
    
    private func handleSSELine(_ line: String) async {
        lastEventTime = Date()
        if WalkieSSE.isCommentLine(line) {
            if line.contains("keepalive") {
                logger.info("SSE: keepalive")
            }
            return
        }
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
                attachAudioLayer()
                Task {
                    await self.audioLayer.probeCapture()
                }
                
            case "state":
                guard let stateEvent = WalkieProtocol.parseStateEvent(dict) else { return }
                // Use server's view of both local and peer tuned state (not local state)
                // This prevents entering call before server confirms both are tuned
                let myTuned = stateEvent.localTuned
                let wasPeerTuned = peerTuned
                peerTuned = stateEvent.peerTuned
                lastStateEventPeerTuned = stateEvent.peerTuned
                let offererLabel = self.isSeatA ? "A (offerer)" : "B (answerer)"
                logger.info("Server state: local.tuned=\(stateEvent.localTuned, privacy: .public) peer.tuned=\(stateEvent.peerTuned, privacy: .public) offerer=\(offererLabel, privacy: .public) negotiation=\(stateEvent.negotiationID ?? "none", privacy: .public)")
                
                // Debug trace for CI
                let trace = "[\(Date().timeIntervalSince1970)] state event: local.tuned=\(stateEvent.localTuned) peer.tuned=\(stateEvent.peerTuned) negID=\(stateEvent.negotiationID ?? "nil") currentState=\(state)\n"
                try? trace.appendToFile(at: "/tmp/walkie-trace-\(sessionID ?? "unknown").log")
                
                if myTuned && peerTuned {
                    self.peerUntunedGraceTask?.cancel()
                    self.peerUntunedGraceTask = nil
                    logger.info("Both tuned: local=true peer=true offerer=\(offererLabel, privacy: .public) negotiation=\(stateEvent.negotiationID ?? "none", privacy: .public)")
                    if stateEvent.negotiationID == nil {
                        self.startBothTunedWatchdog()
                    } else {
                        self.bothTunedWatchdog?.cancel()
                        self.bothTunedWatchdog = nil
                    }
                    // Both tuned - start or continue call
                    if case .waiting = state {
                        waitingTimer?.cancel()
                        waitingTimer = nil
                    }
                    
                    if let negID = stateEvent.negotiationID, negID != negotiationID {
                        negotiationID = negID
                        negotiationMediaReady = false
                        peerUntunedGraceTask?.cancel()
                        peerUntunedGraceTask = nil
                        let traceNeg = "[\(Date().timeIntervalSince1970)] calling startNegotiation: negotiationID=\(negID) isSeatA=\(isSeatA) currentState=\(state)\n"
                        try? traceNeg.appendToFile(at: "/tmp/walkie-trace-\(sessionID ?? "unknown").log")
                        await fetchICEServers()
                        await startNegotiation()
                    }
                    
                    // Play greet only on actual peer tune transition
                    if !wasPeerTuned {
                        playGreetOnce()
                    }
                } else if myTuned && !peerTuned {
                    self.bothTunedWatchdog?.cancel()
                    self.bothTunedWatchdog = nil
                    if case .inCall = state {
                        if self.negotiationMediaReady {
                            await endCall(reason: "peer untuned while inCall")
                        } else {
                            let seat = self.isSeatA ? "A" : "B"
                            logger.error("Peer untuned while inCall but offer/answer not ready; staying inCall seat=\(seat, privacy: .public) — not tearing down")
                            self.startPeerUntunedGrace()
                        }
                    }
                } else if !myTuned && peerTuned {
                    self.bothTunedWatchdog?.cancel()
                    self.bothTunedWatchdog = nil
                    // Peer is waiting
                    if case .connected = state {
                        await startWaitingAnimation()
                    }
                } else {
                    self.bothTunedWatchdog?.cancel()
                    self.bothTunedWatchdog = nil
                    if case .inCall = state {
                        if self.negotiationMediaReady {
                            await endCall(reason: "both untuned while inCall")
                        } else {
                            logger.error("Both untuned while inCall but offer/answer not ready; staying inCall — not tearing down")
                            self.startPeerUntunedGrace()
                        }
                    }
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
                await self.sendPresence()
                try? await Task.sleep(for: .seconds(WalkieSSE.presenceInterval))
            }
        }
    }

    private func startBothTunedWatchdog() {
        bothTunedWatchdog?.cancel()
        bothTunedWatchdog = Task {
            try? await Task.sleep(for: .seconds(WalkieSSE.bothTunedOfferDeadline))
            guard !Task.isCancelled else { return }
            if self.peerTuned && self.isLocallyTuned() && self.negotiationID == nil {
                logger.error("Both tuned for 5s but no negotiation_id/offer")
            }
        }
    }

    private func attachAudioLayer() {
        audioLayer.setupWebView(
            onIceCandidate: { [weak self] candidate in
                Task { @MainActor in
                    await self?.sendIceCandidate(candidate)
                }
            },
            onAnswer: { [weak self] answer in
                Task { @MainActor in
                    await self?.sendAnswer(answer)
                }
            }
        )
    }
    
    private func sendPresence() async {
        guard let serverURL, let sessionToken, let sessionID else { return }
        
        revision += 1
        
        let tuned = isLocallyTuned()
        let transmitting: Bool
        switch state {
        case .inCall(.pushToTalk(let t)):
            transmitting = t
        case .inCall(.handsFree):
            transmitting = true
        default:
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
            showMicPermissionAlert()
            return
        }
        
        // Mic and CallMode come from explicit hold / hands-free intent, not from .waiting
        attachAudioLayer()
        
        applyTalkIntent()
        
        if isSeatA {
            do {
                let offer = try await audioLayer.createOffer(iceServers: iceServers)
                negotiationMediaReady = true
                logger.info("Created offer, sending to peer")
                await sendOffer(offer)
                logger.info("Offer sent")
            } catch {
                logger.error("createOffer failed: \(error.localizedDescription, privacy: .public); staying \(String(describing: self.state), privacy: .public) (will not silently endCall)")
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
        
        state = .inCall(mode: intendedCallMode)
        applyTalkIntent()
        await stopWaitingAnimation()
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }
    
    private func handleSignalEvent(_ dict: [String: Any]) async {
        guard let signalEvent = WalkieProtocol.parseSignalEvent(dict) else {
            logger.error("Failed to parse signal event")
            return
        }
        
        if signalEvent.from == sessionID {
            logger.debug("Ignoring signal from self: kind=\(signalEvent.kind, privacy: .public)")
            return
        }
        
        logger.info("Signal received: kind=\(signalEvent.kind, privacy: .public) from=\(signalEvent.from, privacy: .public)")
        
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
                negotiationMediaReady = true
                peerUntunedGraceTask?.cancel()
                peerUntunedGraceTask = nil
                logger.info("Created answer, sending to peer")
                await sendAnswer(answer)
                logger.info("Answer sent")
                
                state = .inCall(mode: intendedCallMode)
                applyTalkIntent()
                await stopWaitingAnimation()
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch {
                logger.error("handleOffer failed: \(error.localizedDescription, privacy: .public); staying \(String(describing: self.state), privacy: .public) so a later offer can retry (will not silently endCall)")
            }
        } else if offerJSON != nil, isSeatA {
            logger.warning("Received offer but I am seat A (offerer), ignoring")
        }
        
        if let answerJSON, isSeatA {
            logger.info("Received answer from peer, processing...")
            audioLayer.handleAnswer(answerJSON)
            logger.info("Answer processed")
        } else if answerJSON != nil, !isSeatA {
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
            audioLayer.addIceCandidate(candidateJSON)
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
        guard let serverURL, let sessionToken, let sessionID, let negotiationID else {
            logger.error("Cannot send signal: missing serverURL/token/sessionID/negotiationID")
            return
        }
        
        logger.info("Signal sending: kind=\(kind, privacy: .public) session=\(sessionID, privacy: .public) negID=\(negotiationID, privacy: .public)")
        
        let body = WalkieProtocol.buildSignalBody(
            sessionID: sessionID,
            negotiationID: negotiationID,
            kind: kind,
            payload: payload
        )
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            logger.error("Failed to serialize signal body")
            return
        }
        
        let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/signal"
        guard let url = URL(string: urlStr) else {
            logger.error("Invalid signal URL: \(urlStr, privacy: .public)")
            return
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    logger.info("Signal sent successfully: kind=\(kind, privacy: .public)")
                } else {
                    logger.error("Signal send failed: HTTP \(httpResp.statusCode, privacy: .public)")
                }
            }
        } catch {
            logger.error("Signal send error: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func handlePTTDown() async {
        if channelFull {
            return
        }
        
        switch state {
        case .disconnected:
            break
            
        case .connected(tuned: false):
            let hasPermission = await audioLayer.checkMicPermission()
            logger.info("Mic permission check (gesture): \(hasPermission ? "granted" : "denied", privacy: .public)")
            guard hasPermission else {
                showMicPermissionAlert()
                return
            }
            
            isHeld = true
            handsFree = false
            
            attachAudioLayer()
            applyTalkIntent()
            
            state = .waiting(started: Date())
            await sendPresence()
            await startWaitingTimer()
            await startWaitingAnimation()
            
        case .waiting:
            isHeld = true
            if case .waiting(started: _) = state {
                state = .waiting(started: Date())
            }
            applyTalkIntent()
            
        case .inCall(mode: .pushToTalk):
            isHeld = true
            state = .inCall(mode: intendedCallMode)
            applyTalkIntent()
            await sendPresence()
            
        case .inCall(mode: .handsFree):
            isHeld = true
            
        case .connected(tuned: true):
            break
        }
    }
    
    private func handlePTTUp() async {
        isHeld = false
        switch state {
        case .waiting:
            if self.handsFree {
                self.applyTalkIntent()
                return
            }
            logger.info("Hold ended: untune waiting")
            self.resetTalkIntent()
            await self.stopWaitingAnimation()
            self.waitingTimer?.cancel()
            self.waitingTimer = nil
            self.applyTalkIntent()
            self.state = .connected(tuned: false)
            await self.sendPresence()
            
        case .inCall:
            self.state = .inCall(mode: self.intendedCallMode)
            self.applyTalkIntent()
            await self.sendPresence()
            
        default:
            break
        }
    }
    
    private func handleDoubleTap() async {
        if channelFull {
            return
        }
        
        switch state {
        case .disconnected:
            break
            
        case .connected(tuned: false):
            let hasPermission = await audioLayer.checkMicPermission()
            logger.info("Mic permission check (gesture): \(hasPermission ? "granted" : "denied", privacy: .public)")
            guard hasPermission else {
                showMicPermissionAlert()
                return
            }
            
            handsFree = true
            isHeld = false
            
            attachAudioLayer()
            applyTalkIntent()
            
            state = .waiting(started: Date())
            await sendPresence()
            await startWaitingTimer()
            await startWaitingAnimation()
            
        case .waiting:
            handsFree = true
            state = .waiting(started: Date())
            applyTalkIntent()
            
        case .inCall(mode: .pushToTalk):
            handsFree = true
            state = .inCall(mode: intendedCallMode)
            applyTalkIntent()
            await sendPresence()
            
        case .inCall(mode: .handsFree):
            handsFree = true
            
        case .connected(tuned: true):
            break
        }
    }
    
    private func handleTap() async {
        switch state {
        case .waiting:
            // Cancel nudge (untune)
            resetTalkIntent()
            await stopWaitingAnimation()
            applyTalkIntent()
            state = .connected(tuned: false)
            await sendPresence()
            
        case .inCall:
            // Hang up
            await endCall(reason: "single tap hangup")
            
        default:
            break
        }
    }
    
    private func startWaitingTimer() async {
        waitingTimer?.cancel()
        
        waitingTimer = Task {
            try? await Task.sleep(for: .seconds(self.waitingTimeout))
            if !Task.isCancelled {
                await self.waitingTimeout()
            }
        }
    }
    
    private func waitingTimeout() async {
        if case .waiting = state {
            resetTalkIntent()
            await stopWaitingAnimation()
            state = .connected(tuned: false)
            applyTalkIntent()
            await sendPresence()
        }
    }
    
    private func playGreetOnce() {
        if !hasPlayedGreet {
            hasPlayedGreet = true
            SoundEngine.shared.play("greet")
        }
    }
    
    private func startWaitingAnimation() async {
        playGreetOnce()
        NotificationCenter.default.post(name: .botGreet, object: nil)
        
        let token = NSObject()
        waitingAnimationToken = token
        
        Task {
            while self.waitingAnimationToken === token {
                try? await Task.sleep(for: .seconds(2))
                if self.waitingAnimationToken === token {
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
                await self.refreshICE()
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
    
    private func startPeerUntunedGrace() {
        peerUntunedGraceTask?.cancel()
        peerUntunedGraceTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            if case .inCall = self.state, !self.peerTuned {
                await self.endCall(reason: "peer stayed untuned for 8s before offer/answer")
            }
        }
    }

    private func endCall(reason: String) async {
        let seat = isSeatA ? "A" : "B"
        logger.info("endCall: \(reason, privacy: .public) state=\(String(describing: self.state), privacy: .public) seat=\(seat, privacy: .public) peerTuned=\(self.peerTuned, privacy: .public) mediaReady=\(self.negotiationMediaReady, privacy: .public)")
        iceRefreshTimer?.cancel()
        iceRefreshTimer = nil
        peerUntunedGraceTask?.cancel()
        peerUntunedGraceTask = nil
        
        resetTalkIntent()
        audioLayer.cleanup()
        applyTalkIntent()
        
        negotiationID = nil
        negotiationMediaReady = false
        hasPlayedGreet = false
        
        state = .connected(tuned: false)
        await sendPresence()
    }
    
    func disconnect() async {
        cancelWalkieTasks()
        await stopWaitingAnimation()
        audioLayer.cleanup()
        await leaveSession()
        resetAfterLeave()
    }

    /// Cancel SSE and DELETE the session immediately. Safe to call from
    /// `applicationWillTerminate` (does not hop back onto the main actor).
    func shutdown() {
        cancelWalkieTasks()
        audioLayer.cleanup()
        leaveSessionBlocking()
        resetAfterLeave()
    }

    private func cancelWalkieTasks() {
        streamGeneration += 1
        eventTask?.cancel()
        eventSession?.invalidateAndCancel()
        eventSession = nil
        presenceTask?.cancel()
        waitingTimer?.cancel()
        iceRefreshTimer?.cancel()
        streamHealthTimer?.cancel()
        bothTunedWatchdog?.cancel()
        peerUntunedGraceTask?.cancel()
        eventTask = nil
        presenceTask = nil
        waitingTimer = nil
        iceRefreshTimer = nil
        streamHealthTimer = nil
        bothTunedWatchdog = nil
        peerUntunedGraceTask = nil
    }

    private func makeLeaveRequest() -> URLRequest? {
        guard let serverURL, let sessionToken, let sessionID else { return nil }
        let urlStr = "\(serverURL)/v3/channels/\(channelNumber)/session"
        guard let url = URL(string: urlStr) else { return nil }
        let body = WalkieProtocol.buildLeaveBody(sessionID: sessionID)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        req.timeoutInterval = 2
        return req
    }

    private func leaveSession() async {
        guard let req = makeLeaveRequest() else { return }
        logger.info("Leaving session")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse {
                logger.info("Leave session: HTTP \(httpResp.statusCode, privacy: .public)")
            }
        } catch {
            logger.error("Leave session error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func leaveSessionBlocking() {
        guard let req = makeLeaveRequest() else { return }
        logger.info("Leaving session (blocking)")
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, response, _ in
            if let httpResp = response as? HTTPURLResponse {
                logger.info("Leave session: HTTP \(httpResp.statusCode, privacy: .public)")
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
    }

    private func resetAfterLeave() {
        sessionID = nil
        sessionToken = nil
        revision = 0
        negotiationID = nil
        negotiationMediaReady = false
        peerTuned = false
        hasPlayedGreet = false
        channelFull = false
        channelFullAttempts = 0
        bothTunedWatchdog?.cancel()
        bothTunedWatchdog = nil
        resetTalkIntent()
        state = .disconnected
    }
    
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
    
}
