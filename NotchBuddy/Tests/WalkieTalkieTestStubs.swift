import Foundation
import AppKit

// Test stubs for app-only symbols referenced by WalkieTalkieLink

extension NSNotification.Name {
    static let walkiePTTDown = NSNotification.Name("walkiePTTDown")
    static let walkiePTTUp = NSNotification.Name("walkiePTTUp")
    static let walkieDoubleTap = NSNotification.Name("walkieDoubleTap")
    static let walkieTap = NSNotification.Name("walkieTap")
    static let triggerEmote = NSNotification.Name("triggerEmote")
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
