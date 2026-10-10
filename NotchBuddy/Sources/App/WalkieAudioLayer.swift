import Foundation

/// Audio layer protocol for walkie-talkie WebRTC functionality.
/// Allows injection of fake implementations for testing.
@MainActor
protocol WalkieAudioLayer {
    func checkMicPermission() async -> Bool
    func setupWebView(
        onIceCandidate: @escaping @MainActor (String) -> Void,
        onAnswer: @escaping @MainActor (String) -> Void
    )
    func setMicEnabled(_ enabled: Bool)
    func setOffer(_ offer: String, iceServers: [[String: Any]]) async throws -> String
    func createOffer(iceServers: [[String: Any]]) async throws -> String
    func handleAnswer(_ answer: String)
    func addIceCandidate(_ candidate: String)
    func probeCapture() async
    func cleanup()
}

enum WalkieError: Error {
    case notInitialized
    case invalidAnswer
    case invalidOffer
    case webRTCError(String)
}
