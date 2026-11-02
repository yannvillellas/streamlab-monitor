import SwiftUI
import StreamLabModel

struct ContentView: View {
    @Environment(RoomFeed.self) private var feed
    @State private var selection: String?
    @State private var isAddingRoom = false

    var body: some View {
        NavigationSplitView {
            RoomListView(selection: $selection)
                .navigationTitle("Rooms")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add room", systemImage: "plus") {
                            isAddingRoom = true
                        }
                        .accessibilityIdentifier("add-room")
                    }
                }
        } detail: {
            if let selection, let room = feed.store[selection] {
                RoomDetailView(room: room)
            } else {
                ContentUnavailableView(
                    "No room selected",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Pick a room in the list or add a new one.")
                )
            }
        }
        .sheet(isPresented: $isAddingRoom) {
            AddRoomView { name, role in
                if let added = feed.addRoom(name: name, role: role) {
                    selection = added
                }
            }
        }
    }
}
