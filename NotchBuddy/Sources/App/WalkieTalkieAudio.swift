import Foundation
import AppKit
import WebKit
import AVFoundation
import os.log

private let logger = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "WalkieTalkieAudio")

@MainActor
final class WalkieTalkieAudioImpl: NSObject, WalkieAudioLayer, WKUIDelegate, WKScriptMessageHandler {
    static let shared = WalkieTalkieAudioImpl()
    
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
                try await wv.callAsyncJavaScript("setMicEnabled(enabled)", arguments: ["enabled": enabled], contentWorld: .page)
            } catch {
                logger.error("setMicEnabled failed: \(error.localizedDescription)")
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
            logger.error("handleOffer failed: \(error.localizedDescription)")
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
            logger.error("createOffer failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    func handleAnswer(_ answer: String) {
        guard let wv = webView else { return }
        Task {
            do {
                try await wv.callAsyncJavaScript(
                    "handleAnswer(answerJSON)",
                    arguments: ["answerJSON": answer],
                    contentWorld: .page
                )
            } catch {
                logger.error("handleAnswer failed: \(error.localizedDescription)")
            }
        }
    }
    
    func addIceCandidate(_ candidate: String) {
        guard let wv = webView else { return }
        Task {
            do {
                try await wv.callAsyncJavaScript(
                    "addIceCandidate(candidateJSON)",
                    arguments: ["candidateJSON": candidate],
                    contentWorld: .page
                )
            } catch {
                logger.error("addIceCandidate failed: \(error.localizedDescription)")
            }
        }
    }
    
    func cleanup() {
        guard let wv = webView else { return }
        Task {
            do {
                try await wv.callAsyncJavaScript("cleanup()", arguments: [:], contentWorld: .page)
            } catch {
                logger.error("cleanup failed: \(error.localizedDescription)")
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
    
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }
    
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        
        let candidate = dict["candidate"] as? String
        let answer = dict["answer"] as? String
        let errorMessage = dict["message"] as? String
        
        Task { @MainActor in
            self.handleMessage(type: type, candidate: candidate, answer: answer, errorMessage: errorMessage)
        }
    }
    
    private func handleMessage(type: String, candidate: String?, answer: String?, errorMessage: String?) {
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
                logger.error("WebRTC error: \(errorMessage)")
            }
        default:
            break
        }
    }
    
    private var htmlContent: String {
        """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"></head>
        <body>
        <audio id="remoteAudio" autoplay></audio>
        <script>
        let pc = null;
        let stream = null;
        let audioTrack = null;
        let wantMic = false;
        const remoteAudio = document.getElementById('remoteAudio');
        
        if (!navigator.mediaDevices) {
            window.webkit.messageHandlers.native.postMessage({
                type: 'error',
                message: 'navigator.mediaDevices is undefined (secure context required)'
            });
        }
        
        async function createOffer(iceServers) {
            if (!stream) {
                stream = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
                audioTrack = stream.getAudioTracks()[0];
                audioTrack.enabled = wantMic;
            }
            
            pc = new RTCPeerConnection({iceServers: iceServers});
            stream.getTracks().forEach(track => pc.addTrack(track, stream));
            
            pc.ontrack = (e) => {
                if (e.streams && e.streams[0]) {
                    remoteAudio.srcObject = e.streams[0];
                    remoteAudio.play().catch(err => console.error('Audio play failed:', err));
                }
            };
            
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
                audioTrack.enabled = wantMic;
            }
            
            pc = new RTCPeerConnection({iceServers: iceServers});
            stream.getTracks().forEach(track => pc.addTrack(track, stream));
            
            pc.ontrack = (e) => {
                if (e.streams && e.streams[0]) {
                    remoteAudio.srcObject = e.streams[0];
                    remoteAudio.play().catch(err => console.error('Audio play failed:', err));
                }
            };
            
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
            wantMic = enabled;
            if (audioTrack) {
                audioTrack.enabled = enabled;
            }
        }
        
        function cleanup() {
            if (pc) {
                pc.close();
                pc = null;
            }
            if (stream) {
                stream.getTracks().forEach(track => track.stop());
                stream = null;
                audioTrack = null;
            }
            if (remoteAudio.srcObject) {
                remoteAudio.srcObject.getTracks().forEach(track => track.stop());
                remoteAudio.srcObject = null;
            }
        }
        </script>
        </body>
        </html>
        """
    }
}

// Type alias for compatibility
typealias WalkieTalkieAudio = WalkieTalkieAudioImpl
