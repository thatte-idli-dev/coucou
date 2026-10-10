import Foundation

@main
enum WalkieGestureTests {
    static func main() {
        testHoldAndRelease()
        testShortTapBecomesHangup()
        testDoubleTap()
        testDoubleTapNotMisreadAsTapHangup()
        testKeyRepeatDebounce()
        testHoldThresholdExact()
        testTapThenHold()
        testSlowDoubleTap()
        testHoldReleaseUntunes()
        testIdleSingleTapDoesNotLatch()
        testDoubleTapLatchesHandsFree()
        testSingleTapLeavesHandsFree()
        testComboReleaseOnAnyKey()
        print("WalkieGestureClassifier: all cases passed")
    }

    // MARK: - testHoldAndRelease

    static func testHoldAndRelease() {
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        
        // Key down at t=0
        let e1 = c.keyDown(at: 0)
        precondition(e1 == nil, "keyDown must not emit event immediately")
        
        // Check threshold at t=150ms (not yet held)
        let e2 = c.checkHoldThreshold(at: 150)
        precondition(e2 == nil, "threshold not crossed at 150ms")
        
        // Check at t=180ms (exactly at threshold)
        let e3 = c.checkHoldThreshold(at: 180)
        precondition(e3 == .pttDown, "threshold at 180ms must emit pttDown")
        
        // Check again (already held, no repeat)
        let e4 = c.checkHoldThreshold(at: 200)
        precondition(e4 == nil, "pttDown must not repeat")
        
        // Key up at t=500ms
        let e5 = c.keyUp(at: 500)
        precondition(e5 == .pttUp, "keyUp after hold must emit pttUp")
    }

    // MARK: - testShortTapBecomesHangup

    static func testShortTapBecomesHangup() {
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        
        // Key down at t=0
        let e1 = c.keyDown(at: 0)
        precondition(e1 == nil, "keyDown immediate")
        
        // Key up at t=100ms (short, not a hold)
        let e2 = c.keyUp(at: 100)
        precondition(e2 == nil, "short keyUp waits for double-tap timeout")
        
        // Wait until t=600ms (past double-tap interval)
        let e3 = c.checkTapTimeout(at: 600)
        precondition(e3 == .tap, "timeout must emit tap")
        
        // Check again (no repeat)
        let e4 = c.checkTapTimeout(at: 700)
        precondition(e4 == nil, "tap must not repeat")
    }

    // MARK: - testDoubleTap

    static func testDoubleTap() {
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        
        // First tap: down at t=0, up at t=100
        _ = c.keyDown(at: 0)
        let e1 = c.keyUp(at: 100)
        precondition(e1 == nil, "first tap keyUp waits")
        
        // Second tap: down at t=300, up at t=400 (within 500ms)
        _ = c.keyDown(at: 300)
        let e2 = c.keyUp(at: 400)
        precondition(e2 == .doubleTap, "second tap within interval must emit doubleTap")
        
        // No tap event should follow
        let e3 = c.checkTapTimeout(at: 1000)
        precondition(e3 == nil, "doubleTap must consume tap")
    }

    // MARK: - testDoubleTapNotMisreadAsTapHangup

    static func testDoubleTapNotMisreadAsTapHangup() {
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        
        // First tap: down at t=0, up at t=100
        _ = c.keyDown(at: 0)
        _ = c.keyUp(at: 100)
        
        // Before timeout, second tap arrives: down at t=400
        let e1 = c.keyDown(at: 400)
        precondition(e1 == nil, "second keyDown before timeout")
        
        // Second tap up at t=500
        let e2 = c.keyUp(at: 500)
        precondition(e2 == .doubleTap, "must emit doubleTap, not tap")
        
        // No tap event at any time
        let e3 = c.checkTapTimeout(at: 1000)
        precondition(e3 == nil, "no tap after doubleTap")
    }

    // MARK: - testKeyRepeatDebounce

    static func testKeyRepeatDebounce() {
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        
        // Key down at t=0
        let e1 = c.keyDown(at: 0)
        precondition(e1 == nil, "initial keyDown")
        
        // Hold crosses threshold at t=180
        let e2 = c.checkHoldThreshold(at: 180)
        precondition(e2 == .pttDown, "hold emits pttDown")
        
        // Key repeat: another keyDown at t=250 (ignored)
        let e3 = c.keyDown(at: 250)
        precondition(e3 == nil, "key repeat keyDown ignored")
        
        // Key up at t=500
        let e4 = c.keyUp(at: 500)
        precondition(e4 == .pttUp, "keyUp emits pttUp")
    }

    // MARK: - testHoldThresholdExact

    static func testHoldThresholdExact() {
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        
        // Key down at t=1000
        _ = c.keyDown(at: 1000)
        
        // At t=1179 (179ms elapsed, <180ms)
        let e1 = c.checkHoldThreshold(at: 1179)
        precondition(e1 == nil, "179ms must not emit pttDown")
        
        // At t=1180 (exactly 180ms)
        let e2 = c.checkHoldThreshold(at: 1180)
        precondition(e2 == .pttDown, "180ms must emit pttDown")
        
        // Key up at t=1200
        let e3 = c.keyUp(at: 1200)
        precondition(e3 == .pttUp, "keyUp after threshold must emit pttUp")
    }

    // MARK: - testTapThenHold
    
    static func testTapThenHold() {
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        
        // First tap: down at t=0, up at t=100
        _ = c.keyDown(at: 0)
        let e1 = c.keyUp(at: 100)
        precondition(e1 == nil, "first tap keyUp waits")
        
        // Second press (hold): down at t=200 (within double-tap window)
        let e2 = c.keyDown(at: 200)
        precondition(e2 == nil, "second keyDown within window")
        
        // Hold crosses threshold at t=380
        let e3 = c.checkHoldThreshold(at: 380)
        precondition(e3 == .pttDown, "hold threshold emits pttDown")
        
        // CRITICAL: No tap should be emitted while key is held
        let e4 = c.checkTapTimeout(at: 700)
        precondition(e4 == nil, "tap must not emit during hold - first tap was cancelled by second press")
        
        // Key up at t=1000
        let e5 = c.keyUp(at: 1000)
        precondition(e5 == .pttUp, "keyUp after hold emits pttUp")
        
        // Still no tap after release
        let e6 = c.checkTapTimeout(at: 1500)
        precondition(e6 == nil, "no tap after pttUp")
    }

    // MARK: - testSlowDoubleTap
    
    static func testSlowDoubleTap() {
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        
        // First tap: down at t=0, up at t=100
        _ = c.keyDown(at: 0)
        let e1 = c.keyUp(at: 100)
        precondition(e1 == nil, "first tap keyUp waits")
        
        // Second tap: down at t=450 (within 500ms window, but slow)
        let e2 = c.keyDown(at: 450)
        precondition(e2 == nil, "second keyDown")
        
        // Second tap up at t=550 (duration=100ms, short tap)
        let e3 = c.keyUp(at: 550)
        precondition(e3 == .doubleTap, "slow but valid double-tap emits doubleTap")
        
        // No tap event should follow
        let e4 = c.checkTapTimeout(at: 1100)
        precondition(e4 == nil, "no tap after doubleTap")
    }

    static func testHoldReleaseUntunes() {
        var phase: WalkieSessionPhase = .idle
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        _ = c.keyDown(at: 0)
        precondition(c.checkHoldThreshold(at: 180) == .pttDown, "hold starts")
        phase = WalkieGestureMapping.apply(phase, event: .pttDown)
        precondition(phase == .waiting(handsFree: false), "hold tunes waiting")
        precondition(c.keyUp(at: 400) == .pttUp, "release ends hold")
        phase = WalkieGestureMapping.apply(phase, event: .pttUp)
        precondition(phase == .idle, "hold then release untunes")
    }

    static func testIdleSingleTapDoesNotLatch() {
        var phase: WalkieSessionPhase = .idle
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        _ = c.keyDown(at: 0)
        precondition(c.keyUp(at: 80) == nil, "short up waits for second tap")
        precondition(c.checkTapTimeout(at: 600) == .tap, "lone tap resolves as singleTap")
        phase = WalkieGestureMapping.apply(phase, event: .tap)
        precondition(phase == .idle, "idle single tap must not stay tuned")
    }

    static func testDoubleTapLatchesHandsFree() {
        var phase: WalkieSessionPhase = .idle
        let c = WalkieGestureClassifier(doubleTapInterval: 0.5)
        _ = c.keyDown(at: 0)
        _ = c.keyUp(at: 80)
        _ = c.keyDown(at: 200)
        precondition(c.keyUp(at: 280) == .doubleTap, "two quick taps")
        phase = WalkieGestureMapping.apply(phase, event: .doubleTap)
        precondition(phase == .waiting(handsFree: true), "double-tap latches hands-free")
        phase = WalkieGestureMapping.apply(phase, event: .pttUp)
        precondition(phase == .waiting(handsFree: true), "key-up after double-tap stays latched")
    }

    static func testSingleTapLeavesHandsFree() {
        var phase: WalkieSessionPhase = .waiting(handsFree: true)
        phase = WalkieGestureMapping.apply(phase, event: .tap)
        precondition(phase == .idle, "single tap leaves hands-free waiting")
        phase = .inCall(handsFree: true, transmitting: true)
        phase = WalkieGestureMapping.apply(phase, event: .tap)
        precondition(phase == .idle, "single tap leaves hands-free call")
    }

    static func testComboReleaseOnAnyKey() {
        let spec = ShortcutSpec(keyCode: 40, nsFlags: ShortcutSpec.ctrlOpt)
        let held = ShortcutSpec.ctrlBit | ShortcutSpec.optBit
        precondition(
            WalkieGestureMapping.comboStillHeld(spec: spec, hidFlags: held, keyIsDown: true),
            "K + Control-Option is held"
        )
        precondition(
            !WalkieGestureMapping.comboStillHeld(spec: spec, hidFlags: held, keyIsDown: false),
            "letting go of K is a release"
        )
        precondition(
            !WalkieGestureMapping.comboStillHeld(spec: spec, hidFlags: ShortcutSpec.optBit, keyIsDown: true),
            "letting go of Control is a release"
        )
        precondition(
            !WalkieGestureMapping.comboStillHeld(spec: spec, hidFlags: ShortcutSpec.ctrlBit, keyIsDown: true),
            "letting go of Option is a release"
        )
    }
}
