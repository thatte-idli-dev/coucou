import Foundation
import AppKit

// Test stubs for app-only symbols referenced by WalkieTalkieLink

extension NSNotification.Name {
    static let walkiePTTDown = NSNotification.Name("walkiePTTDown")
    static let walkiePTTUp = NSNotification.Name("walkiePTTUp")
    static let walkieDoubleTap = NSNotification.Name("walkieDoubleTap")
    static let walkieTap = NSNotification.Name("walkieTap")
    static let triggerEmote = NSNotification.Name("triggerEmote")
    static let botGreet = NSNotification.Name("botGreet")
    static let hookReveal = NSNotification.Name("hookReveal")
}

@MainActor
final class WalkieIslandState {
    static let shared = WalkieIslandState()
    func apply(_ state: WalkieState) {}
    func applyChannelFull() {}
}

enum BotEmote: String {
    case happy
}

@MainActor
final class SoundEngine {
    static let shared = SoundEngine()
    private init() {}
    
    func play(_ sound: String) {
        // No-op in tests
    }
}

// Stub for WalkieTalkieAudio (production uses WalkieTalkieAudioImpl, tests use FakeAudioLayer)
@MainActor
final class WalkieTalkieAudio {
    static let shared: WalkieAudioLayer = FakeAudioLayer()
}
