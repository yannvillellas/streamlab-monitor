import Foundation
import SwiftUI
import StreamLabModel

struct AddRoomView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: @MainActor (String, Role) -> Void

    @State private var name = ""
    @State private var role: Role = .viewer

    init(onAdd: @escaping @MainActor (String, Role) -> Void) {
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Room name", text: $name)
                    .accessibilityIdentifier("room-name")

                Picker("Role", selection: $role) {
                    ForEach(Role.allCases, id: \.self) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("room-role")
            }
            .formStyle(.grouped)
            .navigationTitle("New room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(name, role)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("add-room-confirm")
                }
            }
        }
        .frame(minWidth: 320, minHeight: 220)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
