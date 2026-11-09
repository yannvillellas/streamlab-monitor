import Foundation
import StreamLabModel

/// What the store knows about a room, without reading its events.
public struct StoredRoom: Equatable, Sendable {
    public let room: String
    public let role: Role
    public let sessionId: String
    public let eventCount: Int
    public let lastEventAt: Date?

    public init(
        room: String,
        role: Role,
        sessionId: String,
        eventCount: Int,
        lastEventAt: Date?
    ) {
        self.room = room
        self.role = role
        self.sessionId = sessionId
        self.eventCount = eventCount
        self.lastEventAt = lastEventAt
    }
}

/// An append-only log of room events, in SQLite.
///
/// The log keeps every event, while `RoomRecord` keeps the last
/// `RoomRecord.eventLimit` in memory: the two limits are deliberate. Replaying the
/// log through `RoomRecord` rebuilds the state machine without a second copy of the
/// transition rules.
public final class RoomEventStore {
    public static let schemaVersion: Int64 = 1

    let database: SQLiteDatabase

    /// Opens a database file, creating it and its schema on first use.
    public init(databaseURL: URL) throws {
        database = try SQLiteDatabase(path: databaseURL.path)
        try prepareSchema()

        // WAL keeps a reader from blocking the writer. Memory databases ignore it.
        try database.execute("PRAGMA journal_mode = WAL")
    }

    public static func inMemory() throws -> RoomEventStore {
        let store = RoomEventStore(database: try SQLiteDatabase.inMemory())
        try store.prepareSchema()
        return store
    }

    private init(database: SQLiteDatabase) {
        self.database = database
    }

    public func close() {
        database.close()
    }

    // MARK: Schema

    private func prepareSchema() throws {
        let version = try database.scalarInt("PRAGMA user_version") ?? 0

        if version > Self.schemaVersion {
            throw StorageError.unsupportedSchemaVersion(
                found: version,
                supported: Self.schemaVersion
            )
        }

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS rooms (
                room TEXT PRIMARY KEY,
                role TEXT NOT NULL CHECK (role IN ('sender', 'viewer')),
                session_id TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS events (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                room TEXT NOT NULL REFERENCES rooms(room) ON DELETE CASCADE,
                session_id TEXT NOT NULL,
                event_id INTEGER NOT NULL,
                received_at REAL NOT NULL,
                direction TEXT NOT NULL CHECK (direction IN ('outbound', 'inbound', 'local')),
                text TEXT NOT NULL,
                payload TEXT
            );

            CREATE INDEX IF NOT EXISTS events_by_room ON events(room, seq);

            PRAGMA user_version = \(Self.schemaVersion);
            """
        )
    }

    // MARK: Writing

    /// Registers a room, or updates the session it is being watched with. Events
    /// already stored for that room are kept.
    public func register(room: String, role: Role, sessionId: String) throws {
        let statement = try database.prepare(
            """
            INSERT INTO rooms (room, role, session_id) VALUES (?, ?, ?)
            ON CONFLICT(room) DO UPDATE SET role = excluded.role, session_id = excluded.session_id
            """
        )
        defer { statement.reset() }

        try statement.bind(1, room)
        try statement.bind(2, role.rawValue)
        try statement.bind(3, sessionId)
        _ = try statement.step()
    }

    /// Appends one event and returns its position in the log.
    @discardableResult
    public func append(_ event: RoomEvent, to room: String, sessionId: String) throws -> Int64 {
        let payload: String?
        if let message = event.message {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                payload = String(decoding: try encoder.encode(message), as: UTF8.self)
            } catch {
                throw StorageError.corruptRow(
                    sequence: Int64(event.id),
                    message: String(describing: error)
                )
            }
        } else {
            payload = nil
        }

        let statement = try database.prepare(
            """
            INSERT INTO events (room, session_id, event_id, received_at, direction, text, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { statement.reset() }

        try statement.bind(1, room)
        try statement.bind(2, sessionId)
        try statement.bind(3, Int64(event.id))
        try statement.bind(4, event.receivedAt.timeIntervalSince1970)
        try statement.bind(5, event.direction.rawValue)
        try statement.bind(6, event.text)
        if let payload {
            try statement.bind(7, payload)
        } else {
            try statement.bindNull(7)
        }

        _ = try statement.step()
        return database.lastInsertRowId
    }

    @discardableResult
    public func append(_ events: [RoomEvent], to room: String, sessionId: String) throws -> Int64 {
        var last: Int64 = 0
        for event in events {
            last = try append(event, to: room, sessionId: sessionId)
        }
        return last
    }

    // MARK: Reading

    public func rooms() throws -> [StoredRoom] {
        let statement = try database.prepare(
            """
            SELECT rooms.room, rooms.role, rooms.session_id,
                   COUNT(events.seq), MAX(events.received_at)
            FROM rooms
            LEFT JOIN events ON events.room = rooms.room
            GROUP BY rooms.room
            ORDER BY rooms.room
            """
        )
        defer { statement.reset() }

        var result: [StoredRoom] = []
        while try statement.step() {
            guard let role = Role(rawValue: statement.text(1)) else {
                throw StorageError.corruptRow(
                    sequence: 0,
                    message: "unknown role '\(statement.text(1))' for room '\(statement.text(0))'"
                )
            }

            result.append(
                StoredRoom(
                    room: statement.text(0),
                    role: role,
                    sessionId: statement.text(2),
                    eventCount: Int(statement.int64(3)),
                    lastEventAt: statement.isNull(4)
                        ? nil
                        : Date(timeIntervalSince1970: statement.double(4))
                )
            )
        }
        return result
    }

    public func events(in room: String) throws -> [RoomEvent] {
        let statement = try database.prepare(
            """
            SELECT seq, event_id, received_at, direction, text, payload
            FROM events WHERE room = ? ORDER BY seq
            """
        )
        defer { statement.reset() }
        try statement.bind(1, room)

        var result: [RoomEvent] = []
        while try statement.step() {
            let sequence = statement.int64(0)
            guard let direction = RoomEvent.Direction(rawValue: statement.text(3)) else {
                throw StorageError.corruptRow(
                    sequence: sequence,
                    message: "unknown direction '\(statement.text(3))'"
                )
            }

            let message: ServerMessage?
            if statement.isNull(5) {
                message = nil
            } else {
                do {
                    message = try ServerMessage.decode(from: statement.text(5))
                } catch {
                    throw StorageError.corruptRow(
                        sequence: sequence,
                        message: String(describing: error)
                    )
                }
            }

            result.append(
                RoomEvent(
                    id: UInt64(statement.int64(1)),
                    receivedAt: Date(timeIntervalSince1970: statement.double(2)),
                    direction: direction,
                    text: statement.text(4),
                    message: message
                )
            )
        }
        return result
    }

    /// Reads the log back through the same state machine the client uses.
    ///
    /// A stored payload goes through `apply`, so the transitions are not re-implemented
    /// here. An event without a payload (an outbound send, a local note) is restored
    /// with `record`. Returns nil when the room was never registered.
    public func replay(_ room: String) throws -> RoomRecord? {
        let stored = try rooms().first { $0.room == room }
        guard let stored else { return nil }

        var record = RoomRecord(
            room: stored.room,
            role: stored.role,
            sessionId: stored.sessionId
        )

        for event in try events(in: stored.room) {
            if let message = event.message {
                record.apply(message, at: event.receivedAt)
            } else {
                record.record(text: event.text, direction: event.direction, at: event.receivedAt)
            }
        }
        return record
    }
}
