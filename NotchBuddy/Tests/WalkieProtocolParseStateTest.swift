import Foundation

@main
enum WalkieProtocolParseStateTest {
    static func main() {
        testSeatAOnlyTuned()
        testSeatBOnlyTuned()
        testBothTuned()
        testNeitherTuned()
        print("WalkieProtocol state parsing: all cases passed")
    }
    
    // MARK: - Seat A tuned, Seat B not tuned
    
    static func testSeatAOnlyTuned() {
        // Server sends to Seat A
        let stateForA: [String: Any] = [
            "local": ["tuned": true],
            "peer": ["tuned": false]
        ]
        
        guard let eventA = WalkieProtocol.parseStateEvent(stateForA) else {
            preconditionFailure("Failed to parse state for seat A")
        }
        
        precondition(eventA.localTuned == true, "Seat A local should be tuned")
        precondition(eventA.peerTuned == false, "Seat A peer should not be tuned")
        
        // Server sends to Seat B
        let stateForB: [String: Any] = [
            "local": ["tuned": false],
            "peer": ["tuned": true]
        ]
        
        guard let eventB = WalkieProtocol.parseStateEvent(stateForB) else {
            preconditionFailure("Failed to parse state for seat B")
        }
        
        precondition(eventB.localTuned == false, "Seat B local should not be tuned")
        precondition(eventB.peerTuned == true, "Seat B peer should be tuned")
    }
    
    // MARK: - Seat B tuned, Seat A not tuned
    
    static func testSeatBOnlyTuned() {
        // Server sends to Seat A
        let stateForA: [String: Any] = [
            "local": ["tuned": false],
            "peer": ["tuned": true]
        ]
        
        guard let eventA = WalkieProtocol.parseStateEvent(stateForA) else {
            preconditionFailure("Failed to parse state for seat A")
        }
        
        precondition(eventA.localTuned == false, "Seat A local should not be tuned")
        precondition(eventA.peerTuned == true, "Seat A peer should be tuned")
        
        // Server sends to Seat B
        let stateForB: [String: Any] = [
            "local": ["tuned": true],
            "peer": ["tuned": false]
        ]
        
        guard let eventB = WalkieProtocol.parseStateEvent(stateForB) else {
            preconditionFailure("Failed to parse state for seat B")
        }
        
        precondition(eventB.localTuned == true, "Seat B local should be tuned")
        precondition(eventB.peerTuned == false, "Seat B peer should not be tuned")
    }
    
    // MARK: - Both tuned
    
    static func testBothTuned() {
        let state: [String: Any] = [
            "local": ["tuned": true],
            "peer": ["tuned": true],
            "negotiation_id": "test123"
        ]
        
        guard let event = WalkieProtocol.parseStateEvent(state) else {
            preconditionFailure("Failed to parse state")
        }
        
        precondition(event.localTuned == true, "Local should be tuned")
        precondition(event.peerTuned == true, "Peer should be tuned")
        precondition(event.negotiationID == "test123", "Negotiation ID should be present")
    }
    
    // MARK: - Neither tuned
    
    static func testNeitherTuned() {
        let state: [String: Any] = [
            "local": ["tuned": false],
            "peer": ["tuned": false]
        ]
        
        guard let event = WalkieProtocol.parseStateEvent(state) else {
            preconditionFailure("Failed to parse state")
        }
        
        precondition(event.localTuned == false, "Local should not be tuned")
        precondition(event.peerTuned == false, "Peer should not be tuned")
        precondition(event.negotiationID == nil, "Negotiation ID should be nil")
    }
}
