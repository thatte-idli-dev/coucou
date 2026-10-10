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
        applyPrivateBoolPreference(configA.preferences, setterName: "_setAllowFileAccessFromFileURLs:", value: true)
        configA.userContentController.addUserScript(userScript)
        webViewA = WKWebView(frame: .zero, configuration: configA)
        delegateA = NavigationDelegate()
        webViewA.navigationDelegate = delegateA
        
        let configB = WKWebViewConfiguration()
        applyPrivateBoolPreference(configB.preferences, setterName: "_setAllowFileAccessFromFileURLs:", value: true)
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
        runCandidateBeforeOfferTest()
    }
    
    func runCandidateBeforeOfferTest() {
        print("📝 Test: Queue ICE candidate arriving before the offer")
        print("======================================================\n")
        
        let iceServers: [[String: Any]] = [
            ["urls": ["stun:stun.l.google.com:19302"]],
            ["urls": ["turn:turn.example.com:3478"], "username": "test", "credential": "secret"]
        ]
        
        let earlyCandidate = """
        {"candidate":"candidate:1 1 UDP 2130706431 192.168.1.100 51234 typ host","sdpMid":"0","sdpMLineIndex":0}
        """
        
        print("🔊 Feeding candidate to peer B before any offer...")
        webViewB.callAsyncJavaScript(
            "return await addIceCandidate(candidateJSON)",
            arguments: ["candidateJSON": earlyCandidate],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result {
                self.fail("addIceCandidate before offer failed: \(error)")
                return
            }
            
            self.webViewB.callAsyncJavaScript(
                "return getIceQueueStats()",
                arguments: [:],
                in: nil,
                in: .page
            ) { [weak self] statsResult in
                guard let self = self else { return }
                switch statsResult {
                case .success(let value):
                    guard let stats = Self.dictionary(value),
                          let pending = Self.intValue(stats["pending"]),
                          let applied = Self.intValue(stats["applied"]) else {
                        self.fail("getIceQueueStats returned unexpected value: \(String(describing: value))")
                        return
                    }
                    guard pending == 1, applied == 0 else {
                        self.fail("Candidate should be queued before offer (pending=\(pending), applied=\(applied))")
                        return
                    }
                    print("✓ Candidate queued before offer (pending=1, applied=0)\n")
                    self.createOfferThenFlushCandidate(iceServers: iceServers)
                case .failure(let error):
                    self.fail("getIceQueueStats failed: \(error)")
                }
            }
        }
    }
    
    func createOfferThenFlushCandidate(iceServers: [[String: Any]]) {
        print("🔊 Creating offer from peer A...")
        
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
                self.handleOfferAndAssertCandidateApplied(offerStr, iceServers: iceServers)
            case .failure(let error):
                self.fail("Failed to create offer: \(error)")
            }
        }
    }
    
    func handleOfferAndAssertCandidateApplied(_ offer: String, iceServers: [[String: Any]]) {
        print("🔊 Handling offer on peer B (should flush queued candidate)...")
        
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
                self.webViewB.callAsyncJavaScript(
                    "return getIceQueueStats()",
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { [weak self] statsResult in
                    guard let self = self else { return }
                    switch statsResult {
                    case .success(let statsValue):
                        guard let stats = Self.dictionary(statsValue),
                              let pending = Self.intValue(stats["pending"]),
                              let applied = Self.intValue(stats["applied"]) else {
                            self.fail("getIceQueueStats after offer returned unexpected value: \(String(describing: statsValue))")
                            return
                        }
                        guard pending == 0, applied >= 1 else {
                            self.fail("Queued candidate should be applied after offer (pending=\(pending), applied=\(applied))")
                            return
                        }
                        print("✓ Queued candidate applied after offer (pending=0, applied=\(applied))\n")
                        print("✅ ICE candidate-before-offer test passed\n")
                        self.runOfferAnswerTest(existingOffer: offer, existingAnswer: answerStr)
                    case .failure(let error):
                        self.fail("getIceQueueStats after offer failed: \(error)")
                    }
                }
            case .failure(let error):
                self.fail("Failed to handle offer: \(error)")
            }
        }
    }
    
    func runOfferAnswerTest(existingOffer: String, existingAnswer: String) {
        print("📝 Test: Offer/Answer SDP flow through JavaScript bridge")
        print("=========================================================\n")
        
        guard let data = existingOffer.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = json["sdp"] as? String,
              let type = json["type"] as? String,
              type == "offer",
              !sdp.isEmpty else {
            fail("Offer is not valid SDP JSON")
            return
        }
        
        print("✓ Peer A created offer:")
        print("  Type: \(type)")
        print("  SDP length: \(sdp.count) characters\n")
        
        guard let answerData = existingAnswer.data(using: .utf8),
              let answerJSON = try? JSONSerialization.jsonObject(with: answerData) as? [String: Any],
              let answerSDP = answerJSON["sdp"] as? String,
              let answerType = answerJSON["type"] as? String,
              answerType == "answer",
              !answerSDP.isEmpty else {
            fail("Answer is not valid SDP JSON")
            return
        }
        
        print("✓ Peer B created answer:")
        print("  Type: \(answerType)")
        print("  SDP length: \(answerSDP.count) characters\n")
        
        handleAnswer(existingAnswer)
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
    
    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }
    
    static func dictionary(_ any: Any?) -> [String: Any]? {
        if let d = any as? [String: Any] { return d }
        if let d = any as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, value) in d {
                if let key = key as? String {
                    result[key] = value
                }
            }
            return result
        }
        return nil
    }
}

/// Private WKPreferences setters must be invoked via `perform`, never KVC.
@MainActor
func applyPrivateBoolPreference(_ preferences: WKPreferences, setterName: String, value: Bool) {
    let sel = NSSelectorFromString(setterName)
    guard preferences.responds(to: sel) else { return }
    preferences.perform(sel, with: NSNumber(value: value))
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
