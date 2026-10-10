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
    private var presenceTask: Task<Void, Never>?
    private var waitingTimer: Task<Void, Never>?
    private var iceRefreshTimer: Task<Void, Never>?
    private var streamHealthTimer: Task<Void, Never>?
    
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
                case .pttDown: await self.handlePTTDown()
                case .pttUp: await self.handlePTTUp()
                case .doubleTap: await self.handleDoubleTap()
                case .tap: await self.handleTap()
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
        
        guard let request = makeEventsRequest() else { return }
        logger.info("SSE: Connecting to \(request.url?.absoluteString ?? "", privacy: .public)")
        
        // I/O stays off the main actor; every state / UI hop goes through @MainActor methods.
        eventTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
                    
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        await self?.handleSSELine(line)
                    }
                    
                    if !Task.isCancelled {
                        await self?.noteSSEStreamEnded()
                        if let backoff = await self?.nextReconnectBackoff() {
                            try? await Task.sleep(for: .seconds(backoff))
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
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
                try? await Task.sleep(for: .seconds(35))
                if self.channelFull { continue }
                if Date().timeIntervalSince(self.lastEventTime) > 35 {
                    logger.warning("Stream dead for 35s, reconnecting...")
                    await self.reconnect()
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
        
        audioLayer.cleanup()
        
        if wasConnected {
            state = .disconnected
            state = .connected(tuned: false)
            await startEventStream()
        }
    }
    
    private func handleSSELine(_ line: String) async {
        lastEventTime = Date()
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
                        playGreetOnce()
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
        
        applyTalkIntent()
        
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
                logger.info("Created answer, sending to peer")
                await sendAnswer(answer)
                logger.info("Answer sent")
                
                state = .inCall(mode: intendedCallMode)
                applyTalkIntent()
                await stopWaitingAnimation()
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch {
                logger.error("handleOffer failed: \(error.localizedDescription, privacy: .public)")
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
            // Release PTT while waiting → mute unless hands-free
            applyTalkIntent()
            
        case .inCall:
            // Release PTT during call → stay in call; mic follows intent
            state = .inCall(mode: intendedCallMode)
            applyTalkIntent()
            await sendPresence()
            
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
        
        resetTalkIntent()
        audioLayer.cleanup()
        applyTalkIntent()
        
        negotiationID = nil
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
        eventTask?.cancel()
        presenceTask?.cancel()
        waitingTimer?.cancel()
        iceRefreshTimer?.cancel()
        streamHealthTimer?.cancel()
        eventTask = nil
        presenceTask = nil
        waitingTimer = nil
        iceRefreshTimer = nil
        streamHealthTimer = nil
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
        peerTuned = false
        hasPlayedGreet = false
        channelFull = false
        channelFullAttempts = 0
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
