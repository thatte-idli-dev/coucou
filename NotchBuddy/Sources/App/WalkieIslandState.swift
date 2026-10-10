import Foundation
import Combine

enum WalkieIslandPresentation: Equatable {
    case hidden
    case calling
    case onCall(mode: OnCallMode)

    enum OnCallMode: Equatable {
        case talking
        case muted
        case handsFree

        var label: String {
            switch self {
            case .talking: return "Talking"
            case .muted: return "Muted"
            case .handsFree: return "Hands-free"
            }
        }
    }
}

/// Island-facing walkie presentation. Updated only on the main actor.
@MainActor
final class WalkieIslandState: ObservableObject {
    static let shared = WalkieIslandState()

    @Published private(set) var presentation: WalkieIslandPresentation = .hidden
    @Published private(set) var localLevel: Double = 0
    @Published private(set) var remoteLevel: Double = 0

    var holdsIsland: Bool {
        presentation != .hidden
    }

    /// Local level while we transmit; remote level while muted so the friend's voice moves the bars.
    var displayedLevel: Double {
        switch presentation {
        case .hidden, .calling:
            return 0
        case .onCall(.muted):
            return remoteLevel
        case .onCall(.talking), .onCall(.handsFree):
            return localLevel
        }
    }

    func apply(_ state: WalkieState) {
        switch state {
        case .disconnected, .connected:
            presentation = .hidden
            localLevel = 0
            remoteLevel = 0
        case .waiting:
            presentation = .calling
        case .inCall(.handsFree):
            presentation = .onCall(mode: .handsFree)
        case .inCall(.pushToTalk(let transmitting)):
            presentation = .onCall(mode: transmitting ? .talking : .muted)
        }
    }

    func applyLevels(local: Double, remote: Double) {
        localLevel = local
        remoteLevel = remote
    }
}
