import Foundation

public enum Role: String, Codable, Sendable, CaseIterable {
    case sender
    case viewer

    public var counterpart: Role {
        switch self {
        case .sender: .viewer
        case .viewer: .sender
        }
    }
}

public struct PeerInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: Role

    public init(id: String, role: Role) {
        self.id = id
        self.role = role
    }
}

public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case unknownMessageType(String)
    case invalidField(String)

    public var description: String {
        switch self {
        case .unknownMessageType(let type):
            "Unknown message type '\(type)'"
        case .invalidField(let field):
            "Invalid or missing field '\(field)'"
        }
    }
}

public enum ClientMessage: Equatable, Sendable {
    public static let maximumRoomLength = 64
    public static let maximumSessionLength = 64

    case join(room: String, role: Role, sessionId: String)
    case offer(sdp: String)
    case answer(sdp: String)
    case iceCandidate(JSONValue)
    case leave
}

extension ClientMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "join":
            guard let roomValue = try container.decodeIfPresent(String.self, forKey: .room),
                  let role = try container.decodeIfPresent(Role.self, forKey: .role),
                  let sessionValue = try container.decodeIfPresent(String.self, forKey: .sessionId)
            else {
                throw ProtocolError.invalidField(type)
            }

            let room = roomValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionId = sessionValue.trimmingCharacters(in: .whitespacesAndNewlines)

            guard (1 ... Self.maximumRoomLength).contains(room.count),
                  (1 ... Self.maximumSessionLength).contains(sessionId.count)
            else {
                throw ProtocolError.invalidField("room")
            }
            self = .join(room: room, role: role, sessionId: sessionId)

        case "offer", "answer":
            guard let sdp = try container.decodeIfPresent(String.self, forKey: .sdp),
                  !sdp.isEmpty
            else {
                throw ProtocolError.invalidField("sdp")
            }
            self = type == "offer" ? .offer(sdp: sdp) : .answer(sdp: sdp)

        case "ice-candidate":
            guard let candidate = try container.decodeIfPresent(JSONValue.self, forKey: .candidate),
                  candidate.objectValue != nil
            else {
                throw ProtocolError.invalidField("candidate")
            }
            self = .iceCandidate(candidate)

        case "leave":
            self = .leave

        default:
            throw ProtocolError.unknownMessageType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)

        switch self {
        case .join(let room, let role, let sessionId):
            try container.encode("join", forKey: .type)
            try container.encode(room, forKey: .room)
            try container.encode(role, forKey: .role)
            try container.encode(sessionId, forKey: .sessionId)

        case .offer(let sdp):
            try container.encode("offer", forKey: .type)
            try container.encode(sdp, forKey: .sdp)

        case .answer(let sdp):
            try container.encode("answer", forKey: .type)
            try container.encode(sdp, forKey: .sdp)

        case .iceCandidate(let candidate):
            try container.encode("ice-candidate", forKey: .type)
            try container.encode(candidate, forKey: .candidate)

        case .leave:
            try container.encode("leave", forKey: .type)
        }
    }

    public func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }
}

public enum ServerMessage: Equatable, Sendable {
    case joined(peerId: String, room: String, role: Role, peer: PeerInfo?)
    case peerJoined(peer: PeerInfo)
    case peerLeft(peerId: String)
    case offer(from: String, sdp: String)
    case answer(from: String, sdp: String)
    case iceCandidate(from: String, candidate: JSONValue)
    case error(code: String, message: String)
}

extension ServerMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "joined":
            let peerId = try container.decode(String.self, forKey: .peerId)
            let room = try container.decode(String.self, forKey: .room)
            let role = try container.decode(Role.self, forKey: .role)

            let peer = try container.decodeIfPresent(PeerInfo.self, forKey: .peer)
            self = .joined(peerId: peerId, room: room, role: role, peer: peer)

        case "peer-joined":
            self = .peerJoined(peer: try container.decode(PeerInfo.self, forKey: .peer))

        case "peer-left":
            self = .peerLeft(peerId: try container.decode(String.self, forKey: .peerId))

        case "offer", "answer":
            let from = try container.decode(String.self, forKey: .from)
            let sdp = try container.decode(String.self, forKey: .sdp)
            self = type == "offer" ? .offer(from: from, sdp: sdp) : .answer(from: from, sdp: sdp)

        case "ice-candidate":
            let from = try container.decode(String.self, forKey: .from)
            let candidate = try container.decode(JSONValue.self, forKey: .candidate)
            self = .iceCandidate(from: from, candidate: candidate)

        case "error":
            let code = try container.decode(String.self, forKey: .code)
            let message = try container.decode(String.self, forKey: .message)
            self = .error(code: code, message: message)

        default:
            throw ProtocolError.unknownMessageType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)

        switch self {
        case .joined(let peerId, let room, let role, let peer):
            try container.encode("joined", forKey: .type)
            try container.encode(peerId, forKey: .peerId)
            try container.encode(room, forKey: .room)
            try container.encode(role, forKey: .role)
            try container.encode(peer, forKey: .peer)

        case .peerJoined(let peer):
            try container.encode("peer-joined", forKey: .type)
            try container.encode(peer, forKey: .peer)

        case .peerLeft(let peerId):
            try container.encode("peer-left", forKey: .type)
            try container.encode(peerId, forKey: .peerId)

        case .offer(let from, let sdp):
            try container.encode("offer", forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(sdp, forKey: .sdp)

        case .answer(let from, let sdp):
            try container.encode("answer", forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(sdp, forKey: .sdp)

        case .iceCandidate(let from, let candidate):
            try container.encode("ice-candidate", forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(candidate, forKey: .candidate)

        case .error(let code, let message):
            try container.encode("error", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }

    public static func decode(from data: Data) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: data)
    }

    public static func decode(from text: String) throws -> ServerMessage {
        try decode(from: Data(text.utf8))
    }
}

extension ServerMessage {
    public var typeName: String {
        switch self {
        case .joined: "joined"
        case .peerJoined: "peer-joined"
        case .peerLeft: "peer-left"
        case .offer: "offer"
        case .answer: "answer"
        case .iceCandidate: "ice-candidate"
        case .error: "error"
        }
    }

    public enum ErrorCode {
        public static let roleTaken = "role-taken"
        public static let invalidMessage = "invalid-message"
        public static let noPeer = "no-peer"
        public static let alreadyInRoom = "already-in-room"
    }
}

enum Key: String, CodingKey {
    case type
    case room
    case role
    case sessionId
    case sdp
    case candidate
    case peerId
    case peer
    case from
    case code
    case message
}
