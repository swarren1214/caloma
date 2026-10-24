import Foundation

/// What the family's devices say to each other over the intercom's connection. Each message is
/// JSON, sent with a 4-byte length in front (see `IntercomFrame`). Sound and video don't go
/// this way: they go straight between the devices over WebRTC, which this sets up.
nonisolated enum IntercomMessage: Codable, Equatable, Sendable {
    /// First thing on every connection: who's on the other end.
    case hello(device: UUID, name: String)
    /// Calling: ring this device. `group` lists everyone else being rung for the same call.
    case ring(call: UUID, from: UUID, name: String, video: Bool, group: [UUID])
    /// Broadcasting: join and listen, no answering (one way; nothing goes back but setup).
    case announce(call: UUID, from: UUID, name: String)
    /// Picked up.
    case accept(call: UUID, video: Bool)
    case decline(call: UUID, reason: DeclineReason)
    /// Left the call (or stopped ringing).
    case hangUp(call: UUID)
    /// WebRTC's session descriptions and network candidates.
    case offer(call: UUID, sdp: String)
    case answer(call: UUID, sdp: String)
    case candidate(call: UUID, sdp: String, mid: String?, index: Int32)
    /// Their camera went on or off, so the other end shows video or their name.
    case camera(call: UUID, on: Bool)
    /// Flash "Kitchen Board" on that screen, to tell which one is which.
    case find(name: String)

    /// The call it belongs to, if any.
    var call: UUID? {
        switch self {
        case let .ring(call, _, _, _, _), let .announce(call, _, _), let .accept(call, _), let .decline(call, _), let .hangUp(call),
             let .offer(call, _), let .answer(call, _), let .candidate(call, _, _, _), let .camera(call, _):
            call
        case .hello, .find:
            nil
        }
    }
}

nonisolated enum DeclineReason: String, Codable, Sendable {
    /// Someone tapped Decline.
    case declined
    /// Already on another call.
    case busy
    /// Nobody answered in time.
    case noAnswer
    /// This device has calls turned off.
    case off

    var sentence: String {
        switch self {
        case .declined: "Declined"
        case .busy: "On another call"
        case .noAnswer: "No answer"
        case .off: "Not taking calls"
        }
    }
}

/// The intercom's framing: a 4-byte big-endian length, then that many bytes of JSON.
nonisolated enum IntercomFrame {
    /// Nothing the intercom sends comes close; anything bigger is a broken or hostile peer.
    static let maximumLength = 512 * 1024

    static func encode(_ message: IntercomMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// The body's length from a 4-byte header, or nil if it's out of range.
    static func length(fromHeader header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard value > 0, value <= UInt32(maximumLength) else { return nil }
        return Int(value)
    }

    static func decode(_ body: Data) throws -> IntercomMessage {
        try JSONDecoder().decode(IntercomMessage.self, from: body)
    }
}
