import XCTest

/// End-to-end proof that the app works: the real app, launched in a simulator, opens a real
/// WebSocket to the real signalling server and displays a decoded `joined` event.
///
/// The CI job starts `stream-lab`'s server on 127.0.0.1:8080 before this runs. From the
/// simulator, 127.0.0.1 is the host machine, so the app's default endpoint already points at it.
final class MonitorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testJoiningARoomReachesTheServer() throws {
        let app = XCUIApplication()
        app.launch()

        let addRoom = app.buttons["add-room"]
        XCTAssertTrue(addRoom.waitForExistence(timeout: 30), "the room list never appeared")
        addRoom.tap()

        let nameField = app.textFields["room-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "the add-room form never appeared")
        nameField.tap()
        nameField.typeText("uitest-\(Int(Date().timeIntervalSince1970))")

        let confirm = app.buttons["add-room-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        let connect = app.buttons["connect-toggle"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "the room detail never appeared")
        connect.tap()

        // The badge switches to `waiting` as soon as the join is attempted; the event only
        // appears once the server answered and the decoder produced a ServerMessage.
        let joined = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "joined"))
            .firstMatch
        XCTAssertTrue(
            joined.waitForExistence(timeout: 30),
            "no 'joined' event was displayed: the WebSocket round trip did not complete"
        )

        let waiting = app.staticTexts["waiting"]
        XCTAssertTrue(
            waiting.waitForExistence(timeout: 10),
            "the room should be waiting for a peer after joining alone"
        )
    }
}
