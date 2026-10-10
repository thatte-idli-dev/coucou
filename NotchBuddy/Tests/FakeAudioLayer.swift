import Foundation

/// Fake audio layer for testing walkie-talkie without WebView
@MainActor
final class FakeAudioLayer: WalkieAudioLayer {
    var onIceCandidate: ((String) -> Void)?
    var onAnswer: ((String) -> Void)?
    var micEnabled: Bool = false
    var setupCalled: Bool = false
    var cleanupCalled: Bool = false
    
    var shouldSimulateCallFlow: Bool = true
    var peerAudioLayer: FakeAudioLayer?
    
    private var localOffer: String?
    private var remoteOffer: String?
    private var localAnswer: String?
    
    func checkMicPermission() async -> Bool {
        return true
    }
    
    func setupWebView(onIceCandidate: @escaping (String) -> Void, onAnswer: @escaping (String) -> Void) {
        self.onIceCandidate = onIceCandidate
        self.onAnswer = onAnswer
        setupCalled = true
    }
    
    func setMicEnabled(_ enabled: Bool) {
        micEnabled = enabled
    }
    
    func createOffer(iceServers: [[String: Any]]) async throws -> String {
        let offer = """
        {"type":"offer","sdp":"v=0\\r\\no=- 123 2 IN IP4 127.0.0.1\\r\\ns=-\\r\\nt=0 0\\r\\na=msid-semantic: WMS\\r\\nm=audio 9 UDP/TLS/RTP/SAVPF 111\\r\\nc=IN IP4 0.0.0.0\\r\\na=ice-ufrag:test\\r\\na=ice-pwd:test123\\r\\na=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99\\r\\na=setup:actpass\\r\\na=mid:0\\r\\na=sendrecv\\r\\na=rtcp-mux\\r\\na=rtpmap:111 opus/48000/2\\r\\n"}
        """
        localOffer = offer
        
        if shouldSimulateCallFlow {
            // Simulate ICE candidate gathering
            Task {
                try? await Task.sleep(for: .milliseconds(10))
                let candidate = """
                {"candidate":"candidate:1 1 UDP 2130706431 192.168.1.100 51234 typ host","sdpMid":"0","sdpMLineIndex":0}
                """
                self.onIceCandidate?(candidate)
            }
        }
        
        return offer
    }
    
    func setOffer(_ offer: String, iceServers: [[String: Any]]) async throws -> String {
        remoteOffer = offer
        
        let answer = """
        {"type":"answer","sdp":"v=0\\r\\no=- 456 2 IN IP4 127.0.0.1\\r\\ns=-\\r\\nt=0 0\\r\\na=msid-semantic: WMS\\r\\nm=audio 9 UDP/TLS/RTP/SAVPF 111\\r\\nc=IN IP4 0.0.0.0\\r\\na=ice-ufrag:test2\\r\\na=ice-pwd:test456\\r\\na=fingerprint:sha-256 FF:EE:DD:CC:BB:AA:99:88:77:66:55:44:33:22:11:00:FF:EE:DD:CC:BB:AA:99:88:77:66:55:44:33:22:11:00\\r\\na=setup:active\\r\\na=mid:0\\r\\na=sendrecv\\r\\na=rtcp-mux\\r\\na=rtpmap:111 opus/48000/2\\r\\n"}
        """
        localAnswer = answer
        
        if shouldSimulateCallFlow {
            // Simulate ICE candidate gathering
            Task {
                try? await Task.sleep(for: .milliseconds(10))
                let candidate = """
                {"candidate":"candidate:1 1 UDP 2130706431 192.168.1.101 51235 typ host","sdpMid":"0","sdpMLineIndex":0}
                """
                self.onIceCandidate?(candidate)
            }
        }
        
        return answer
    }
    
    func handleAnswer(_ answer: String) {
        // Store remote answer
        // In a real WebRTC implementation this would complete the connection
    }
    
    func addIceCandidate(_ candidate: String) {
        // Store remote ICE candidate
        // In a real WebRTC implementation this would be added to the connection
    }
    
    func cleanup() {
        cleanupCalled = true
        micEnabled = false
        onIceCandidate = nil
        onAnswer = nil
        localOffer = nil
        remoteOffer = nil
        localAnswer = nil
    }
}
