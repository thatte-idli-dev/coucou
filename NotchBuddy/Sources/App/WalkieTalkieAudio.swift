import Foundation
import AppKit
import WebKit
import AVFoundation
import os.log

private let logger = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "Walkie")

@MainActor
final class WalkieTalkieAudioImpl: NSObject, WalkieAudioLayer, WKUIDelegate, WKScriptMessageHandler {
    static let shared = WalkieTalkieAudioImpl()
    
    private var window: NSWindow?
    private var webView: WKWebView?
    private var onIceCandidate: (@MainActor (String) -> Void)?
    private var onAnswer: (@MainActor (String) -> Void)?
    
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
        
        // PRIVATE WEBKIT API: _getUserMediaRequiresFocus
        if config.preferences.responds(to: Selector(("_setGetUserMediaRequiresFocus:"))) {
            config.preferences.setValue(false, forKey: "_getUserMediaRequiresFocus")
        }
        
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.uiDelegate = self
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = wv
        win.alphaValue = 0.01
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        win.orderBack(nil)
        
        self.window = win
        self.webView = wv
        
        wv.loadHTMLString(htmlContent, baseURL: URL(string: "https://localhost/"))
    }
    
    func setMicEnabled(_ enabled: Bool) {
        guard let wv = webView else { return }
        Task {
            do {
                _ = try await wv.callAsyncJavaScript("setMicEnabled(enabled)", arguments: ["enabled": enabled], contentWorld: .page)
            } catch {
                logger.error("setMicEnabled failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func setOffer(_ offer: String, iceServers: [[String: Any]]) async throws -> String {
        guard let wv = webView else { throw WalkieError.notInitialized }
        
        do {
            let result = try await wv.callAsyncJavaScript(
                "return await handleOffer(offerJSON, iceServers)",
                arguments: ["offerJSON": offer, "iceServers": iceServers],
                contentWorld: .page
            )
            
            guard let answer = result as? String else {
                throw WalkieError.invalidAnswer
            }
            return answer
        } catch {
            logger.error("handleOffer failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    func createOffer(iceServers: [[String: Any]]) async throws -> String {
        guard let wv = webView else { throw WalkieError.notInitialized }
        
        do {
            let result = try await wv.callAsyncJavaScript(
                "return await createOffer(iceServers)",
                arguments: ["iceServers": iceServers],
                contentWorld: .page
            )
            
            guard let offer = result as? String else {
                throw WalkieError.invalidOffer
            }
            return offer
        } catch {
            logger.error("createOffer failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    func handleAnswer(_ answer: String) {
        guard let wv = webView else { return }
        Task {
            do {
                _ = try await wv.callAsyncJavaScript(
                    "handleAnswer(answerJSON)",
                    arguments: ["answerJSON": answer],
                    contentWorld: .page
                )
            } catch {
                logger.error("handleAnswer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func addIceCandidate(_ candidate: String) {
        guard let wv = webView else { return }
        Task {
            do {
                _ = try await wv.callAsyncJavaScript(
                    "addIceCandidate(candidateJSON)",
                    arguments: ["candidateJSON": candidate],
                    contentWorld: .page
                )
            } catch {
                logger.error("addIceCandidate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func cleanup() {
        guard let wv = webView else { return }
        Task {
            do {
                _ = try await wv.callAsyncJavaScript("cleanup()", arguments: [:], contentWorld: .page)
            } catch {
                logger.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        window?.orderOut(nil)
        webView = nil
        window = nil
        onIceCandidate = nil
        onAnswer = nil
    }
    
    nonisolated func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let handler = decisionHandler
        Task { @MainActor in
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
        Task { @MainActor in
            self.handleMessage(
                type: type,
                candidate: candidate,
                answer: answer,
                errorMessage: errorMessage,
                iceState: iceState,
                candidateType: candidateType,
                connectionState: connectionState
            )
        }
    }
    
    private func handleMessage(type: String, candidate: String?, answer: String?, errorMessage: String?, iceState: String?, candidateType: String?, connectionState: String?) {
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
