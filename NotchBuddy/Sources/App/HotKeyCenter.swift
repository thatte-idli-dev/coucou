import AppKit
import Carbon.HIToolbox
import os.log

private let walkieHotKeyLogger = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "Walkie")

// MARK: - C-level event handler
//
// Carbon's InstallEventHandler requires a top-level C-compatible function.
// We store state in nonisolated(unsafe) globals — safe because all mutations
// happen on the main thread (Carbon dispatches hot-key events on the main thread).

private nonisolated(unsafe) var gHotKeyHandler: EventHandlerRef? = nil
private nonisolated(unsafe) var gHotKeyTable: [UInt32: ShortcutAction] = [:]
private nonisolated(unsafe) var gOnAction: ((ShortcutAction, Bool) -> Void)? = nil

private func coucouHotKeyEventHandler(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    
    let eventKind = GetEventKind(event)
    let isPressed = (eventKind == UInt32(kEventHotKeyPressed))
    
    var hkid = EventHotKeyID()
    let err = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkid
    )
    guard err == noErr, let action = gHotKeyTable[hkid.id] else {
        return OSStatus(eventNotHandledErr)
    }
    if action == .walkie {
        walkieHotKeyLogger.info("Hotkey raw: walkie \(isPressed ? "down" : "up", privacy: .public) (carbon \(isPressed ? "pressed" : "released", privacy: .public))")
    }
    // Carbon events are dispatched on the main thread.
    MainActor.assumeIsolated { gOnAction?(action, isPressed) }
    return noErr
}

// MARK: - HotKeyCenter

/// Manages all global keyboard shortcuts via Carbon `RegisterEventHotKey`.
///
/// - No Accessibility permission required.
/// - Works in the App Store sandbox.
/// - The hot-key event is consumed and never forwarded to the front application.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private init() {}

    // "COUC" in big-endian — unique signature for Coucou's hot-key IDs
    private let kSignature = OSType(0x434F5543)

    // Live registered refs (action → EventHotKeyRef)
    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private var walkieComboWatch: Timer?
    private var walkiePhysicallyDown = false
    private var walkieWatchStarted: Date?

    /// Actions whose `RegisterEventHotKey` call failed (system conflict).
    private(set) var conflicts: Set<ShortcutAction> = []

    // MARK: - Lifecycle

    /// Start the hot-key engine and fire `onAction` whenever the user presses a registered shortcut.
    /// Safe to call more than once — the handler is installed only once.
    func start(onAction: @escaping @MainActor (ShortcutAction, Bool) -> Void) {
        gOnAction = { [weak self] action, isPressed in
            if action == .walkie {
                self?.noteWalkieCarbon(isPressed: isPressed)
            }
            onAction(action, isPressed)
        }

        if gHotKeyHandler == nil {
            var specs = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyReleased))
            ]
            InstallEventHandler(
                GetApplicationEventTarget(),
                coucouHotKeyEventHandler,
                2, &specs,
                nil, &gHotKeyHandler
            )
        }

        registerAll()
    }

    /// HID snapshot: the walkie key AND every required modifier are still down.
    static func isWalkieComboPhysicallyHeld() -> Bool {
        let spec = ShortcutLogic.hotKey(for: .walkie)
        let hidFlags = UInt(CGEventSource.flagsState(.hidSystemState).rawValue)
        let keyIsDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(spec.keyCode))
        return WalkieGestureMapping.comboStillHeld(spec: spec, hidFlags: hidFlags, keyIsDown: keyIsDown)
    }

    private func noteWalkieCarbon(isPressed: Bool) {
        if isPressed {
            self.walkiePhysicallyDown = true
            self.walkieWatchStarted = Date()
            self.startWalkieComboWatch()
        } else {
            self.walkiePhysicallyDown = false
            self.walkieWatchStarted = nil
            self.stopWalkieComboWatch()
        }
    }

    private func startWalkieComboWatch() {
        self.stopWalkieComboWatch()
        // Carbon often swallows kEventHotKeyReleased when K goes up while
        // Control-Option are still held (or the reverse). Poll HID.
        self.walkieComboWatch = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollWalkieCombo()
            }
        }
        if let watch = self.walkieComboWatch {
            RunLoop.main.add(watch, forMode: .common)
        }
    }

    private func stopWalkieComboWatch() {
        self.walkieComboWatch?.invalidate()
        self.walkieComboWatch = nil
    }

    private func pollWalkieCombo() {
        guard self.walkiePhysicallyDown else { return }
        let spec = ShortcutLogic.hotKey(for: .walkie)
        let hidFlags = UInt(CGEventSource.flagsState(.hidSystemState).rawValue)
        let keyIsDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(spec.keyCode))
        if !WalkieGestureMapping.modifiersStillHeld(spec: spec, hidFlags: hidFlags) {
            self.synthesizeWalkieUp(reason: "modifier released")
            return
        }
        let elapsed = Date().timeIntervalSince(self.walkieWatchStarted ?? Date())
        if elapsed >= 0.08 && !keyIsDown {
            self.synthesizeWalkieUp(reason: "key released")
        }
    }

    private func synthesizeWalkieUp(reason: String) {
        walkieHotKeyLogger.info("Hotkey raw: walkie up (combo released, \(reason, privacy: .public))")
        self.walkiePhysicallyDown = false
        self.walkieWatchStarted = nil
        self.stopWalkieComboWatch()
        gOnAction?(.walkie, false)
    }

    /// Unregister every hot key. Called on app quit.
    func unregisterAll() {
        self.stopWalkieComboWatch()
        self.walkiePhysicallyDown = false
        self.walkieWatchStarted = nil
        for (action, ref) in refs {
            UnregisterEventHotKey(ref)
            let idx = UInt32(ShortcutAction.allCases.firstIndex(of: action)!)
            gHotKeyTable.removeValue(forKey: idx)
        }
        refs.removeAll()
    }

    /// Re-register all shortcuts from the current UserDefaults state.
    func registerAll() {
        unregisterAll()
        conflicts.removeAll()

        for action in ShortcutAction.allCases {
            #if APPSTORE
            if action.isNonAppStore { continue }
            #endif
            if !ShortcutLogic.isEnabled(action) { continue }
            registerOne(action)
        }
    }

    /// Re-register a single action (called after a setting change).
    func reregister(_ action: ShortcutAction) {
        // Remove old registration if present
        if let ref = refs[action] {
            UnregisterEventHotKey(ref)
            let idx = UInt32(ShortcutAction.allCases.firstIndex(of: action)!)
            gHotKeyTable.removeValue(forKey: idx)
            refs.removeValue(forKey: action)
        }
        conflicts.remove(action)

        #if APPSTORE
        if action.isNonAppStore { return }
        #endif
        if !ShortcutLogic.isEnabled(action) { return }
        registerOne(action)
    }

    // MARK: - Private

    private func registerOne(_ action: ShortcutAction) {
        let spec   = ShortcutLogic.hotKey(for: action)
        let carbon = ShortcutLogic.carbonModifiers(fromNS: spec.nsFlags)
        let idx    = UInt32(ShortcutAction.allCases.firstIndex(of: action)!)
        let hkid   = EventHotKeyID(signature: kSignature, id: idx)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            UInt32(spec.keyCode),
            carbon,
            hkid,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs[action] = ref
            gHotKeyTable[idx] = action
        } else {
            conflicts.insert(action)
        }
    }
}
