import Foundation
import SwiftUI
import XCTest

import StreamLabModel
import StreamLabSignalling
@testable import StreamLabMonitorApp

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

final class SnapshotTests: XCTestCase {
    @MainActor
    func testRoomListRendersAPNG() async throws {
        let feed = RoomFeed(store: RoomStore.fixture())
        let view = NavigationSplitView {
            RoomListView(selection: .constant("roof-cam" as String?))
        } detail: {
            Color.white
        }
        .environment(feed)
        .environment(\.colorScheme, .light)

        try render(view, size: CGSize(width: 440, height: 640), name: "room-list.png")
    }

    @MainActor
    func testRoomDetailWithEventsRendersAPNG() async throws {
        let store = RoomStore.fixture()
        let room = try XCTUnwrap(store["roof-cam"])
        XCTAssertGreaterThanOrEqual(room.events.count, 2, "the detail snapshot needs a filled feed")

        let feed = RoomFeed(store: store)
        let view = RoomDetailView(room: room)
            .environment(feed)
            .environment(\.colorScheme, .light)

        try render(view, size: CGSize(width: 780, height: 640), name: "room-detail.png")
    }

    @MainActor
    private func render(_ content: some View, size: CGSize, name: String) throws {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 2

        let data: Data
        #if os(macOS)
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("Could not render \(name) on macOS")
            return
        }
        data = png
        #elseif os(iOS)
        guard let image = renderer.uiImage, let png = image.pngData() else {
            XCTFail("Could not render \(name) on iOS")
            return
        }
        data = png
        #else
        XCTFail("Unsupported platform for \(name)")
        return
        #endif

        let url = try snapshotDirectory().appendingPathComponent(name)
        try data.write(to: url, options: .atomic)

        XCTAssertGreaterThan(data.count, 0, "\(name) is empty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        print("snapshot: \(url.path)")
    }

    private func snapshotDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["SNAPSHOT_OUTPUT_DIR"] ?? environment["TEST_RUNNER_SNAPSHOT_OUTPUT_DIR"]

        if let raw = configured, !raw.isEmpty {
            let directory = URL(fileURLWithPath: raw, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        let local = URL(fileURLWithPath: "snapshots", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)) != nil {
            return local
        }

        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}
