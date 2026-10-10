import Foundation

/// Pure protocol layer for Talky-Talky v3 signaling.
/// No AppKit dependencies, suitable for both app and test compilation.
enum WalkieProtocol {
    
    // MARK: - Access Code
    
    struct AccessCodeComponents {
        let origin: String
        let channelToken: String
        let channelID: String
        let channel: Int
    }
    
    static func decodeAccessCode(_ accessCode: String) -> AccessCodeComponents? {
        // Base64URL decode (with or without padding)
        var base64 = accessCode
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        
        guard let decoded = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let origin = json["origin"] as? String,
              let token = json["token"] as? String,
              let channelID = json["channel_id"] as? String,
              let channel = json["channel"] as? Int else {
            return nil
        }
        
        return AccessCodeComponents(
            origin: origin,
            channelToken: token,
            channelID: channelID,
            channel: channel
        )
    }
    
    // MARK: - SSE Events
    
    struct SnapshotEvent {
        let sessionToken: String
        let sessionID: String
        let member: String
    }
    
    struct StateEvent {
        let negotiationID: String?
        let localTuned: Bool
        let peerTuned: Bool
    }
    
    struct SignalEvent {
        let from: String
        let kind: String
        let payload: [String: Any]
    }
    
    static func parseSnapshotEvent(_ data: [String: Any]) -> SnapshotEvent? {
        guard let sessionToken = data["session_token"] as? String,
              let event = data["event"] as? [String: Any],
              let sessionID = event["session_id"] as? String,
              let member = event["member"] as? String else {
            return nil
        }
        
        return SnapshotEvent(
            sessionToken: sessionToken,
            sessionID: sessionID,
            member: member
        )
    }
    
    static func parseStateEvent(_ data: [String: Any]) -> StateEvent? {
        let negotiationID = data["negotiation_id"] as? String
        let localStatus = data["local"] as? [String: Any]
        let peerStatus = data["peer"] as? [String: Any]
        
        let localTuned = localStatus?["tuned"] as? Bool ?? false
        let peerTuned = peerStatus?["tuned"] as? Bool ?? false
        
        return StateEvent(
            negotiationID: negotiationID?.isEmpty == false ? negotiationID : nil,
            localTuned: localTuned,
            peerTuned: peerTuned
        )
    }
    
    static func parseSignalEvent(_ data: [String: Any]) -> SignalEvent? {
        guard let from = data["from"] as? String,
              let kind = data["kind"] as? String,
              let payload = data["payload"] else {
            return nil
        }
        
        var payloadDict: [String: Any] = [:]
        if let payloadData = payload as? Data {
            payloadDict = (try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]) ?? [:]
        } else if let payloadString = payload as? String,
                  let payloadData = payloadString.data(using: .utf8) {
            payloadDict = (try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]) ?? [:]
        } else if let dict = payload as? [String: Any] {
            payloadDict = dict
        }
        
        return SignalEvent(from: from, kind: kind, payload: payloadDict)
    }
    
    // MARK: - Request Bodies
    
    static func buildPresenceBody(sessionID: String, revision: Int, tuned: Bool, transmitting: Bool, restartNegotiation: Bool = false) -> [String: Any] {
        return [
            "session_id": sessionID,
            "revision": revision,
            "tuned": tuned,
            "transmitting": transmitting,
            "restart_negotiation": restartNegotiation
        ]
    }
    
    static func buildSignalBody(sessionID: String, negotiationID: String, kind: String, payload: [String: Any]) -> [String: Any] {
        return [
            "session_id": sessionID,
            "negotiation_id": negotiationID,
            "kind": kind,
            "payload": payload
        ]
    }
    
    static func buildLeaveBody(sessionID: String) -> [String: Any] {
        return ["session_id": sessionID]
    }
    
    // MARK: - ICE Server Response
    
    struct ICEServerConfig {
        let urls: [String]
        let username: String?
        let credential: String?
        let expiresAt: Int64?
        let refreshAfter: Int?
    }
    
    static func parseICEResponse(_ data: [String: Any]) -> ICEServerConfig? {
        // Server returns single server with urls, username, credential
        guard let urlsValue = data["urls"] else {
            return nil
        }
        
        let urls: [String]
        if let urlString = urlsValue as? String {
            urls = [urlString]
        } else if let urlArray = urlsValue as? [String] {
            urls = urlArray
        } else {
            return nil
        }
        
        let username = data["username"] as? String
        let credential = data["credential"] as? String
        let expiresAt = data["expires_at"] as? Int64
        let refreshAfter = data["refresh_after"] as? Int
        
        return ICEServerConfig(
            urls: urls,
            username: username,
            credential: credential,
            expiresAt: expiresAt,
            refreshAfter: refreshAfter
        )
    }

    /// 409 channel_full backoff: 2, 4, 8, then cap at 15 seconds.
    static func channelFullBackoff(
        attempt: Int,
        steps: [TimeInterval] = [2, 4, 8],
        cap: TimeInterval = 15
    ) -> TimeInterval {
        guard attempt > 0 else { return steps.first ?? cap }
        if attempt <= steps.count {
            return steps[attempt - 1]
        }
        return cap
    }
}

/// SSE liveness helpers. Comment lines (`: keepalive`) must count as activity.
enum WalkieSSE {
    static let keepaliveInterval: TimeInterval = 15
    static let streamDeadAfter: TimeInterval = 40
    static let presenceInterval: TimeInterval = 15
    static let bothTunedOfferDeadline: TimeInterval = 5
    static let mediaTimeoutMS = 8000

    /// Pull complete LF (or CRLF) lines from `buffer`, leaving a partial line behind.
    static func pullLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<nl]
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            lines.append(String(data: Data(lineData), encoding: .utf8) ?? "")
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }

    static func isCommentLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(":")
    }
}

/// Parse and throttle walkie analyser level messages (~15 Hz).
enum WalkieLevels {
    static let minInterval: TimeInterval = 1.0 / 15.0

    static func parse(_ dict: [String: Any]) -> (local: Double, remote: Double)? {
        func number(_ key: String) -> Double? {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? Int { return Double(value) }
            if let value = dict[key] as? NSNumber { return value.doubleValue }
            return nil
        }
        guard let local = number("local"), let remote = number("remote") else { return nil }
        return (clamp01(local), clamp01(remote))
    }

    static func shouldAccept(now: Date, last: Date?, minInterval: TimeInterval = minInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) + 0.000_5 >= minInterval
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
