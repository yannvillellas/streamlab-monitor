import SwiftUI
import StreamLabModel

struct RoomListView: View {
    @Environment(RoomFeed.self) private var feed
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(feed.store.sortedRooms) { room in
                RoomRow(room: room)
                    .tag(room.room)
            }
        }
        .overlay {
            if feed.store.rooms.isEmpty {
                ContentUnavailableView(
                    "No rooms",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Add a room to start monitoring its signalling traffic.")
                )
            }
        }
    }
}

struct RoomRow: View {
    let room: RoomRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(room.room)
                    .font(.headline)
                Text(room.role.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            RoomStateBadge(state: room.state)
        }
        .padding(.vertical, 2)
    }
}
