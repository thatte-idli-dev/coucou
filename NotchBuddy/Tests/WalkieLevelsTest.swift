import Foundation

@main
enum WalkieLevelsTest {
    static func main() {
        testParseValid()
        testParseNSNumber()
        testParseMissing()
        testParseClamps()
        testThrottle()
        testChannelFullBackoff()
        testSSEKeepaliveLinesRefreshLiveness()
        print("WalkieLevels: all cases passed")
    }

    static func testParseValid() {
        guard let parsed = WalkieLevels.parse(["local": 0.4, "remote": 0.8]) else {
            preconditionFailure("expected parse of Doubles")
        }
        precondition(abs(parsed.local - 0.4) < 0.000_1, "local")
        precondition(abs(parsed.remote - 0.8) < 0.000_1, "remote")
    }

    static func testParseNSNumber() {
        guard let parsed = WalkieLevels.parse([
            "local": NSNumber(value: 0.25),
            "remote": NSNumber(value: 1)
        ]) else {
            preconditionFailure("expected parse of NSNumber")
        }
        precondition(abs(parsed.local - 0.25) < 0.000_1, "local NSNumber")
        precondition(abs(parsed.remote - 1) < 0.000_1, "remote NSNumber")
    }

    static func testParseMissing() {
        precondition(WalkieLevels.parse(["local": 0.5]) == nil, "missing remote")
        precondition(WalkieLevels.parse(["type": "levels"]) == nil, "missing both")
        precondition(WalkieLevels.parse(["local": "loud", "remote": 0.1]) == nil, "wrong type")
    }

    static func testParseClamps() {
        guard let parsed = WalkieLevels.parse(["local": 1.7, "remote": -0.2]) else {
            preconditionFailure("expected clamp parse")
        }
        precondition(parsed.local == 1, "local clamp")
        precondition(parsed.remote == 0, "remote clamp")
    }

    static func testThrottle() {
        let start = Date(timeIntervalSince1970: 1_000)
        precondition(WalkieLevels.shouldAccept(now: start, last: nil), "first sample")
        precondition(
            !WalkieLevels.shouldAccept(now: start.addingTimeInterval(1.0 / 30.0), last: start),
            "faster than 15 Hz must drop"
        )
        precondition(
            WalkieLevels.shouldAccept(now: start.addingTimeInterval(1.0 / 15.0), last: start),
            "15 Hz boundary accepted"
        )
        precondition(
            WalkieLevels.shouldAccept(now: start.addingTimeInterval(0.2), last: start),
            "slower than 15 Hz accepted"
        )
    }

    static func testChannelFullBackoff() {
        precondition(WalkieProtocol.channelFullBackoff(attempt: 1) == 2, "first 409 is 2s")
        precondition(WalkieProtocol.channelFullBackoff(attempt: 2) == 4, "second 409 is 4s")
        precondition(WalkieProtocol.channelFullBackoff(attempt: 3) == 8, "third 409 is 8s")
        precondition(WalkieProtocol.channelFullBackoff(attempt: 4) == 15, "fourth 409 caps at 15s")
        precondition(WalkieProtocol.channelFullBackoff(attempt: 10) == 15, "later 409 stays at 15s")
    }

    static func testSSEKeepaliveLinesRefreshLiveness() {
        precondition(WalkieSSE.streamDeadAfter == 40, "watchdog must be 40s")
        precondition(
            WalkieSSE.streamDeadAfter > 2 * WalkieSSE.keepaliveInterval,
            "watchdog must be over 2× the 15s keepalive"
        )
        var buffer = Data(": keepalive\n\n".utf8)
        let lines = WalkieSSE.pullLines(from: &buffer)
        precondition(lines.count == 2, "keepalive frame is comment + blank")
        precondition(WalkieSSE.isCommentLine(lines[0]), ": keepalive is a comment")
        precondition(lines[1].isEmpty, "SSE comment frame ends with a blank line")
        precondition(buffer.isEmpty, "keepalive bytes must be fully consumed")

        buffer = Data("event: state\ndata: {\"ok\":true}\n\npartial".utf8)
        let events = WalkieSSE.pullLines(from: &buffer)
        precondition(events.count == 3, "event + data + blank")
        precondition(!WalkieSSE.isCommentLine(events[0]), "event line is not a comment")
        precondition(String(data: buffer, encoding: .utf8) == "partial", "partial line stays buffered")
    }
}
