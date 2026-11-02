import SwiftUI
import StreamLabModel

struct EventFeedView: View {
    let events: [RoomEvent]

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView(
                "No events",
                systemImage: "waveform.path",
                description: Text("Connect the room to watch its signalling traffic.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(symbol(for: event.direction))
                            .frame(width: 14)
                        Text(event.receivedAt, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                        Text(event.direction.rawValue)
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .leading)
                        Text(event.text)
                    }
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }

    private func symbol(for direction: RoomEvent.Direction) -> String {
        switch direction {
        case .outbound: "→"
        case .inbound: "←"
        case .local: "•"
        }
    }
}
