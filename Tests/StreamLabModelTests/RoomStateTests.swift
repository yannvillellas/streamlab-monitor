import Foundation
import XCTest

@testable import StreamLabModel

final class RoomStateTransitionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let senderId = "aaaa1111-0000-0000-0000-000000000001"
    private let viewerId = "bbbb2222-0000-0000-0000-000000000002"

    private func record(role: Role = .sender) -> RoomRecord {
        RoomRecord(room: "studio-a", role: role, sessionId: "session-1")
    }

    func testEmptyToOccupiedToEmpty() {
        var room = record()

        XCTAssertEqual(room.state, .unknown)
        XCTAssertNil(room.peer)

        room.beginJoin(at: t0)
        XCTAssertEqual(room.state, .waiting, "dialling and joined-alone look the same")

        room.apply(.joined(peerId: senderId, room: "studio-a", role: .sender, peer: nil), at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(room.state, .waiting)
        XCTAssertNil(room.peer)
        XCTAssertEqual(room.localPeerId, senderId)

        room.apply(.peerJoined(peer: PeerInfo(id: viewerId, role: .viewer)), at: t0.addingTimeInterval(0.2))
        XCTAssertEqual(room.state, .connected)
        XCTAssertEqual(room.peer, PeerInfo(id: viewerId, role: .viewer))

        room.apply(.peerLeft(peerId: viewerId), at: t0.addingTimeInterval(0.3))
        XCTAssertEqual(room.state, .waiting)
        XCTAssertNil(room.peer)
        XCTAssertEqual(room.localPeerId, senderId, "we are still in the room")
    }

    func testJoinedWithPeerGoesStraightToConnected() {
        var room = record(role: .viewer)
        room.beginJoin(at: t0)
        room.apply(
            .joined(peerId: viewerId, room: "studio-a", role: .viewer, peer: PeerInfo(id: senderId, role: .sender)),
            at: t0
        )

        XCTAssertEqual(room.state, .connected)
        XCTAssertEqual(room.peer?.id, senderId)
    }

    func testRoleTakenPutsTheRoomInError() {
        var room = record(role: .viewer)
        room.beginJoin(at: t0)

        room.apply(
            .error(code: ServerMessage.ErrorCode.roleTaken, message: "That role is already taken in this room."),
            at: t0.addingTimeInterval(0.1)
        )

        XCTAssertEqual(
            room.state,
            .failed(code: "role-taken", message: "That role is already taken in this room.")
        )
        XCTAssertTrue(room.state.isFailure)
        XCTAssertEqual(room.state.label, "error")
        XCTAssertNil(room.localPeerId, "a refused join never gave us a peer id")
        XCTAssertFalse(room.isJoined)
    }

    func testOtherErrorsAlsoBecomeFailures() {
        var room = record(role: .viewer)
        room.beginJoin(at: t0)
        room.apply(.error(code: "no-peer", message: "The other peer is no longer connected."), at: t0)

        XCTAssertEqual(room.state, .failed(code: "no-peer", message: "The other peer is no longer connected."))
    }

    func testPeerLeftForAnotherPeerDoesNotDropConnected() {
        var room = record()
        room.beginJoin(at: t0)
        room.apply(.peerJoined(peer: PeerInfo(id: viewerId, role: .viewer)), at: t0)
        XCTAssertEqual(room.state, .connected)

        room.apply(.peerLeft(peerId: "some-other-id"), at: t0)

        XCTAssertEqual(room.state, .connected, "an unrelated peer-left must not change our state")
        XCTAssertEqual(room.peer?.id, viewerId)
    }

    func testSignallingMessagesDoNotChangeMembership() {
        var room = record()
        room.beginJoin(at: t0)
        room.apply(.peerJoined(peer: PeerInfo(id: viewerId, role: .viewer)), at: t0)

        room.apply(.offer(from: viewerId, sdp: "v=0\r\n"), at: t0)
        room.apply(.iceCandidate(from: viewerId, candidate: .object(["sdpMid": "0"])), at: t0)
        room.apply(.answer(from: viewerId, sdp: "v=0\r\n"), at: t0)

        XCTAssertEqual(room.state, .connected)
        XCTAssertEqual(room.peer?.id, viewerId)
    }

    func testEndSessionReturnsToUnknown() {
        var room = record()
        room.beginJoin(at: t0)
        room.apply(.joined(peerId: senderId, room: "studio-a", role: .sender, peer: nil), at: t0)
        room.endSession(state: .unknown, at: t0.addingTimeInterval(1), reason: "disconnected")

        XCTAssertEqual(room.state, .unknown)
        XCTAssertNil(room.localPeerId)
        XCTAssertNil(room.peer)
    }

    func testEventFeedIsCappedAndOrdered() {
        var room = record()
        room.beginJoin(at: t0)

        for index in 0 ..< (RoomRecord.eventLimit * 2) {
            room.apply(.peerLeft(peerId: "peer-\(index)"), at: t0.addingTimeInterval(Double(index)))
        }

        XCTAssertEqual(room.events.count, RoomRecord.eventLimit)
        XCTAssertEqual(room.events.last?.id, 1 + UInt64(RoomRecord.eventLimit * 2))

        let ids = room.events.map(\.id)
        XCTAssertEqual(ids, ids.sorted(), "the feed is append-only")
    }

    func testEventSummaryNamesTheProtocolMessage() {
        var room = record()
        let event = room.apply(
            .joined(peerId: senderId, room: "studio-a", role: .sender, peer: nil),
            at: t0
        )

        XCTAssertEqual(event.direction, .inbound)
        XCTAssertEqual(event.message?.typeName, "joined")
        XCTAssertTrue(event.text.contains("peer none"), event.text)
    }
}

final class RoomStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testAddIsIdempotentAndTrims() {
        var store = RoomStore()

        XCTAssertNotNil(store.add(room: "  studio-a  ", role: .viewer))
        XCTAssertEqual(store.rooms.map(\.room), ["studio-a"])
        XCTAssertNil(store.add(room: "studio-a", role: .sender), "same room twice is a no-op")
        XCTAssertNil(store.add(room: "   ", role: .sender), "blank names are refused")
    }

    func testApplyForUntrackedRoomIsIgnored() {
        var store = RoomStore()
        store.add(room: "studio-a", role: .viewer)

        XCTAssertNil(store.apply(.peerLeft(peerId: "x"), to: "ghost", at: t0))
        XCTAssertEqual(store.rooms.count, 1)
    }

    func testRemoveDropsTheRoom() {
        var store = RoomStore()
        store.add(room: "studio-a", role: .viewer)

        XCTAssertNotNil(store.remove(room: "studio-a"))
        XCTAssertNil(store["studio-a"])
    }

    func testSortedRoomsPutsFailuresFirstAndIsStable() {
        var store = RoomStore()
        store.add(room: "connected", role: .viewer)
        store.add(room: "waiting", role: .viewer)
        store.add(room: "failing", role: .viewer)
        store.add(room: "unknown", role: .viewer)

        store.apply(.peerJoined(peer: PeerInfo(id: "p", role: .sender)), to: "connected", at: t0)
        store.beginJoin(room: "waiting", at: t0)
        store.apply(.error(code: "role-taken", message: "no"), to: "failing", at: t0)

        XCTAssertEqual(store.sortedRooms.map(\.room), ["failing", "connected", "waiting", "unknown"])
    }

    func testFixtureIsDeterministic() {
        let first = RoomStore.fixture()
        let second = RoomStore.fixture()

        XCTAssertEqual(first, second, "the snapshot fixture must not depend on the clock")
        XCTAssertEqual(first.rooms.count, 4)
        XCTAssertEqual(first["roof-cam"]?.state, .connected)
        XCTAssertEqual(first["lobby"]?.state.isFailure, true)
    }
}
