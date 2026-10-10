import Foundation
import AppKit
import WebKit
import AVFoundation
import os.log

private let logger = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "Walkie")

enum WalkieTalkieScheme {
    static let name = "coucou-walkie"
    static let pageURL = URL(string: "coucou-walkie://audio/index.html")!
    static let mediaCaptureSelector = NSSelectorFromString(
        "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"
    )
}

/// Serves the walkie page from a real custom-scheme origin so WebKit treats
/// it as a capture-capable secure context. `loadHTMLString` + `https://localhost`
/// does not (the permission delegate never fires).
final class WalkieTalkieSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let requestURL = urlSchemeTask.request.url ?? WalkieTalkieScheme.pageURL
        let path = requestURL.path
        let serveHTML = path.isEmpty || path == "/" || path.hasSuffix("index.html") || path.hasSuffix("/audio")
        if serveHTML {
            let data = Data(walkieTalkieHTML.utf8)
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Length": "\(data.count)",
                    "Cache-Control": "no-store"
                ]
            ) ?? URLResponse(
                url: requestURL,
                mimeType: "text/html",
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }
        let empty = HTTPURLResponse(
            url: requestURL,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        ) ?? URLResponse(url: requestURL, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(empty)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Dedicated nonisolated NSObject so Swift 6 `@MainActor` isolation cannot
/// drop the ObjC selector WebKit uses for media capture.
final class WalkieTalkieWebViewUIDelegate: NSObject, WKUIDelegate {
    @objc(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host
        let scheme = origin.protocol
        let kind = String(describing: type)
        logger.info("Media capture permission: entered type=\(kind, privacy: .public) origin=\(host, privacy: .public) scheme=\(scheme, privacy: .public)")
        decisionHandler(.grant)
        logger.info("Media capture permission: grant type=\(kind, privacy: .public) origin=\(host, privacy: .public)")
    }
}

@MainActor
final class WalkieTalkieAudioImpl: NSObject, WalkieAudioLayer, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = WalkieTalkieAudioImpl()

    private var window: NSWindow?
    private var webView: WKWebView?
    /// Strong retain — WKWebView.uiDelegate is weak.
    private var mediaUIDelegate: WalkieTalkieWebViewUIDelegate?
    private var schemeHandler: WalkieTalkieSchemeHandler?
    private var onIceCandidate: (@MainActor (String) -> Void)?
    private var onAnswer: (@MainActor (String) -> Void)?
    private var isPageReady = false
    private var pageReadyWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastLevelAt: Date?
    private var occlusionObserver: NSObjectProtocol?
    private var restoredActivationPolicy: NSApplication.ActivationPolicy?
    private(set) var lastProbeDescription = "not-run"

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

        let handler = WalkieTalkieSchemeHandler()
        self.schemeHandler = handler

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(handler, forURLScheme: WalkieTalkieScheme.name)
        let contentController = WKUserContentController()
        contentController.add(self, name: "native")
        config.userContentController = contentController

        // Never KVC private WebKit keys: responds(to: setter) can be true while
        // setValue(_:forKey:) throws NSUnknownKeyException and unwinds a Swift
        // async frame (corrupts the executor; later assumeIsolated SIGBUS).
        if Self.applyPrivateBool(
            config.preferences,
            setterName: "_setGetUserMediaRequiresFocus:",
            value: false
        ) {
            logger.info("WKPreferences: applied _setGetUserMediaRequiresFocus: via perform")
        } else {
            logger.info("WKPreferences: _setGetUserMediaRequiresFocus: unsupported; on-screen window fallback")
        }
        if Self.applyPrivateBool(config.preferences, setterName: "_setMediaCaptureEnabled:", value: true) {
            logger.info("WKPreferences: applied _setMediaCaptureEnabled: via perform")
        }

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        let uiDelegate = WalkieTalkieWebViewUIDelegate()
        self.mediaUIDelegate = uiDelegate
        wv.uiDelegate = uiDelegate
        wv.navigationDelegate = self
        isPageReady = false

        let responds = uiDelegate.responds(to: WalkieTalkieScheme.mediaCaptureSelector)
        logger.info("WK uiDelegate set before load respondsToMediaCapture=\(responds, privacy: .public) uiDelegateNil=\(wv.uiDelegate == nil, privacy: .public)")
        if !responds {
            logger.error("WK uiDelegate does not respond to webView:requestMediaCapturePermissionForOrigin:... — getUserMedia will hang")
        }

        if Self.applyPrivateBool(wv, setterName: "_setMediaCaptureEnabled:", value: true) {
            logger.info("WKWebView: applied _setMediaCaptureEnabled: via perform")
        }

        let win = Self.makeCaptureWindow(content: wv)
        self.window = win
        self.webView = wv
        self.observeOcclusion(win)
        self.logWindowState(context: "setup")
        self.logActivationPolicy(context: "setup")

        wv.load(URLRequest(url: WalkieTalkieScheme.pageURL))
        logger.info("Walkie page load \(WalkieTalkieScheme.pageURL.absoluteString, privacy: .public)")
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
            lastProbeDescription = "skipped:mic-denied"
            logger.info("probeMic skipped: mic permission not granted")
            return
        }
        logWindowState(context: "probe-before")
        logActivationPolicy(context: "probe-before")
        let first = await runProbeMic()
        lastProbeDescription = first
        logger.info("probeMic result: \(first, privacy: .public)")
        if first.hasPrefix("ok") { return }

        // Smallest no-deps fallback if accessory/LSUIElement is what blocks
        // WK getUserMedia: become a regular app for the rest of the session.
        let current = NSApp.activationPolicy()
        if current != .regular {
            adoptRegularActivation(reason: "probeMic retry after \(first)")
            window?.orderFrontRegardless()
            logWindowState(context: "probe-regular")
            let second = await runProbeMic()
            lastProbeDescription = "retry-regular:\(second)"
            logger.info("probeMic result after regular: \(second, privacy: .public)")
            if second.hasPrefix("ok") {
                logger.info("probeMic: getUserMedia works only after activationPolicy=.regular — keeping regular until cleanup")
                return
            }
            restoreActivationPolicyIfNeeded()
            logger.error("probeMic: getUserMedia failed in accessory and regular. If Media capture permission: entered was never logged, WK is not calling the UI delegate. Smallest native alternative: keep NSApp.setActivationPolicy(.regular) for the call, or capture with AVAudioEngine and drop WK getUserMedia (no third-party WebRTC).")
        } else {
            logger.error("probeMic: getUserMedia failed while already regular (\(first, privacy: .public)). If Media capture permission: entered was never logged, WK is not calling the UI delegate.")
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
        wv?.uiDelegate = nil
        wv?.stopLoading()
        wv?.loadHTMLString("", baseURL: nil)
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        window?.orderOut(nil)
        window = nil
        mediaUIDelegate = nil
        schemeHandler = nil
        onIceCandidate = nil
        onAnswer = nil
        restoreActivationPolicyIfNeeded()
    }

    private func runProbeMic() async -> String {
        do {
            let result = try await callPageJS("return await probeMic();", arguments: [:])
            if let text = result as? String { return text }
            if let number = result as? NSNumber { return number.boolValue ? "ok" : "fail:false" }
            if let flag = result as? Bool { return flag ? "ok" : "fail:false" }
            return "ok:\(String(describing: result))"
        } catch {
            return "fail:\(jsErrorDescription(error))"
        }
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

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "nil"
        Task { @MainActor in
            logger.info("Walkie page didCommit url=\(url, privacy: .public)")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "nil"
        Task { @MainActor in
            logger.info("Walkie page didFinish url=\(url, privacy: .public)")
            self.logWindowState(context: "didFinish")
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

    /// Invoke a private BOOL setter via `perform`. Never KVC.
    private static func applyPrivateBool(
        _ target: NSObject,
        setterName: String,
        value: Bool
    ) -> Bool {
        let sel = NSSelectorFromString(setterName)
        guard target.responds(to: sel) else { return false }
        target.perform(sel, with: NSNumber(value: value))
        return true
    }

    private static func makeCaptureWindow(content: NSView) -> NSWindow {
        let size = NSSize(width: 2, height: 2)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let origin: NSPoint
        if let screen {
            origin = NSPoint(x: screen.visibleFrame.minX + 1, y: screen.visibleFrame.minY + 1)
        } else {
            origin = .zero
        }
        let win = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = content
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.alphaValue = 0.01
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        win.level = .floating
        win.setFrame(NSRect(origin: origin, size: size), display: true)
        win.orderFrontRegardless()
        return win
    }

    private func observeOcclusion(_ win: NSWindow) {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: win,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            let visible = window.isVisible
            let occlusion = window.occlusionState.contains(.visible)
            Task { @MainActor in
                guard let self else { return }
                logger.info("Walkie window occlusion changed isVisible=\(visible, privacy: .public) occlusionVisible=\(occlusion, privacy: .public)")
                self.logWindowState(context: "occlusion")
            }
        }
    }

    private func logWindowState(context: String) {
        guard let win = window else {
            logger.info("Walkie window (\(context, privacy: .public)): nil")
            return
        }
        let visible = win.isVisible
        let occlusionVisible = win.occlusionState.contains(.visible)
        let frame = NSStringFromRect(win.frame)
        let url = webView?.url?.absoluteString ?? "nil"
        let hasSuperview = webView?.superview != nil
        logger.info("Walkie window (\(context, privacy: .public)): isVisible=\(visible, privacy: .public) occlusionVisible=\(occlusionVisible, privacy: .public) frame=\(frame, privacy: .public) alpha=\(win.alphaValue, privacy: .public) url=\(url, privacy: .public) inViewHierarchy=\(hasSuperview, privacy: .public)")
    }

    private func logActivationPolicy(context: String) {
        let policy = String(describing: NSApp.activationPolicy())
        logger.info("activationPolicy (\(context, privacy: .public)): \(policy, privacy: .public)")
    }

    private func adoptRegularActivation(reason: String) {
        let current = NSApp.activationPolicy()
        logger.info("activationPolicy adopt regular from \(String(describing: current), privacy: .public) reason=\(reason, privacy: .public)")
        guard current != .regular else { return }
        if restoredActivationPolicy == nil {
            restoredActivationPolicy = current
        }
        let ok = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("activationPolicy → regular ok=\(ok, privacy: .public)")
    }

    private func restoreActivationPolicyIfNeeded() {
        guard let previous = restoredActivationPolicy else { return }
        restoredActivationPolicy = nil
        _ = NSApp.setActivationPolicy(previous)
        logger.info("activationPolicy restored \(String(describing: previous), privacy: .public)")
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
}

// Type alias for compatibility
typealias WalkieTalkieAudio = WalkieTalkieAudioImpl
