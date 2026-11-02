import SwiftUI
import StreamLabModel

struct RoomStateBadge: View {
    let state: RoomState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.caption.monospaced())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .accessibilityLabel(state.label)
    }

    private var color: Color {
        switch state {
        case .unknown: .gray
        case .waiting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}
