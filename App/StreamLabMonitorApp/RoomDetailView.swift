import SwiftUI
import StreamLabModel

struct RoomDetailView: View {
    let room: RoomRecord

    var body: some View {
        ScrollView {
            RoomDetailContent(room: room)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(room.room)
    }
}

struct RoomDetailContent: View {
    let room: RoomRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoomHeader(room: room)
            Divider()
            EventFeedView(events: room.events)
        }
    }
}

struct RoomHeader: View {
    @Environment(RoomFeed.self) private var feed
    let room: RoomRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(room.room)
                    .font(.title2.weight(.semibold))

                RoomStateBadge(state: room.state)

                Spacer(minLength: 12)

                Button {
                    if room.isJoined {
                        feed.disconnect(room.room)
                    } else {
                        feed.connect(room.room)
                    }
                } label: {
                    Text(room.isJoined ? "Disconnect" : "Connect")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(room.isJoined ? Color.red : Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!room.isJoined && feed.isBusy(room.room))
                .accessibilityIdentifier("connect-toggle")
            }

            HStack(alignment: .top, spacing: 28) {
                field("Role", room.role.rawValue)
                field("Peer", room.peer?.id ?? "none")
            }
        }
        .padding(16)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
