import Foundation
import AppKit
import WebKit

/// Test the real WebKit JavaScript bridge for WebRTC
/// This test loads the actual production HTML from WalkieTalkieAudioImpl and verifies:
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
        
        // Create user script to override getUserMedia with fake audio track
        let userScript = WKUserScript(
            source: """
            // Override getUserMedia to provide fake audio track (for CI)
            navigator.mediaDevices.getUserMedia = async function(constraints) {
                console.log('[Override] getUserMedia called with', constraints);
                const audioContext = new AudioContext();
                const oscillator = audioContext.createOscillator();
                const dest = audioContext.createMediaStreamDestination();
                oscillator.connect(dest);
                console.log('[Override] Returning fake audio stream');
                return dest.stream;
            };
            console.log('[Override] getUserMedia override installed');
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        
        // Create web views with the override
        let configA = WKWebViewConfiguration()
        configA.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configA.userContentController.addUserScript(userScript)
        webViewA = WKWebView(frame: .zero, configuration: configA)
        delegateA = NavigationDelegate()
        webViewA.navigationDelegate = delegateA
        
        let configB = WKWebViewConfiguration()
        configB.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configB.userContentController.addUserScript(userScript)
        webViewB = WKWebView(frame: .zero, configuration: configB)
        delegateB = NavigationDelegate()
        webViewB.navigationDelegate = delegateB
        
        // Load PRODUCTION HTML from shared constant
        let html = walkieTalkieHTML
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
