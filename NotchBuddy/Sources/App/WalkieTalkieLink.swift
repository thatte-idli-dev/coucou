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
    private var revision: Int = 0
    private var negotiationID: String?
    private var isSeatA: Bool = false
    private var peerTuned: Bool = false
    
    private var eventTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var waitingTimer: Task<Void, Never>?
    private var iceRefreshTimer: Task<Void, Never>?
    
    private var iceServers: [String] = []
    private var serverURL: String?
    private var accessCode: String?
    private var channelFull: Bool = false
    
    private var waitingAnimationToken: NSObject?
    
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
        self.serverURL = serverURL
        self.accessCode = accessCode
        
        if let url = serverURL, !url.isEmpty, let code = accessCode, !code.isEmpty {
            await connectIfNeeded()
        } else {
            await disconnect()
        }
    }
    
    private func connectIfNeeded() async {
        guard case .disconnected = state else { return }
        guard let serverURL, let accessCode, !serverURL.isEmpty, !accessCode.isEmpty else { return }
        
        channelFull = false
        state = .connected(tuned: false)
        
        await startEventStream()
    }
    
    private func startEventStream() async {
        eventTask?.cancel()
        
        guard let serverURL, let accessCode else { return }
        
        let baseURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = "\(baseURL)/v3/channels/1/events?access_code=\(accessCode)"
        guard let url = URL(string: urlStr) else { return }
        
        eventTask = Task {
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(from: url)
                    
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
        if line.hasPrefix("data: ") {
            let json = String(line.dropFirst(6))
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            if let eventType = dict["type"] as? String {
                switch eventType {
                case "snapshot":
                    if let sid = dict["session_id"] as? String {
                        sessionID = sid
                        revision = (dict["revision"] as? Int) ?? 0
                        isSeatA = (dict["seat"] as? String) == "A"
                    }
                    if let ice = dict["ice_servers"] as? [[String: Any]] {
                        iceServers = ice.compactMap { $0["urls"] as? String }
                    }
                    await startPresence()
                    
                case "state":
                    if let rev = dict["revision"] as? Int {
                        revision = rev
                    }
                    
                    let myTuned = isLocallyTuned()
                    
                    if let states = dict["states"] as? [[String: Any]] {
                        for s in states where (s["session_id"] as? String) != sessionID {
                            peerTuned = (s["tuned"] as? Bool) ?? false
                        }
                    }
                    
                    if myTuned && peerTuned {
                        if case .waiting = state {
                            await stopWaitingAnimation()
                        }
                        
                        if let negID = dict["negotiation_id"] as? String {
                            if negotiationID != negID {
                                negotiationID = negID
                                await startNegotiation()
                            }
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
            }
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
        guard let serverURL, let accessCode, let sessionID else { return }
        
        let tuned = isLocallyTuned()
        let transmitting: Bool
        if case .inCall(.pushToTalk(let t)) = state {
            transmitting = t
        } else {
            transmitting = false
        }
        
        let body: [String: Any] = [
            "session_id": sessionID,
            "revision": revision,
            "tuned": tuned,
            "transmitting": transmitting,
            "restart_negotiation": false
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        let urlStr = "\(serverURL)/v3/channels/1/presence?access_code=\(accessCode)"
        guard let url = URL(string: urlStr) else { return }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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
        
        WalkieTalkieAudio.shared.setupWebView(
            onIceCandidate: { [weak self] candidate in
                Task { await self?.sendIceCandidate(candidate) }
            },
            onAnswer: { [weak self] answer in
                Task { await self?.sendAnswer(answer) }
            }
        )
        
        if isSeatA {
            do {
                let offer = try await WalkieTalkieAudio.shared.createOffer(iceServers: iceServers)
                await sendOffer(offer)
            } catch {}
        }
        
        state = .inCall(mode: .pushToTalk(transmitting: false))
        await stopWaitingAnimation()
        await startICERefreshTimer()
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }
    
    private func handleSignalEvent(_ dict: [String: Any]) async {
        guard let fromSession = dict["from_session_id"] as? String,
              fromSession != sessionID else { return }
        
        if let offerJSON = dict["offer"] as? String, !isSeatA {
            do {
                let answer = try await WalkieTalkieAudio.shared.setOffer(offerJSON, iceServers: iceServers)
                await sendAnswer(answer)
            } catch {}
        }
        
        if let answerJSON = dict["answer"] as? String, isSeatA {
            WalkieTalkieAudio.shared.handleAnswer(answerJSON)
        }
        
        if let candidateJSON = dict["ice_candidate"] as? String {
            WalkieTalkieAudio.shared.addIceCandidate(candidateJSON)
        }
    }
    
    private func sendOffer(_ offer: String) async {
        await sendSignal(["offer": offer])
    }
    
    private func sendAnswer(_ answer: String) async {
        await sendSignal(["answer": answer])
    }
    
    private func sendIceCandidate(_ candidate: String) async {
        await sendSignal(["ice_candidate": candidate])
    }
    
    private func sendSignal(_ payload: [String: String]) async {
        guard let serverURL, let accessCode, let sessionID, let negotiationID else { return }
        
        var body: [String: Any] = [
            "session_id": sessionID,
            "negotiation_id": negotiationID
        ]
        body.merge(payload) { $1 }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        let urlStr = "\(serverURL)/v3/channels/1/signal?access_code=\(accessCode)"
        guard let url = URL(string: urlStr) else { return }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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
            
            WalkieTalkieAudio.shared.setupWebView(
                onIceCandidate: { [weak self] candidate in
                    Task { await self?.sendIceCandidate(candidate) }
                },
                onAnswer: { [weak self] answer in
                    Task { await self?.sendAnswer(answer) }
                }
            )
            await MainActor.run {
                WalkieTalkieAudio.shared.setMicEnabled(true)
            }
            
            state = .waiting(started: Date())
            await sendPresence()
            await startWaitingTimer()
            await startWaitingAnimation()
            
        case .waiting:
            if case .waiting(started: _) = state {
                state = .waiting(started: Date())
                await MainActor.run {
                    WalkieTalkieAudio.shared.setMicEnabled(true)
                }
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
            
            WalkieTalkieAudio.shared.setupWebView(
                onIceCandidate: { [weak self] candidate in
                    Task { await self?.sendIceCandidate(candidate) }
                },
                onAnswer: { [weak self] answer in
                    Task { await self?.sendAnswer(answer) }
                }
            )
            await MainActor.run {
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
        SoundEngine.shared.play("greet")
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
    
    private func startICERefreshTimer() async {
        iceRefreshTimer?.cancel()
        
        iceRefreshTimer = Task {
            try? await Task.sleep(for: .seconds(45 * 60))
            if !Task.isCancelled {
                await refreshICE()
            }
        }
    }
    
    private func refreshICE() async {
        guard let serverURL, let accessCode else { return }
        
        let urlStr = "\(serverURL)/v3/channels/1/ice?access_code=\(accessCode)"
        guard let url = URL(string: urlStr) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ice = dict["ice_servers"] as? [[String: Any]] {
                iceServers = ice.compactMap { $0["urls"] as? String }
            }
        } catch {}
        
        await startICERefreshTimer()
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
        
        if let serverURL, let accessCode, let sessionID {
            let urlStr = "\(serverURL)/v3/channels/1/session/\(sessionID)?access_code=\(accessCode)"
            if let url = URL(string: urlStr) {
                var req = URLRequest(url: url)
                req.httpMethod = "DELETE"
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        
        sessionID = nil
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
