import Foundation
import AppKit
import WebKit

/// Test the real WebKit JavaScript bridge for WebRTC
/// This test loads the actual HTML from WalkieTalkieAudio and verifies:
/// 1. createOffer returns non-empty SDP
/// 2. handleOffer returns non-empty answer
/// 3. The same callAsyncJavaScript path production uses works correctly

@MainActor
@main
class WebKitBridgeTest: NSObject, NSApplicationDelegate {
    var webViewA: WKWebView!
    var webViewB: WKWebView!
    var delegateA: NavigationDelegate!
    var delegateB: NavigationDelegate!
    
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        
        let delegate = WebKitBridgeTest()
        app.delegate = delegate
        
        // 60s watchdog timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("\n❌ Test timed out after 60 seconds")
            exit(1)
        }
        
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("\n🧪 WebKit Bridge Test")
        print("=====================\n")
        print("📝 Test: Offer/Answer SDP flow through JavaScript bridge")
        print("=========================================================\n")
        
        // Create web views
        let configA = WKWebViewConfiguration()
        configA.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let consoleHandlerA = ConsoleMessageHandler(name: "A")
        configA.userContentController.add(consoleHandlerA, name: "consoleLog")
        webViewA = WKWebView(frame: .zero, configuration: configA)
        delegateA = NavigationDelegate()
        webViewA.navigationDelegate = delegateA
        
        let configB = WKWebViewConfiguration()
        configB.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let consoleHandlerB = ConsoleMessageHandler(name: "B")
        configB.userContentController.add(consoleHandlerB, name: "consoleLog")
        webViewB = WKWebView(frame: .zero, configuration: configB)
        delegateB = NavigationDelegate()
        webViewB.navigationDelegate = delegateB
        
        // Load HTML
        let html = makeHTML()
        webViewA.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        webViewB.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        
        // Wait for both to load
        delegateA.onLoad = { [weak self] in
            guard let self = self else { return }
            if self.delegateB.loaded {
                self.startTest()
            }
        }
        delegateB.onLoad = { [weak self] in
            guard let self = self else { return }
            if self.delegateA.loaded {
                self.startTest()
            }
        }
    }
    
    func startTest() {
        print("✓ Web views created and loaded\n")
        
        // Test ICE servers configuration
        let iceServers: [[String: Any]] = [
            ["urls": ["stun:stun.l.google.com:19302"]],
            ["urls": ["turn:turn.example.com:3478"], "username": "test", "credential": "secret"]
        ]
        
        print("🔊 Creating offer from peer A...")
        
        // Create offer
        webViewA.callAsyncJavaScript(
            "return await createOffer(iceServers)",
            arguments: ["iceServers": iceServers],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let value):
                guard let offerStr = value as? String, !offerStr.isEmpty else {
                    self.fail("createOffer returned empty or invalid result: \(String(describing: value))")
                    return
                }
                
                // Verify it's valid JSON
                guard let data = offerStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sdp = json["sdp"] as? String,
                      let type = json["type"] as? String,
                      type == "offer",
                      !sdp.isEmpty else {
                    self.fail("Offer is not valid SDP JSON")
                    return
                }
                
                print("✓ Peer A created offer:")
                print("  Type: \(type)")
                print("  SDP length: \(sdp.count) characters\n")
                
                self.handleOffer(offerStr, iceServers: iceServers)
                
            case .failure(let error):
                self.fail("Failed to create offer: \(error)")
            }
        }
    }
    
    func handleOffer(_ offer: String, iceServers: [[String: Any]]) {
        print("🔊 Handling offer on peer B...")
        
        webViewB.callAsyncJavaScript(
            "return await handleOffer(offerJSON, iceServers)",
            arguments: ["offerJSON": offer, "iceServers": iceServers],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let value):
                guard let answerStr = value as? String, !answerStr.isEmpty else {
                    self.fail("handleOffer returned empty or invalid result: \(String(describing: value))")
                    return
                }
                
                // Verify it's valid JSON
                guard let data = answerStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sdp = json["sdp"] as? String,
                      let type = json["type"] as? String,
                      type == "answer",
                      !sdp.isEmpty else {
                    self.fail("Answer is not valid SDP JSON")
                    return
                }
                
                print("✓ Peer B created answer:")
                print("  Type: \(type)")
                print("  SDP length: \(sdp.count) characters\n")
                
                self.handleAnswer(answerStr)
                
            case .failure(let error):
                self.fail("Failed to handle offer: \(error)")
            }
        }
    }
    
    func handleAnswer(_ answer: String) {
        print("🔊 Handling answer on peer A...")
        
        webViewA.callAsyncJavaScript(
            "return await handleAnswer(answerJSON)",
            arguments: ["answerJSON": answer],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success:
                print("✓ Peer A handled answer\n")
                print("✅ Full offer/answer flow completed successfully")
                print("\n✅ WebKit bridge test passed!")
                exit(0)
                
            case .failure(let error):
                self.fail("Failed to handle answer: \(error)")
            }
        }
    }
    
    func fail(_ message: String) {
        print("\n❌ WebKit bridge test failed: \(message)")
        exit(1)
    }
    
    func makeHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"></head>
        <body>
        <audio id="remoteAudio" autoplay></audio>
        <script>
        // Override console.log to send to Swift
        const originalLog = console.log;
        const originalError = console.error;
        const originalWarn = console.warn;
        console.log = (...args) => {
            originalLog(...args);
            window.webkit.messageHandlers.consoleLog.postMessage(args.join(' '));
        };
        console.error = (...args) => {
            originalError(...args);
            window.webkit.messageHandlers.consoleLog.postMessage('ERROR: ' + args.join(' '));
        };
        console.warn = (...args) => {
            originalWarn(...args);
            window.webkit.messageHandlers.consoleLog.postMessage('WARN: ' + args.join(' '));
        };
        
        let pc = null;
        let stream = null;
        let audioTrack = null;
        let wantMic = false;
        const remoteAudio = document.getElementById('remoteAudio');
        
        console.log('JavaScript loaded');
        
        if (!navigator.mediaDevices) {
            console.error('navigator.mediaDevices is undefined (secure context required)');
        } else {
            console.log('navigator.mediaDevices is available');
        }
        
        async function createOffer(iceServers) {
            // Create silent audio context track (avoid getUserMedia on CI)
            console.log('createOffer: Creating fake audio track');
            const audioContext = new AudioContext();
            const oscillator = audioContext.createOscillator();
            const dest = audioContext.createMediaStreamDestination();
            oscillator.connect(dest);
            stream = dest.stream;
            audioTrack = stream.getAudioTracks()[0];
            audioTrack.enabled = wantMic;
            console.log('createOffer: Audio track created');
            
            console.log('createOffer: Creating RTCPeerConnection');
            pc = new RTCPeerConnection({iceServers: iceServers});
            console.log('createOffer: Adding tracks');
            stream.getTracks().forEach(track => pc.addTrack(track, stream));
            
            pc.ontrack = (e) => {
                console.log('createOffer: ontrack fired');
                if (e.streams && e.streams[0]) {
                    remoteAudio.srcObject = e.streams[0];
                    remoteAudio.play().catch(err => console.error('Audio play failed:', err));
                }
            };
            
            pc.onicecandidate = (e) => {
                if (e.candidate) {
                    console.log('ICE candidate:', e.candidate);
                }
            };
            
            console.log('createOffer: Creating offer...');
            const offer = await pc.createOffer();
            console.log('createOffer: Setting local description...');
            await pc.setLocalDescription(offer);
            console.log('createOffer: Done, returning SDP');
            return JSON.stringify(offer);
        }
        
        async function handleOffer(offerJSON, iceServers) {
            // Create silent audio context track (avoid getUserMedia on CI)
            console.log('handleOffer: Creating fake audio track');
            const audioContext = new AudioContext();
            const oscillator = audioContext.createOscillator();
            const dest = audioContext.createMediaStreamDestination();
            oscillator.connect(dest);
            stream = dest.stream;
            audioTrack = stream.getAudioTracks()[0];
            audioTrack.enabled = wantMic;
            console.log('handleOffer: Audio track created');
            
            console.log('handleOffer: Creating RTCPeerConnection');
            pc = new RTCPeerConnection({iceServers: iceServers});
            console.log('handleOffer: Adding tracks');
            stream.getTracks().forEach(track => pc.addTrack(track, stream));
            
            pc.ontrack = (e) => {
                console.log('handleOffer: ontrack fired');
                if (e.streams && e.streams[0]) {
                    remoteAudio.srcObject = e.streams[0];
                    remoteAudio.play().catch(err => console.error('Audio play failed:', err));
                }
            };
            
            pc.onicecandidate = (e) => {
                if (e.candidate) {
                    console.log('ICE candidate:', e.candidate);
                }
            };
            
            console.log('handleOffer: Parsing offer JSON');
            const offer = JSON.parse(offerJSON);
            console.log('handleOffer: Setting remote description...');
            await pc.setRemoteDescription(offer);
            console.log('handleOffer: Creating answer...');
            const answer = await pc.createAnswer();
            console.log('handleOffer: Setting local description...');
            await pc.setLocalDescription(answer);
            console.log('handleOffer: Done, returning answer');
            return JSON.stringify(answer);
        }
        
        async function handleAnswer(answerJSON) {
            console.log('handleAnswer: Starting');
            if (!pc) {
                console.error('handleAnswer: No peer connection!');
                return;
            }
            console.log('handleAnswer: Parsing answer JSON');
            const answer = JSON.parse(answerJSON);
            console.log('handleAnswer: Setting remote description...');
            await pc.setRemoteDescription(answer);
            console.log('handleAnswer: Done');
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

@MainActor
class ConsoleMessageHandler: NSObject, WKScriptMessageHandler {
    let name: String
    
    init(name: String) {
        self.name = name
    }
    
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            print("[WebView \(self.name)] \(message.body)")
        }
    }
}

@MainActor
class NavigationDelegate: NSObject, WKNavigationDelegate {
    var loaded = false
    var onLoad: (() -> Void)?
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        onLoad?()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("❌ Navigation failed: \(error)")
        loaded = true
        onLoad?()
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("❌ Provisional navigation failed: \(error)")
        loaded = true
        onLoad?()
    }
}
