import Foundation
import AppKit

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
    static let shared = WalkieTalkieLink()
    
    private var state: WalkieState = .disconnected
    private var sessionID: String?
    private var sessionToken: String?
    private var revision: Int = 0
    private var negotiationID: String?
    private var isSeatA: Bool = false
    private var peerTuned: Bool = false
    
    private var eventTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var waitingTimer: Task<Void, Never>?
    private var iceRefreshTimer: Task<Void, Never>?
    
    private var iceServers: [[String: String]] = []
    private var serverURL: String?
    private var channelToken: String?
    private var channelFull: Bool = false
    
    private var waitingAnimationToken: NSObject?
    private var currentSSEEvent: String?
    
    private init() {
        NotificationCenter.default.addObserver(
            forName: .walkiePTTDown,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handlePTTDown() }
        }
        
        NotificationCenter.default.addObserver(
            forName: .walkiePTTUp,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handlePTTUp() }
        }
        
        NotificationCenter.default.addObserver(
            forName: .walkieDoubleTap,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleDoubleTap() }
        }
        
        NotificationCenter.default.addObserver(
            forName: .walkieTap,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleTap() }
        }
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
        
        await connectIfNeeded()
    }
    
    private func connectIfNeeded() async {
        guard case .disconnected = state else { return }
        guard let serverURL, let channelToken, !serverURL.isEmpty, !channelToken.isEmpty else { return }
        
        channelFull = false
        state = .connected(tuned: false)
        
        await startEventStream()
    }
    
    private func startEventStream() async {
        eventTask?.cancel()
        
        guard let serverURL, let channelToken else { return }
        
        let baseURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = "\(baseURL)/v3/channels/1/events"
        guard let url = URL(string: urlStr) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(channelToken)", forHTTPHeaderField: "Authorization")
        
        eventTask = Task {
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    if let httpResp = response as? HTTPURLResponse {
                        if httpResp.statusCode == 409 {
                            channelFull = true
                            await disconnect()
                            return
                        }
                        guard httpResp.statusCode == 200 else {
                            try? await Task.sleep(for: .seconds(5))
                            continue
                        }
                    }
                    
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        await handleSSELine(line)
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(5))
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
                revision = 0
                await startPresence()
                
            case "state":
                guard let stateEvent = WalkieProtocol.parseStateEvent(dict) else { return }
                let myTuned = isLocallyTuned()
                peerTuned = stateEvent.peerTuned
                
                if myTuned && peerTuned {
                    if case .waiting = state {
                        await stopWaitingAnimation()
                    }
                    
                    if let negID = stateEvent.negotiationID, negID != negotiationID {
                        negotiationID = negID
                        await fetchICEServers()
                        await startNegotiation()
                    }
                } else if myTuned && !peerTuned {
                    if case .inCall = state {
                        await endCall()
                    }
                } else if !myTuned && peerTuned {
                    if case .connected = state {
                        await startWaitingAnimation()
                    }
                } else {
                    if case .waiting = state {
                        await stopWaitingAnimation()
                    }
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
        
        let urlStr = "\(serverURL)/v3/channels/1/presence"
        guard let url = URL(string: urlStr) else { return }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        
        _ = try? await URLSession.shared.data(for: req)
    }
    
    private func startNegotiation() async {
        guard case .connected = state else { return }
        guard peerTuned else { return }
        
        let hasPermission = await WalkieTalkieAudio.shared.checkMicPermission()
        guard hasPermission else {
            await showMicPermissionAlert()
            return
        }
        
        await MainActor.run {
            WalkieTalkieAudio.shared.setupWebView(
                onIceCandidate: { [weak self] candidate in
                    Task { await self?.sendIceCandidate(candidate) }
                },
                onAnswer: { [weak self] answer in
                    Task { await self?.sendAnswer(answer) }
                }
            )
        }
        
        if isSeatA {
            do {
                let offer = try await WalkieTalkieAudio.shared.createOffer(iceServers: iceServers)
                await sendOffer(offer)
            } catch {}
        }
        
        state = .inCall(mode: .pushToTalk(transmitting: false))
        await stopWaitingAnimation()
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }
    
    private func handleSignalEvent(_ dict: [String: Any]) async {
        guard let signalEvent = WalkieProtocol.parseSignalEvent(dict) else { return }
        guard signalEvent.from != sessionID else { return }
        
        let payload = signalEvent.payload
        
        if let offerJSON = payload["offer"] as? String, !isSeatA {
            do {
                let answer = try await WalkieTalkieAudio.shared.setOffer(offerJSON, iceServers: iceServers)
                await sendAnswer(answer)
            } catch {}
        }
        
        if let answerJSON = payload["answer"] as? String, isSeatA {
            await MainActor.run {
                WalkieTalkieAudio.shared.handleAnswer(answerJSON)
            }
        }
        
        if let candidateJSON = payload["ice_candidate"] as? String {
            await MainActor.run {
                WalkieTalkieAudio.shared.addIceCandidate(candidateJSON)
            }
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
        
        let urlStr = "\(serverURL)/v3/channels/1/signal"
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
            let hasPermission = await WalkieTalkieAudio.shared.checkMicPermission()
            guard hasPermission else {
                await showMicPermissionAlert()
                return
            }
            
            await MainActor.run {
                WalkieTalkieAudio.shared.setupWebView(
                    onIceCandidate: { [weak self] candidate in
                        Task { await self?.sendIceCandidate(candidate) }
                    },
                    onAnswer: { [weak self] answer in
                        Task { await self?.sendAnswer(answer) }
                    }
                )
                WalkieTalkieAudio.shared.setMicEnabled(true)
            }
            
            state = .waiting(started: Date())
            await sendPresence()
            await startWaitingTimer()
            await startWaitingAnimation()
            
        case .waiting:
            if case .waiting(started: _) = state {
                state = .waiting(started: Date())
            }
            await MainActor.run {
                WalkieTalkieAudio.shared.setMicEnabled(true)
            }
            
        case .inCall(mode: .pushToTalk):
            state = .inCall(mode: .pushToTalk(transmitting: true))
            await MainActor.run {
                WalkieTalkieAudio.shared.setMicEnabled(true)
            }
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
            await MainActor.run {
                WalkieTalkieAudio.shared.setMicEnabled(false)
            }
            
        case .inCall(mode: .pushToTalk):
            state = .inCall(mode: .pushToTalk(transmitting: false))
            await MainActor.run {
                WalkieTalkieAudio.shared.setMicEnabled(false)
            }
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
            let hasPermission = await WalkieTalkieAudio.shared.checkMicPermission()
            guard hasPermission else {
                await showMicPermissionAlert()
                return
            }
            
            await MainActor.run {
                WalkieTalkieAudio.shared.setupWebView(
                    onIceCandidate: { [weak self] candidate in
                        Task { await self?.sendIceCandidate(candidate) }
                    },
                    onAnswer: { [weak self] answer in
                        Task { await self?.sendAnswer(answer) }
                    }
                )
                WalkieTalkieAudio.shared.setMicEnabled(true)
            }
            
            state = .waiting(started: Date())
            await sendPresence()
            await startWaitingTimer()
            await startWaitingAnimation()
            
        case .waiting:
            state = .waiting(started: Date())
            
        case .inCall(mode: .pushToTalk):
            state = .inCall(mode: .handsFree)
            await MainActor.run {
                WalkieTalkieAudio.shared.setMicEnabled(true)
            }
            await sendPresence()
            
        case .inCall(mode: .handsFree):
            break
            
        case .connected(tuned: true):
            break
        }
    }
    
    private func handleTap() async {
        switch state {
        case .inCall:
            await endCall()
            
        default:
            break
        }
    }
    
    private func startWaitingTimer() async {
        waitingTimer?.cancel()
        
        waitingTimer = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled {
                await waitingTimeout()
            }
        }
    }
    
    private func waitingTimeout() async {
        if case .waiting = state {
            await stopWaitingAnimation()
            state = .connected(tuned: false)
            await MainActor.run {
                WalkieTalkieAudio.shared.setMicEnabled(false)
            }
            await sendPresence()
        }
    }
    
    private func startWaitingAnimation() async {
        await MainActor.run {
            SoundEngine.shared.play("greet")
        }
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
        
        let urlStr = "\(serverURL)/v3/channels/1/ice"
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
                var serverDict: [String: String] = [:]
                serverDict["urls"] = config.urls.joined(separator: ",")
                if let username = config.username {
                    serverDict["username"] = username
                }
                if let credential = config.credential {
                    serverDict["credential"] = credential
                }
                iceServers = [serverDict]
                
                // Schedule refresh before expiry
                if let refreshAfter = config.refreshAfter {
                    await startICERefreshTimer(seconds: refreshAfter)
                }
            }
        } catch {}
    }
    
    private func refreshICE() async {
        await fetchICEServers()
    }
    
    private func endCall() async {
        iceRefreshTimer?.cancel()
        iceRefreshTimer = nil
        
        await MainActor.run {
            WalkieTalkieAudio.shared.setMicEnabled(false)
        }
        negotiationID = nil
        
        state = .connected(tuned: false)
        await sendPresence()
    }
    
    private func disconnect() async {
        eventTask?.cancel()
        presenceTask?.cancel()
        waitingTimer?.cancel()
        iceRefreshTimer?.cancel()
        
        await stopWaitingAnimation()
        
        eventTask = nil
        presenceTask = nil
        waitingTimer = nil
        iceRefreshTimer = nil
        
        if let serverURL, let sessionToken, let sessionID {
            let urlStr = "\(serverURL)/v3/channels/1/session"
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
        alert.informativeText = "Channel 1 is currently full (2 people connected). Please try again later."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
