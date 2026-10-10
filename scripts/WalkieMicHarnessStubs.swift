import Foundation

/// Minimal island stub so the production WalkieTalkieAudio sources compile
/// into the standalone mic harness without AppKit island / Combine.
@MainActor
final class WalkieIslandState {
    static let shared = WalkieIslandState()
    func applyLevels(local: Double, remote: Double) {}
}
