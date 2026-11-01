import Foundation
import XCTest

@testable import StreamLabModel

final class ServerMessageDecodingTests: XCTestCase {
    func testJoinedWithPeerNullDecodesToNilPeer() throws {
        let message = try ServerMessage.decode(from: Fixture.joinedPeerNull)

        XCTAssertEqual(
            message,
            .joined(
                peerId: "f43f04bd-b124-494f-962e-b75329d84d65",
                room: "studio-a",
                role: .sender,
                peer: nil
            )
        )

        guard case .joined(_, _, _, let peer) = message else {
            return XCTFail("Expected .joined, got \(message)")
        }
        XCTAssertNil(peer)
    }

    func testJoinedWithPeerDecodesPeerRole() throws {
        let message = try ServerMessage.decode(from: Fixture.joinedWithPeer)

        XCTAssertEqual(
            message,
            .joined(
                peerId: "f43f04bd-b124-494f-962e-b75329d84d65",
                room: "studio-a",
                role: .viewer,
                peer: PeerInfo(id: "9a8b7c6d-1111-2222-3333-444455556666", role: .sender)
            )
        )
    }

    func testPeerJoined() throws {
        XCTAssertEqual(
            try ServerMessage.decode(from: Fixture.peerJoined),
            .peerJoined(peer: PeerInfo(id: "9a8b7c6d-1111-2222-3333-444455556666", role: .viewer))
        )
    }

    func testPeerLeft() throws {
        XCTAssertEqual(
            try ServerMessage.decode(from: Fixture.peerLeft),
            .peerLeft(peerId: "9a8b7c6d-1111-2222-3333-444455556666")
        )
    }

    func testOfferKeepsSdpVerbatim() throws {
        guard case .offer(let from, let sdp) = try ServerMessage.decode(from: Fixture.offer) else {
            return XCTFail("Expected .offer")
        }

        XCTAssertEqual(from, "9a8b7c6d-1111-2222-3333-444455556666")
        XCTAssertTrue(sdp.hasPrefix("v=0\r\no=- "))
        XCTAssertTrue(sdp.hasSuffix("\r\n"))
    }

    func testAnswer() throws {
        guard case .answer(let from, let sdp) = try ServerMessage.decode(from: Fixture.answer) else {
            return XCTFail("Expected .answer")
        }

        XCTAssertEqual(from, "9a8b7c6d-1111-2222-3333-444455556666")
        XCTAssertTrue(sdp.hasPrefix("v=0\r\n"))
    }

    func testIceCandidateKeepsUntypedPayload() throws {
        guard case .iceCandidate(let from, let candidate) = try ServerMessage.decode(from: Fixture.iceCandidate) else {
            return XCTFail("Expected .iceCandidate")
        }

        XCTAssertEqual(from, "9a8b7c6d-1111-2222-3333-444455556666")

        let object = try XCTUnwrap(candidate.objectValue)
        XCTAssertEqual(object.count, 3)
        XCTAssertEqual(object["sdpMid"], .string("0"))
        XCTAssertEqual(object["sdpMLineIndex"], .number(0))
        XCTAssertEqual(
            object["candidate"],
            .string("candidate:842163049 1 udp 1677729535 192.0.2.4 54873 typ srflx")
        )
    }

    func testErrorWithRoleTakenCode() throws {
        let message = try ServerMessage.decode(from: Fixture.errorRoleTaken)

        XCTAssertEqual(
            message,
            .error(
                code: ServerMessage.ErrorCode.roleTaken,
                message: "That role is already taken in this room."
            )
        )
        XCTAssertEqual(message.typeName, "error")
    }

    func testEveryVariantRoundTripsThroughTheEncoder() throws {
        let samples: [ServerMessage] = [
            .joined(peerId: "p", room: "r", role: .sender, peer: nil),
            .joined(peerId: "p", room: "r", role: .viewer, peer: PeerInfo(id: "q", role: .sender)),
            .peerJoined(peer: PeerInfo(id: "q", role: .viewer)),
            .peerLeft(peerId: "q"),
            .offer(from: "q", sdp: "v=0\r\n"),
            .answer(from: "q", sdp: "v=0\r\n"),
            .iceCandidate(from: "q", candidate: .object(["sdpMid": "0", "sdpMLineIndex": 0])),
            .error(code: "no-peer", message: "Join a room first."),
        ]

        for sample in samples {
            let data = try JSONEncoder().encode(sample)
            XCTAssertEqual(try ServerMessage.decode(from: data), sample, "round-trip of \(sample.typeName)")
        }
    }

    func testJoinedEncodesExplicitNullPeer() throws {
        let data = try JSONEncoder().encode(ServerMessage.joined(peerId: "p", room: "r", role: .sender, peer: nil))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertTrue(object.keys.contains("peer"))
        XCTAssertTrue(object["peer"] is NSNull)
    }

    func testUnknownDiscriminatorThrowsTypedError() {
        XCTAssertThrowsError(try ServerMessage.decode(from: #"{"type":"teleport","room":"a"}"#)) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownMessageType("teleport"))
        }
    }

    func testMissingDiscriminatorThrows() {
        XCTAssertThrowsError(try ServerMessage.decode(from: #"{"room":"a"}"#))
    }

    func testMissingFieldThrows() {
        XCTAssertThrowsError(try ServerMessage.decode(from: #"{"type":"peer-joined"}"#))
    }

    func testUnknownRoleThrows() {
        XCTAssertThrowsError(
            try ServerMessage.decode(
                from: #"{"type":"joined","peerId":"p","room":"r","role":"operator","peer":null}"#
            )
        )
    }
}

final class ClientMessageEncodingTests: XCTestCase {
    private func assertJSON(_ message: ClientMessage, equals expected: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try message.jsonData()) as? [String: Any]
        )
        let wanted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(expected.utf8)) as? [String: Any]
        )

        XCTAssertEqual(actual as NSDictionary, wanted as NSDictionary, file: file, line: line)
    }

    func testJoinMatchesTheContract() throws {
        try assertJSON(
            .join(room: "studio-a", role: .viewer, sessionId: "session-1"),
            equals: Fixture.clientJoin
        )
    }

    func testOffer() throws {
        try assertJSON(.offer(sdp: "v=0\r\n"), equals: Fixture.clientOffer)
    }

    func testAnswer() throws {
        try assertJSON(.answer(sdp: "v=0\r\n"), equals: Fixture.clientAnswer)
    }

    func testIceCandidate() throws {
        try assertJSON(
            .iceCandidate(.object([
                "candidate": "candidate:1 1 udp 1 192.0.2.4 5000 typ host",
                "sdpMid": "0",
                "sdpMLineIndex": 0,
            ])),
            equals: Fixture.clientIceCandidate
        )
    }

    func testLeave() throws {
        try assertJSON(.leave, equals: Fixture.clientLeave)
    }

    func testJoinWithoutSessionIdIsRejected() {
        XCTAssertThrowsError(try ClientMessage.decode(from: #"{"type":"join","room":"a","role":"sender"}"#))
    }

    func testJoinWithBlankRoomIsRejected() {
        XCTAssertThrowsError(
            try ClientMessage.decode(from: #"{"type":"join","room":"   ","role":"sender","sessionId":"s"}"#)
        )
    }

    func testIceCandidateMustBeAnObject() {
        XCTAssertThrowsError(
            try ClientMessage.decode(from: #"{"type":"ice-candidate","candidate":"not-an-object"}"#)
        )
    }
}

extension ClientMessage {
    static func decode(from text: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8))
    }
}
