import Foundation
import AppKit
import WebKit
import AVFoundation
import os.log

private let logger = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "Walkie")

@MainActor
final class WalkieTalkieAudioImpl: NSObject, WalkieAudioLayer, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = WalkieTalkieAudioImpl()
    
    private var window: NSWindow?
    private var webView: WKWebView?
    private var onIceCandidate: (@MainActor (String) -> Void)?
    private var onAnswer: (@MainActor (String) -> Void)?
    private var isPageReady = false
    private var pageReadyWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastLevelAt: Date?
    
    private override init() {
        super.init()
    }
    
    func checkMicPermission() async -> Bool {
        // Never await the Swift 6 async import of requestRecordPermission()
        // from @MainActor — Apple's completion runs on a background queue and
        // that import corrupts the current-task executor (later assumeIsolated SIGBUS).
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await Self.requestRecordPermissionIsolated()
        @unknown default:
            return await Self.requestRecordPermissionIsolated()
        }
    }

    /// Callback-based request. Apple's completion runs on a background queue;
    /// `CheckedContinuation` resumes exactly once, then the caller hops back to MainActor.
    nonisolated static func requestRecordPermissionIsolated() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    func setupWebView(
        onIceCandidate: @escaping @MainActor (String) -> Void,
        onAnswer: @escaping @MainActor (String) -> Void
    ) {
        guard webView == nil else { return }
        
        self.onIceCandidate = onIceCandidate
        self.onAnswer = onAnswer
        
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let contentController = WKUserContentController()
        contentController.add(self, name: "native")
        config.userContentController = contentController
        
        // Never KVC private WebKit keys: responds(to: setter) can be true while
        // setValue(_:forKey:) throws NSUnknownKeyException and unwinds a Swift
        // async frame (corrupts the executor; later assumeIsolated SIGBUS).
        if Self.applyPrivateBoolPreference(
            config.preferences,
            setterName: "_setGetUserMediaRequiresFocus:",
            value: false
        ) {
            logger.info("WKPreferences: applied _setGetUserMediaRequiresFocus: via perform")
        } else {
            logger.info("WKPreferences: _setGetUserMediaRequiresFocus: unsupported; offscreen front window fallback")
        }
        
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.uiDelegate = self
        wv.navigationDelegate = self
        isPageReady = false
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = wv
        win.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        win.alphaValue = 0.01
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        // Ordered front (not key) so getUserMedia can run while Coucou is an
        // unfocused LSUIElement. Real-Mac proof of background capture is pending.
        win.level = .floating
        win.orderFrontRegardless()
        
        self.window = win
        self.webView = wv
        
        wv.loadHTMLString(htmlContent, baseURL: URL(string: "https://localhost/"))
    }
    
    func setMicEnabled(_ enabled: Bool) {
        Task {
            do {
                _ = try await self.callPageJS("setMicEnabled(enabled); return true;", arguments: ["enabled": enabled])
            } catch {
                if case WalkieError.notInitialized = error { return }
                logger.error("setMicEnabled failed: \(self.jsErrorDescription(error), privacy: .public)")
            }
        }
    }
    
    func setOffer(_ offer: String, iceServers: [[String: Any]]) async throws -> String {
        do {
            let result = try await callPageJS(
                "return await handleOffer(offerJSON, iceServers)",
                arguments: ["offerJSON": offer, "iceServers": iceServers]
            )
            guard let answer = result as? String else {
                throw WalkieError.invalidAnswer
            }
            return answer
        } catch {
            logger.error("handleOffer failed: \(self.jsErrorDescription(error), privacy: .public)")
            throw error
        }
    }
    
    func createOffer(iceServers: [[String: Any]]) async throws -> String {
        do {
            let result = try await callPageJS(
                "return await createOffer(iceServers)",
                arguments: ["iceServers": iceServers]
            )
            guard let offer = result as? String else {
                throw WalkieError.invalidOffer
            }
            return offer
        } catch {
            logger.error("createOffer failed: \(self.jsErrorDescription(error), privacy: .public)")
            throw error
        }
    }
    
    func handleAnswer(_ answer: String) {
        Task {
            do {
                _ = try await self.callPageJS(
                    "handleAnswer(answerJSON)",
                    arguments: ["answerJSON": answer]
                )
            } catch {
                if case WalkieError.notInitialized = error { return }
                logger.error("handleAnswer failed: \(self.jsErrorDescription(error), privacy: .public)")
            }
        }
    }
    
    func addIceCandidate(_ candidate: String) {
        Task {
            do {
                _ = try await self.callPageJS(
                    "addIceCandidate(candidateJSON)",
                    arguments: ["candidateJSON": candidate]
                )
            } catch {
                if case WalkieError.notInitialized = error { return }
                logger.error("addIceCandidate failed: \(self.jsErrorDescription(error), privacy: .public)")
            }
        }
    }

    func probeCapture() async {
        guard await checkMicPermission() else {
            logger.info("probeMic skipped: mic permission not granted")
            return
        }
        do {
            let result = try await callPageJS("return await probeMic();", arguments: [:])
            logger.info("probeMic result: \(String(describing: result), privacy: .public)")
        } catch {
            logger.error("probeMic failed: \(self.jsErrorDescription(error), privacy: .public)")
        }
    }
    
    func cleanup() {
        let wv = webView
        isPageReady = false
        webView = nil
        finishPageReadyWaiters()
        lastLevelAt = nil
        WalkieIslandState.shared.applyLevels(local: 0, remote: 0)
        
        if let wv {
            Task {
                do {
                    _ = try await wv.callAsyncJavaScript("cleanup()", arguments: [:], contentWorld: .page)
                } catch {
                    logger.error("cleanup failed: \(self.jsErrorDescription(error), privacy: .public)")
                }
            }
        }
        
        wv?.navigationDelegate = nil
        wv?.stopLoading()
        wv?.loadHTMLString("", baseURL: nil)
        window?.orderOut(nil)
        window = nil
        onIceCandidate = nil
        onAnswer = nil
    }

    private func callPageJS(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        await waitUntilPageReady()
        guard let wv = webView else { throw WalkieError.notInitialized }
        return try await wv.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    private func waitUntilPageReady() async {
        if isPageReady || webView == nil { return }
        await withCheckedContinuation { continuation in
            if self.isPageReady || self.webView == nil {
                continuation.resume()
            } else {
                self.pageReadyWaiters.append(continuation)
            }
        }
    }

    private func markPageReady() {
        isPageReady = true
        finishPageReadyWaiters()
    }

    private func finishPageReadyWaiters() {
        let waiters = pageReadyWaiters
        pageReadyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func jsErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        let jsMessage = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String
        if let jsMessage, !jsMessage.isEmpty {
            return "\(nsError.localizedDescription): \(jsMessage)"
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let jsMessage = underlying.userInfo["WKJavaScriptExceptionMessage"] as? String,
           !jsMessage.isEmpty {
            return "\(nsError.localizedDescription): \(jsMessage)"
        }
        return nsError.localizedDescription
    }
    
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.markPageReady()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            logger.error("Walkie page load failed: \(self.jsErrorDescription(error), privacy: .public)")
            self.markPageReady()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            logger.error("Walkie page provisional load failed: \(self.jsErrorDescription(error), privacy: .public)")
            self.markPageReady()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let host = origin.host
        let kind = String(describing: type)
        let handler = decisionHandler
        // Grant on the main queue immediately — a cooperative Task hop can
        // outlive WebKit's permission request and hang getUserMedia.
        DispatchQueue.main.async {
            logger.info("Media capture permission: grant type=\(kind, privacy: .public) origin=\(host, privacy: .public)")
            handler(.grant)
        }
    }
    
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Read the message on this callback thread; WKScriptMessage is not Sendable.
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        let candidate = dict["candidate"] as? String
        let answer = dict["answer"] as? String
        let errorMessage = dict["message"] as? String
        let iceState = dict["state"] as? String
        let candidateType = dict["candidateType"] as? String
        let connectionState = dict["state"] as? String
        let levels = WalkieLevels.parse(dict)
        Task { @MainActor in
            self.handleMessage(
                type: type,
                candidate: candidate,
                answer: answer,
                errorMessage: errorMessage,
                iceState: iceState,
                candidateType: candidateType,
                connectionState: connectionState,
                levels: levels
            )
        }
    }
    
    /// Invoke a private WKPreferences BOOL setter via `perform`. Never KVC.
    private static func applyPrivateBoolPreference(
        _ preferences: WKPreferences,
        setterName: String,
        value: Bool
    ) -> Bool {
        let sel = NSSelectorFromString(setterName)
        guard preferences.responds(to: sel) else { return false }
        preferences.perform(sel, with: NSNumber(value: value))
        return true
    }

    private func handleMessage(type: String, candidate: String?, answer: String?, errorMessage: String?, iceState: String?, candidateType: String?, connectionState: String?, levels: (local: Double, remote: Double)?) {
        switch type {
        case "ice":
            if let candidate = candidate {
                self.onIceCandidate?(candidate)
            }
        case "answer":
            if let answer = answer {
                self.onAnswer?(answer)
            }
        case "error":
            if let errorMessage = errorMessage {
                logger.error("WebRTC JS error: \(errorMessage, privacy: .public)")
            }
        case "log":
            if let errorMessage = errorMessage {
                logger.info("Walkie JS: \(errorMessage, privacy: .public)")
            }
        case "consoleError":
            if let errorMessage = errorMessage {
                logger.error("JS console.error: \(errorMessage, privacy: .public)")
            }
        case "iceState":
            if let iceState = iceState {
                logger.info("ICE connection state: \(iceState, privacy: .public)")
            }
        case "connectionState":
            if let connectionState = connectionState {
                logger.info("Connection state: \(connectionState, privacy: .public)")
            }
        case "candidatePair":
            if let candidateType = candidateType {
                logger.info("Selected candidate pair type: \(candidateType, privacy: .public)")
            }
        case "levels":
            guard let levels,
                  WalkieLevels.shouldAccept(now: Date(), last: lastLevelAt) else { return }
            lastLevelAt = Date()
            WalkieIslandState.shared.applyLevels(local: levels.local, remote: levels.remote)
        default:
            break
        }
    }
    
    private var htmlContent: String {
        walkieTalkieHTML
    }
}

// Type alias for compatibility
typealias WalkieTalkieAudio = WalkieTalkieAudioImpl
