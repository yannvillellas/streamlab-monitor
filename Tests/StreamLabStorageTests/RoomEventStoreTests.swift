import Foundation
import XCTest

@testable import StreamLabModel
@testable import StreamLabStorage

final class RoomEventStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let senderId = "aaaa1111-0000-0000-0000-000000000001"
    private let viewerId = "bbbb2222-0000-0000-0000-000000000002"

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        temporaryFiles = []
        super.tearDown()
    }

    private func temporaryDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamlab-storage-\(UUID().uuidString).sqlite")
        temporaryFiles.append(url)
        return url
    }

    private func registerStudioA(in store: RoomEventStore, role: Role = .sender) throws {
        try store.register(room: "studio-a", role: role, sessionId: "session-1")
    }

    // MARK: Schema

    func testFirstUseCreatesARealSQLiteFile() throws {
        let url = temporaryDatabaseURL()
        let store = try RoomEventStore(databaseURL: url)

        XCTAssertEqual(try store.database.scalarInt("PRAGMA user_version"), RoomEventStore.schemaVersion)
        XCTAssertEqual(try store.rooms(), [])
        store.close()

        let header = try Data(contentsOf: url).prefix(15)
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "SQLite format 3")

        let reopened = try RoomEventStore(databaseURL: url)
        XCTAssertEqual(try reopened.rooms(), [])
        reopened.close()
    }

    func testANewerSchemaIsRefusedInsteadOfReadBlindly() throws {
        let url = temporaryDatabaseURL()

        let store = try RoomEventStore(databaseURL: url)
        try store.database.execute("PRAGMA user_version = 99")
        store.close()

        XCTAssertThrowsError(try RoomEventStore(databaseURL: url)) { error in
            guard case StorageError.unsupportedSchemaVersion(let found, let supported) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, RoomEventStore.schemaVersion)
        }
    }

    // MARK: Writing and reading

    func testAppendThenReadKeepsTheFrame() throws {
        let store = try RoomEventStore.inMemory()
        try registerStudioA(in: store)

        let event = RoomEvent(
            id: 1,
            receivedAt: t0,
            direction: .inbound,
            text: "peer-joined · viewer 9a8b7c6d",
            message: .peerJoined(peer: PeerInfo(id: viewerId, role: .viewer))
        )

        let sequence = try store.append(event, to: "studio-a", sessionId: "session-1")
        XCTAssertGreaterThan(sequence, 0)

        let read = try store.events(in: "studio-a")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].id, 1)
        XCTAssertEqual(read[0].direction, .inbound)
        XCTAssertEqual(read[0].text, event.text)
        XCTAssertEqual(read[0].message, event.message)
        XCTAssertEqual(
            read[0].receivedAt.timeIntervalSince1970,
            t0.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testAnEventWithoutAPayloadIsStoredAndRestored() throws {
        let store = try RoomEventStore.inMemory()
        try registerStudioA(in: store, role: .viewer)

        try store.append(
            RoomEvent(id: 1, receivedAt: t0, direction: .local, text: "connecting"),
            to: "studio-a",
            sessionId: "session-1"
        )
        try store.append(
            RoomEvent(id: 2, receivedAt: t0, direction: .outbound, text: "join studio-a viewer"),
            to: "studio-a",
            sessionId: "session-1"
        )

        let read = try store.events(in: "studio-a")
        XCTAssertEqual(read.map(\.direction), [.local, .outbound])
        XCTAssertEqual(read.map(\.message), [nil, nil])

        let replayed = try XCTUnwrap(try store.replay("studio-a"))
        XCTAssertEqual(replayed.events.map(\.text), ["connecting", "join studio-a viewer"])
        XCTAssertEqual(replayed.events.map(\.direction), [.local, .outbound])
    }

    func testUnknownRoomReplaysToNil() throws {
        let store = try RoomEventStore.inMemory()
        XCTAssertNil(try store.replay("studio-a"))
    }

    // MARK: Replay

    func testReplayRebuildsTheStateMachineFromTheStoredFrames() throws {
        let store = try RoomEventStore.inMemory()
        try registerStudioA(in: store)

        var live = RoomRecord(room: "studio-a", role: .sender, sessionId: "session-1")
        live.beginJoin(at: t0)
        try store.append(live.events, to: "studio-a", sessionId: "session-1")

        let steps: [(Double, ServerMessage)] = [
            (0.1, .joined(peerId: senderId, room: "studio-a", role: .sender, peer: nil)),
            (0.2, .peerJoined(peer: PeerInfo(id: viewerId, role: .viewer))),
            (0.3, .offer(from: viewerId, sdp: "v=0\r\n")),
            (0.4, .peerLeft(peerId: viewerId)),
        ]

        for (offset, message) in steps {
            live.apply(message, at: t0.addingTimeInterval(offset))
            try store.append(
                try XCTUnwrap(live.events.last),
                to: "studio-a",
                sessionId: "session-1"
            )
        }

        XCTAssertEqual(live.state, .waiting)
        XCTAssertEqual(live.events.count, 5)

        let replayed = try XCTUnwrap(try store.replay("studio-a"))
        XCTAssertEqual(replayed.state, live.state)
        XCTAssertEqual(replayed.peer, live.peer)
        XCTAssertEqual(replayed.localPeerId, live.localPeerId)
        XCTAssertEqual(replayed.role, live.role)
        XCTAssertEqual(replayed.sessionId, live.sessionId)
        XCTAssertEqual(replayed.events.map(\.text), live.events.map(\.text))
        XCTAssertEqual(replayed.events.map(\.id), live.events.map(\.id))
    }

    func testReplayOfARefusedJoinEndsInFailure() throws {
        let store = try RoomEventStore.inMemory()
        try registerStudioA(in: store, role: .viewer)

        var live = RoomRecord(room: "studio-a", role: .viewer, sessionId: "session-1")
        live.beginJoin(at: t0)
        live.apply(
            .error(code: ServerMessage.ErrorCode.roleTaken, message: "That role is already taken."),
            at: t0.addingTimeInterval(0.1)
        )
        try store.append(live.events, to: "studio-a", sessionId: "session-1")

        let replayed = try XCTUnwrap(try store.replay("studio-a"))
        XCTAssertEqual(
            replayed.state,
            .failed(code: "role-taken", message: "That role is already taken.")
        )
        XCTAssertNil(replayed.localPeerId)
        XCTAssertFalse(replayed.isJoined)
    }

    func testTheLogKeepsMoreEventsThanTheInMemoryFeed() throws {
        let store = try RoomEventStore.inMemory()
        try registerStudioA(in: store)

        var live = RoomRecord(room: "studio-a", role: .sender, sessionId: "session-1")
        live.beginJoin(at: t0)
        try store.append(live.events, to: "studio-a", sessionId: "session-1")

        live.apply(.peerJoined(peer: PeerInfo(id: viewerId, role: .viewer)), at: t0)
        try store.append(
            try XCTUnwrap(live.events.last),
            to: "studio-a",
            sessionId: "session-1"
        )

        for index in 0 ..< (RoomRecord.eventLimit * 3) {
            live.apply(.peerLeft(peerId: "peer-\(index)"), at: t0.addingTimeInterval(Double(index)))
            try store.append(
                try XCTUnwrap(live.events.last),
                to: "studio-a",
                sessionId: "session-1"
            )
        }

        XCTAssertEqual(live.events.count, RoomRecord.eventLimit)

        let log = try store.events(in: "studio-a")
        XCTAssertEqual(log.count, 2 + RoomRecord.eventLimit * 3)
        XCTAssertEqual(log.map(\.id), log.map(\.id).sorted())

        let replayed = try XCTUnwrap(try store.replay("studio-a"))
        XCTAssertEqual(replayed.events.count, RoomRecord.eventLimit)
        XCTAssertEqual(replayed.state, live.state)
        XCTAssertEqual(
            replayed.state,
            .connected,
            "a peer-left naming an unknown peer does not drop the connection"
        )
        XCTAssertEqual(replayed.peer?.id, viewerId)
    }

    func testASecondSessionKeepsTheEarlierHistory() throws {
        let store = try RoomEventStore.inMemory()
        try registerStudioA(in: store)

        try store.append(
            RoomEvent(id: 1, receivedAt: t0, direction: .local, text: "connecting"),
            to: "studio-a",
            sessionId: "session-1"
        )

        try store.register(room: "studio-a", role: .viewer, sessionId: "session-2")
        try store.append(
            RoomEvent(
                id: 1,
                receivedAt: t0.addingTimeInterval(60),
                direction: .inbound,
                text: "peer-joined · sender aaaa1111",
                message: .peerJoined(peer: PeerInfo(id: senderId, role: .sender))
            ),
            to: "studio-a",
            sessionId: "session-2"
        )

        let rooms = try store.rooms()
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms[0].role, .viewer)
        XCTAssertEqual(rooms[0].sessionId, "session-2")
        XCTAssertEqual(rooms[0].eventCount, 2)
        let lastEventAt = try XCTUnwrap(rooms[0].lastEventAt)
        XCTAssertEqual(
            lastEventAt.timeIntervalSince1970,
            t0.addingTimeInterval(60).timeIntervalSince1970,
            accuracy: 0.001
        )

        let log = try store.events(in: "studio-a")
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log.map(\.id), [1, 1], "the same event id appears once per session")
    }

    func testHistorySurvivesReopeningTheFile() throws {
        let url = temporaryDatabaseURL()

        let store = try RoomEventStore(databaseURL: url)
        try registerStudioA(in: store)
        var live = RoomRecord(room: "studio-a", role: .sender, sessionId: "session-1")
        live.beginJoin(at: t0)
        live.apply(.joined(peerId: senderId, room: "studio-a", role: .sender, peer: nil), at: t0)
        try store.append(live.events, to: "studio-a", sessionId: "session-1")
        store.close()

        let reopened = try RoomEventStore(databaseURL: url)
        let replayed = try XCTUnwrap(try reopened.replay("studio-a"))
        XCTAssertEqual(replayed.state, .waiting)
        XCTAssertEqual(replayed.localPeerId, senderId)
        XCTAssertEqual(replayed.events.count, 2)
        reopened.close()
    }

    // MARK: Failures

    func testACorruptPayloadIsReportedNotSkipped() throws {
        let store = try RoomEventStore.inMemory()
        try registerStudioA(in: store)

        try store.append(
            RoomEvent(
                id: 1,
                receivedAt: t0,
                direction: .inbound,
                text: "peer-left · x",
                message: .peerLeft(peerId: viewerId)
            ),
            to: "studio-a",
            sessionId: "session-1"
        )
        try store.database.execute("UPDATE events SET payload = 'not a message'")

        XCTAssertThrowsError(try store.events(in: "studio-a")) { error in
            guard case StorageError.corruptRow(let sequence, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(sequence, 1)
        }
        XCTAssertThrowsError(try store.replay("studio-a"))
    }

    func testAppendingToAnUnknownRoomFailsOnTheForeignKey() throws {
        let store = try RoomEventStore.inMemory()

        XCTAssertThrowsError(
            try store.append(
                RoomEvent(id: 1, receivedAt: t0, direction: .local, text: "orphan"),
                to: "nowhere",
                sessionId: "session-1"
            )
        )
        XCTAssertEqual(try store.events(in: "nowhere"), [])
    }
}
