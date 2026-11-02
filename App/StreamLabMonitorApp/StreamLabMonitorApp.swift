import SwiftUI

@main
@MainActor
struct StreamLabMonitorApp: App {
    @State private var feed = RoomFeed()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(feed)
        }
    }
}
