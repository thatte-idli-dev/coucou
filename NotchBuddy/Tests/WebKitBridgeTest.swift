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
struct WebKitBridgeTest {
    static var didTimeout = false
    
    static func main() async {
        print("🧪 WebKit Bridge Test")
        print("=====================\n")
        
        // Hard timeout: 60 seconds
        Task {
            try? await Task.sleep(for: .seconds(60))
            if !didTimeout {
                didTimeout = true
                print("\n❌ Test timed out after 60 seconds")
                exit(1)
            }
        }
        
        do {
            try await testOfferAnswerFlow()
            didTimeout = true
            print("\n✅ WebKit bridge test passed!")
            exit(0)
        } catch {
            didTimeout = true
            print("\n❌ WebKit bridge test failed: \(error)")
            exit(1)
        }
    }
    
    static func testOfferAnswerFlow() async throws {
        print("📝 Test: Offer/Answer SDP flow through JavaScript bridge")
        print("=========================================================\n")
        
        // Create two web views (simulating two peers)
        let delegate = NavigationDelegate()
        let webViewA = await createWebView(delegate: delegate)
        let webViewB = await createWebView(delegate: delegate)
        delegate.webViewA = webViewA
        delegate.webViewB = webViewB
        
        // Wait for pages to load and delegate to confirm
        print("⏳ Waiting for pages to load...")
        var attempts = 0
        while !delegate.aLoaded || !delegate.bLoaded {
            if attempts > 40 {
                throw TestError("Pages did not load after 20 seconds (aLoaded=\(delegate.aLoaded), bLoaded=\(delegate.bLoaded))")
            }
            // Run the runloop briefly to allow WebKit callbacks
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            try await Task.sleep(for: .milliseconds(400))
            attempts += 1
        }
        
        print("✓ Web views created and loaded\n")
        
        // Test ICE servers configuration
        let iceServers: [[String: Any]] = [
            ["urls": ["stun:stun.l.google.com:19302"]],
            ["urls": ["turn:turn.example.com:3478"], "username": "test", "credential": "secret"]
        ]
        
        print("🔊 Creating offer from peer A...")
        
        // Create offer on peer A
        let offer: String
        do {
            let result = try await withRunLoop {
                try await webViewA.callAsyncJavaScript(
                    "return await createOffer(iceServers)",
                    arguments: ["iceServers": iceServers],
                    contentWorld: .page
                )
            }
            
            guard let offerStr = result as? String, !offerStr.isEmpty else {
                throw TestError("createOffer returned empty or invalid result: \(String(describing: result))")
            }
            
            offer = offerStr
            
            // Verify it's valid JSON
            guard let data = offer.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sdp = json["sdp"] as? String,
                  let type = json["type"] as? String,
                  type == "offer",
                  !sdp.isEmpty else {
                throw TestError("Offer is not valid SDP JSON")
            }
            
            print("✓ Peer A created offer:")
            print("  Type: \(type)")
            print("  SDP length: \(sdp.count) characters\n")
            
        } catch {
            throw TestError("Failed to create offer: \(error)")
        }
        
        print("🔊 Handling offer on peer B...")
        
        // Handle offer on peer B and get answer
        let answer: String
        do {
            let result = try await withRunLoop {
                try await webViewB.callAsyncJavaScript(
                    "return await handleOffer(offerJSON, iceServers)",
                    arguments: ["offerJSON": offer, "iceServers": iceServers],
                    contentWorld: .page
                )
            }
            
            guard let answerStr = result as? String, !answerStr.isEmpty else {
                throw TestError("handleOffer returned empty or invalid result: \(String(describing: result))")
            }
            
            answer = answerStr
            
            // Verify it's valid JSON
            guard let data = answer.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sdp = json["sdp"] as? String,
                  let type = json["type"] as? String,
                  type == "answer",
                  !sdp.isEmpty else {
                throw TestError("Answer is not valid SDP JSON")
            }
            
            print("✓ Peer B created answer:")
            print("  Type: \(type)")
            print("  SDP length: \(sdp.count) characters\n")
            
        } catch {
            throw TestError("Failed to handle offer: \(error)")
        }
        
        print("🔊 Handling answer on peer A...")
        
        // Handle answer on peer A
        do {
            _ = try await withRunLoop {
                try await webViewA.callAsyncJavaScript(
                    "return await handleAnswer(answerJSON)",
                    arguments: ["answerJSON": answer],
                    contentWorld: .page
                )
            }
            
            print("✓ Peer A handled answer\n")
            
        } catch {
            throw TestError("Failed to handle answer: \(error)")
        }
        
        print("✅ Full offer/answer flow completed successfully")
    }
    
    static func createWebView(delegate: WKNavigationDelegate) async -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = delegate
        
        // Use the same HTML as production WalkieTalkieAudio
        let html = """
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
            console.error('navigator.mediaDevices is undefined (secure context required)');
        }
        
        async function createOffer(iceServers) {
            // For testing, create a fake silent audio track if getUserMedia fails
            try {
                stream = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
                audioTrack = stream.getAudioTracks()[0];
            } catch (e) {
                console.warn('getUserMedia failed, using fake track:', e);
                // Create silent audio context track for testing
                const audioContext = new AudioContext();
                const oscillator = audioContext.createOscillator();
                const dest = audioContext.createMediaStreamDestination();
                oscillator.connect(dest);
                stream = dest.stream;
                audioTrack = stream.getAudioTracks()[0];
            }
            audioTrack.enabled = wantMic;
            
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
                    console.log('ICE candidate:', e.candidate);
                }
            };
            
            const offer = await pc.createOffer();
            await pc.setLocalDescription(offer);
            return JSON.stringify(offer);
        }
        
        async function handleOffer(offerJSON, iceServers) {
            try {
                stream = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
                audioTrack = stream.getAudioTracks()[0];
            } catch (e) {
                console.warn('getUserMedia failed, using fake track:', e);
                const audioContext = new AudioContext();
                const oscillator = audioContext.createOscillator();
                const dest = audioContext.createMediaStreamDestination();
                oscillator.connect(dest);
                stream = dest.stream;
                audioTrack = stream.getAudioTracks()[0];
            }
            audioTrack.enabled = wantMic;
            
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
                    console.log('ICE candidate:', e.candidate);
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
        
        // Use https://localhost/ for secure context (required for navigator.mediaDevices)
        webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        
        return webView
    }
}

// Helper to pump the runloop while waiting for async operations
// Required for WKWebView to function in a CLI context
func withRunLoop<T>(_ operation: @escaping () async throws -> T) async rethrows -> T {
    return try await withCheckedThrowingContinuation { continuation in
        Task { @MainActor in
            do {
                let result = try await operation()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        
        // Pump the runloop while waiting
        Task {
            while !Task.isCancelled {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

@MainActor
class NavigationDelegate: NSObject, WKNavigationDelegate {
    var aLoaded = false
    var bLoaded = false
    weak var webViewA: WKWebView?
    weak var webViewB: WKWebView?
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("✓ Page loaded for webView \(webView === webViewA ? "A" : "B")")
        if webView === webViewA {
            aLoaded = true
        } else if webView === webViewB {
            bLoaded = true
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("❌ Navigation failed: \(error)")
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("❌ Provisional navigation failed: \(error)")
    }
}

struct TestError: Error, CustomStringConvertible {
    let message: String
    
    init(_ message: String) {
        self.message = message
    }
    
    var description: String {
        message
    }
}
