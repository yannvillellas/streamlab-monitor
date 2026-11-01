import Foundation

public enum RoomState: Equatable, Sendable {
    case unknown
    case waiting
    case connected
    case failed(code: String, message: String)

    public var label: String {
        switch self {
        case .unknown: "unknown"
        case .waiting: "waiting"
        case .connected: "connected"
        case .failed: "error"
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    public var sortRank: Int {
        switch self {
        case .failed: 0
        case .connected: 1
        case .waiting: 2
        case .unknown: 3
        }
    }
}

public struct RoomEvent: Identifiable, Equatable, Sendable {
    public enum Direction: String, Equatable, Sendable {
        case outbound
        case inbound
        case local
    }

    public let id: UInt64
    public let receivedAt: Date
    public let direction: Direction
    public let text: String
    public let message: ServerMessage?

    public init(
        id: UInt64,
        receivedAt: Date,
        direction: Direction,
        text: String,
        message: ServerMessage? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.direction = direction
        self.text = text
        self.message = message
    }
}

public struct RoomRecord: Identifiable, Equatable, Sendable {
    public var id: String { room }

    public let room: String
    public var role: Role
    public private(set) var state: RoomState
    public private(set) var peer: PeerInfo?
    public private(set) var localPeerId: String?
    public private(set) var sessionId: String
    public private(set) var events: [RoomEvent]

    public static let eventLimit = 50

    public init(
        room: String,
        role: Role,
        state: RoomState = .unknown,
        peer: PeerInfo? = nil,
        localPeerId: String? = nil,
        sessionId: String = UUID().uuidString,
        events: [RoomEvent] = []
    ) {
        self.room = room
        self.role = role
        self.state = state
        self.peer = peer
        self.localPeerId = localPeerId
        self.sessionId = sessionId
        self.events = events
    }

    public var isJoined: Bool {
        localPeerId != nil && !state.isFailure
    }

    public mutating func beginJoin(at date: Date) {
        state = .waiting
        peer = nil
        append(text: "connecting", direction: .local, at: date)
    }

    public mutating func endSession(state next: RoomState, at date: Date, reason: String) {
        localPeerId = nil
        peer = nil
        state = next
        append(text: reason, direction: .local, at: date)
    }

    @discardableResult
    public mutating func apply(_ message: ServerMessage, at date: Date) -> RoomEvent {
        switch message {
        case .joined(let peerId, _, let role, let peer):
            localPeerId = peerId
            self.role = role
            self.peer = peer
            state = peer == nil ? .waiting : .connected

        case .peerJoined(let peer):
            self.peer = peer
            state = .connected

        case .peerLeft(let peerId):
            if peer?.id == peerId {
                peer = nil
            }
            if peer == nil, state == .connected {
                state = .waiting
            }

        case .error(let code, let message):
            state = .failed(code: code, message: message)
            if code == ServerMessage.ErrorCode.roleTaken {
                peer = nil
                localPeerId = nil
            }

        case .offer, .answer, .iceCandidate:
            break
        }

        return append(text: Self.summary(of: message), direction: .inbound, at: date, message: message)
    }

    public mutating func record(
        text: String,
        direction: RoomEvent.Direction = .local,
        at date: Date,
        message: ServerMessage? = nil
    ) {
        append(text: text, direction: direction, at: date, message: message)
    }

    @discardableResult
    private mutating func append(
        text: String,
        direction: RoomEvent.Direction,
        at date: Date,
        message: ServerMessage? = nil
    ) -> RoomEvent {
        let event = RoomEvent(
            id: (events.last?.id ?? 0) + 1,
            receivedAt: date,
            direction: direction,
            text: text,
            message: message
        )
        events.append(event)

        if events.count > Self.eventLimit {
            events.removeFirst(events.count - Self.eventLimit)
        }

        return event
    }

    static func summary(of message: ServerMessage) -> String {
        switch message {
        case .joined(let peerId, let room, let role, let peer):
            let other = peer.map { "\($0.role.rawValue) \($0.id.prefix(8))" } ?? "none"
            return "joined · \(room) · \(role.rawValue) · self \(peerId.prefix(8)) · peer \(other)"
        case .peerJoined(let peer):
            return "peer-joined · \(peer.role.rawValue) \(peer.id.prefix(8))"
        case .peerLeft(let peerId):
            return "peer-left · \(peerId.prefix(8))"
        case .offer(let from, let sdp):
            return "offer · from \(from.prefix(8)) · \(sdp.count) chars"
        case .answer(let from, let sdp):
            return "answer · from \(from.prefix(8)) · \(sdp.count) chars"
        case .iceCandidate(let from, let candidate):
            return "ice-candidate · from \(from.prefix(8)) · \(candidate.compactDescription)"
        case .error(let code, let message):
            return "error · \(code) · \(message)"
        }
    }
}

extension JSONValue {
    var compactDescription: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value):
            value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(value)
        case .string(let value): "\"\(value)\""
        case .array(let values): "[" + values.map(\.compactDescription).joined(separator: ",") + "]"
        case .object(let values):
            "{"
                + values.keys.sorted()
                .map { "\($0):\(values[$0]!.compactDescription)" }
                .joined(separator: ",")
                + "}"
        }
    }
}

public struct RoomStore: Equatable, Sendable {
    public private(set) var rooms: [RoomRecord]

    public init(rooms: [RoomRecord] = []) {
        self.rooms = rooms
    }

    public subscript(room: String) -> RoomRecord? {
        rooms.first { $0.room == room }
    }

    public var sortedRooms: [RoomRecord] {
        rooms.sorted {
            $0.state.sortRank == $1.state.sortRank
                ? $0.room < $1.room
                : $0.state.sortRank < $1.state.sortRank
        }
    }

    @discardableResult
    public mutating func add(room: String, role: Role, sessionId: String = UUID().uuidString) -> RoomRecord? {
        let name = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, self[name] == nil else { return nil }

        let record = RoomRecord(room: name, role: role, sessionId: sessionId)
        rooms.append(record)
        return record
    }

    @discardableResult
    public mutating func remove(room: String) -> RoomRecord? {
        guard let index = rooms.firstIndex(where: { $0.room == room }) else { return nil }
        return rooms.remove(at: index)
    }

    public mutating func beginJoin(room: String, at date: Date) {
        guard let index = index(of: room) else { return }
        rooms[index].beginJoin(at: date)
    }

    public mutating func endSession(room: String, state: RoomState, at date: Date, reason: String) {
        guard let index = index(of: room) else { return }
        rooms[index].endSession(state: state, at: date, reason: reason)
    }

    @discardableResult
    public mutating func apply(
        _ message: ServerMessage,
        to room: String,
        at date: Date
    ) -> RoomEvent? {
        guard let index = index(of: room) else { return nil }
        return rooms[index].apply(message, at: date)
    }

    private func index(of room: String) -> Int? {
        rooms.firstIndex { $0.room == room }
    }
}

extension RoomStore {
    public static func fixture(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> RoomStore {
        var store = RoomStore()
        store.add(room: "studio-a", role: .viewer, sessionId: "session-studio-a")
        store.add(room: "studio-b", role: .sender, sessionId: "session-studio-b")
        store.add(room: "lobby", role: .viewer, sessionId: "session-lobby")
        store.add(room: "roof-cam", role: .sender, sessionId: "session-roof-cam")

        var wired = store["roof-cam"]!
        let t = now
        wired.beginJoin(at: t)
        wired.apply(
            .joined(
                peerId: "5f0c1e2a-1f2e-4a6f-9c2d-0c1b2a3d4e5f",
                room: "roof-cam",
                role: .sender,
                peer: nil
            ),
            at: t.addingTimeInterval(0.2)
        )
        wired.apply(
            .peerJoined(peer: PeerInfo(id: "9a8b7c6d-1111-2222-3333-444455556666", role: .viewer)),
            at: t.addingTimeInterval(1.4)
        )
        wired.apply(
            .offer(from: "9a8b7c6d-1111-2222-3333-444455556666", sdp: "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n"),
            at: t.addingTimeInterval(2.0)
        )
        wired.apply(
            .iceCandidate(
                from: "9a8b7c6d-1111-2222-3333-444455556666",
                candidate: .object([
                    "candidate": "candidate:842163049 1 udp 1677729535 192.0.2.4 54873 typ srflx",
                    "sdpMid": "0",
                    "sdpMLineIndex": 0,
                ])
            ),
            at: t.addingTimeInterval(2.3)
        )
        store.replace(wired)

        var lobby = store["lobby"]!
        lobby.beginJoin(at: t)
        lobby.apply(
            .error(
                code: ServerMessage.ErrorCode.roleTaken,
                message: "That role is already taken in this room."
            ),
            at: t.addingTimeInterval(0.3)
        )
        store.replace(lobby)

        return store
    }

    public mutating func replace(_ record: RoomRecord) {
        if let index = index(of: record.room) {
            rooms[index] = record
        } else {
            rooms.append(record)
        }
    }
}
