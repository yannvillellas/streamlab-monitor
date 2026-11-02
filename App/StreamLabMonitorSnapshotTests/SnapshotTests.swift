import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import XCTest

import StreamLabModel
@testable import StreamLabMonitorApp

#if os(macOS)
import AppKit
#endif

final class SnapshotTests: XCTestCase {
    @MainActor
    func testRoomListRendersAPNG() async throws {
        let store = RoomStore.fixture()

        let view = VStack(alignment: .leading, spacing: 0) {
            Text("Rooms")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            ForEach(store.sortedRooms) { room in
                RoomRow(room: room)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)

        try render(view, size: CGSize(width: 440, height: 480), name: "room-list.png")
    }

    @MainActor
    func testRoomDetailWithEventsRendersAPNG() async throws {
        let store = RoomStore.fixture()
        let room = try XCTUnwrap(store["roof-cam"])
        XCTAssertGreaterThanOrEqual(room.events.count, 2, "the detail snapshot needs a filled feed")

        let feed = RoomFeed(store: store)
        let view = RoomDetailContent(room: room)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
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
        XCTAssertGreaterThan(
            distinctColors(in: data),
            5,
            "\(name) looks blank or like the ImageRenderer placeholder, not a rendered view"
        )
        print("snapshot: \(url.path)")
    }

    private func distinctColors(in data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return 0
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return 0 }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return 0
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var colors = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4 * 7) {
            let red = UInt32(pixels[index])
            let green = UInt32(pixels[index + 1])
            let blue = UInt32(pixels[index + 2])
            colors.insert((red << 16) | (green << 8) | blue)
            if colors.count > 64 { break }
        }
        return colors.count
    }

    private func snapshotDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["SNAPSHOT_OUTPUT_DIR"] ?? environment["TEST_RUNNER_SNAPSHOT_OUTPUT_DIR"]

        if let raw = configured, !raw.isEmpty {
            let directory = URL(fileURLWithPath: raw, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}
