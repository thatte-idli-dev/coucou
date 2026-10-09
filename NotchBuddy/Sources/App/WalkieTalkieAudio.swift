import Foundation
import AppKit
import WebKit
import AVFoundation

final class WalkieTalkieAudio: NSObject, WKUIDelegate, WKScriptMessageHandler, @unchecked Sendable {
    static let shared = WalkieTalkieAudio()
    
    private var window: NSWindow?
    private var webView: WKWebView?
    private var onIceCandidate: ((String) -> Void)?
    private var onAnswer: ((String) -> Void)?
    
    private override init() {
        super.init()
    }
    
    func checkMicPermission() async -> Bool {
        return await AVAudioApplication.requestRecordPermission()
    }
    
    func setupWebView(onIceCandidate: @escaping (String) -> Void, onAnswer: @escaping (String) -> Void) {
        guard webView == nil else { return }
        
        self.onIceCandidate = onIceCandidate
        self.onAnswer = onAnswer
        
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let contentController = WKUserContentController()
        contentController.add(self, name: "native")
        config.userContentController = contentController
        
        let prefs = WKWebPreferences()
        config.preferences = prefs
        
        // PRIVATE WEBKIT API: _getUserMediaRequiresFocus
        // This is a private WebKit preference that allows getUserMedia to work
        // without the WKWebView being in a focused window. This is acceptable
        // for the direct NotchBuddy build (not App Store) where we need
        // immediate mic access on hotkey press while running as LSUIElement.
        // The alternative would be to require the stasel/WebRTC.swift package.
        if prefs.responds(to: Selector(("_setGetUserMediaRequiresFocus:"))) {
            prefs.setValue(false, forKey: "_getUserMediaRequiresFocus")
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
        
        wv.loadHTMLString(htmlContent, baseURL: nil)
    }
    
    func setMicEnabled(_ enabled: Bool) {
        webView?.evaluateJavaScript("setMicEnabled(\(enabled))") { _, _ in }
    }
    
    func setOffer(_ offer: String, iceServers: [String]) async throws -> String {
        guard let wv = webView else { throw WalkieError.notInitialized }
        
        let iceJSON = try! JSONSerialization.data(withJSONObject: iceServers.map { ["urls": $0] })
        let iceStr = String(data: iceJSON, encoding: .utf8)!
        let offerEscaped = offer.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        
        return try await withCheckedThrowingContinuation { continuation in
            wv.evaluateJavaScript("handleOffer('\(offerEscaped)', \(iceStr))") { result, error in
                if let err = error {
                    continuation.resume(throwing: err)
                } else if let answer = result as? String {
                    continuation.resume(returning: answer)
                } else {
                    continuation.resume(throwing: WalkieError.invalidAnswer)
                }
            }
        }
    }
    
    func createOffer(iceServers: [String]) async throws -> String {
        guard let wv = webView else { throw WalkieError.notInitialized }
        
        let iceJSON = try! JSONSerialization.data(withJSONObject: iceServers.map { ["urls": $0] })
        let iceStr = String(data: iceJSON, encoding: .utf8)!
        
        return try await withCheckedThrowingContinuation { continuation in
            wv.evaluateJavaScript("createOffer(\(iceStr))") { result, error in
                if let err = error {
                    continuation.resume(throwing: err)
                } else if let offer = result as? String {
                    continuation.resume(returning: offer)
                } else {
                    continuation.resume(throwing: WalkieError.invalidOffer)
                }
            }
        }
    }
    
    func handleAnswer(_ answer: String) {
        let escaped = answer.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        webView?.evaluateJavaScript("handleAnswer('\(escaped)')") { _, _ in }
    }
    
    func addIceCandidate(_ candidate: String) {
        let escaped = candidate.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        webView?.evaluateJavaScript("addIceCandidate('\(escaped)')") { _, _ in }
    }
    
    func teardown() {
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
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }
    
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        
        Task { @MainActor in
            switch type {
            case "ice":
                if let candidate = dict["candidate"] as? String {
                    self.onIceCandidate?(candidate)
                }
            case "answer":
                if let answer = dict["answer"] as? String {
                    self.onAnswer?(answer)
                }
            default:
                break
            }
        }
    }
    
    private var htmlContent: String {
        """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"></head>
        <body>
        <script>
        let pc = null;
        let stream = null;
        let audioTrack = null;
        
        async function createOffer(iceServers) {
            if (!stream) {
                stream = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
                audioTrack = stream.getAudioTracks()[0];
                audioTrack.enabled = false;
            }
            
            pc = new RTCPeerConnection({iceServers: iceServers});
            stream.getTracks().forEach(track => pc.addTrack(track, stream));
            
            pc.onicecandidate = (e) => {
                if (e.candidate) {
                    window.webkit.messageHandlers.native.postMessage({
                        type: 'ice',
                        candidate: JSON.stringify(e.candidate.toJSON())
                    });
                }
            };
            
            const offer = await pc.createOffer();
            await pc.setLocalDescription(offer);
            return JSON.stringify(offer);
        }
        
        async function handleOffer(offerJSON, iceServers) {
            if (!stream) {
                stream = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
                audioTrack = stream.getAudioTracks()[0];
                audioTrack.enabled = false;
            }
            
            pc = new RTCPeerConnection({iceServers: iceServers});
            stream.getTracks().forEach(track => pc.addTrack(track, stream));
            
            pc.onicecandidate = (e) => {
                if (e.candidate) {
                    window.webkit.messageHandlers.native.postMessage({
                        type: 'ice',
                        candidate: JSON.stringify(e.candidate.toJSON())
                    });
                }
            };
            
            const offer = JSON.parse(offerJSON);
            await pc.setRemoteDescription(offer);
            const answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);
            return JSON.stringify(answer);
        }
        
        async function handleAnswer(answerJSON) {
            if (!pc) return;
            const answer = JSON.parse(answerJSON);
            await pc.setRemoteDescription(answer);
        }
        
        async function addIceCandidate(candidateJSON) {
            if (!pc) return;
            const candidate = JSON.parse(candidateJSON);
            await pc.addIceCandidate(candidate);
        }
        
        function setMicEnabled(enabled) {
            if (audioTrack) {
                audioTrack.enabled = enabled;
            }
        }
        </script>
        </body>
        </html>
        """
    }
}

enum WalkieError: Error {
    case notInitialized
    case invalidOffer
    case invalidAnswer
}
