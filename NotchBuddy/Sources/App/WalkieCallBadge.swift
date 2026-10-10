import SwiftUI

/// Compact notch badge for walkie waiting / in-call. New view; does not restyle shipped chrome.
struct WalkieCallBadge: View {
    let presentation: WalkieIslandPresentation
    let level: Double
    @State private var pulse = false

    var body: some View {
        switch presentation {
        case .hidden:
            EmptyView()
        case .calling:
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(hex: "#10B981"))
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 1 : 0.35)
                Text("Calling…")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .fixedSize()
            }
            .walkieBadgeChrome()
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        case .onCall(let mode):
            HStack(spacing: 6) {
                Text("On call")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .fixedSize()
                Text(mode.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .fixedSize()
                WalkieVoiceBars(level: level)
            }
            .walkieBadgeChrome()
        }
    }
}

struct WalkieVoiceBars: View {
    let level: Double

    var body: some View {
        let factors: [Double] = [0.45, 1.0, 0.72, 0.88]
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color(hex: "#10B981"))
                    .frame(width: 2.5, height: 4 + 11 * level * factors[index])
            }
        }
        .frame(height: 15, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

private extension View {
    func walkieBadgeChrome() -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: "#0E0F11")))
            .overlay(
                Capsule().stroke(Color(hex: "#10B981").opacity(0.35), lineWidth: 1)
            )
    }
}
