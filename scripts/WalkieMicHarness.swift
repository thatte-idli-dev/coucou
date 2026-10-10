import AppKit
import Foundation
import os.log

/// Tiny regular (not LSUIElement) app that loads the production WalkieTalkieAudio
/// page and calls probeMic. Run on a real Mac:
///   bash scripts/test-walkie-mic-harness.sh --run
@MainActor
@main
final class WalkieMicHarness: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = WalkieMicHarness()
        app.delegate = delegate
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            FileHandle.standardError.write(Data("HARNESS TIMEOUT after 25s\n".utf8))
            exit(2)
        }
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== Walkie mic harness ===")
        print("activationPolicy=\(NSApp.activationPolicy())")
        print("bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        Task { await self.run() }
    }

    private func run() async {
        let audio = WalkieTalkieAudio.shared
        let granted = await audio.checkMicPermission()
        print("micPermission=\(granted)")
        guard granted else {
            print("FAIL mic permission denied — grant Microphone to WalkieMicHarness and retry")
            audio.cleanup()
            exit(1)
        }

        audio.setupWebView(
            onIceCandidate: { _ in },
            onAnswer: { _ in }
        )
        await audio.probeCapture()
        let result = audio.lastProbeDescription
        print("probeMic result=\(result)")
        if result.contains("ok") {
            print("PASS")
            audio.cleanup()
            exit(0)
        }
        print("FAIL getUserMedia did not produce a track")
        print("Look in Console.app for subsystem fr.louisraille.NotchBuddy category Walkie:")
        print("  env mediaDevices= isSecureContext= origin=")
        print("  Media capture permission: entered")
        print("  getUserMedia err name= message=")
        audio.cleanup()
        exit(1)
    }
}
