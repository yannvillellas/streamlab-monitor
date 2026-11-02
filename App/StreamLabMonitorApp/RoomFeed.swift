import Foundation
import Observation
import StreamLabModel
import StreamLabSignalling

@MainActor
@Observable
final class RoomFeed {
    private(set) var store: RoomStore
    let endpoint: SignallingEndpoint
    private(set) var busyRooms: Set<String> = []

    @ObservationIgnored private var clients: [String: SignallingClient] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var sessions: [String: UUID] = [:]

    init(store: RoomStore = RoomStore(), endpoint: SignallingEndpoint = SignallingEndpoint()) {
        self.store = store
        self.endpoint = endpoint
    }

    @discardableResult
    func addRoom(name: String, role: Role) -> String? {
        store.add(room: name, role: role)?.room
    }

    func isBusy(_ room: String) -> Bool {
        busyRooms.contains(room)
    }

    func connect(_ room: String) {
        guard tasks[room] == nil, let record = store[room] else { return }

        let client = SignallingClient(endpoint: endpoint)
        let token = UUID()
        let role = record.role
        let sessionId = record.sessionId

        sessions[room] = token
        clients[room] = client
        busyRooms.insert(room)
        store.beginJoin(room: room, at: Date())

        tasks[room] = Task { @MainActor [weak self] in
            defer {
                guard let self else { return }
                if self.sessions[room] == token {
                    self.sessions[room] = nil
                    self.tasks[room] = nil
                    self.clients[room] = nil
                    self.busyRooms.remove(room)
                }
            }

            // Cancellation handler is the only documented way to interrupt a wait that does not observe cancellation; it runs alongside the operation, so it only starts close, without locking or waiting.
            await withTaskCancellationHandler {
                do {
                    try await client.connect()
                    try await client.send(.join(room: room, role: role, sessionId: sessionId))

                    while !Task.isCancelled {
                        let message = try await client.receive()
                        guard let self, self.sessions[room] == token else { break }
                        self.store.apply(message, to: room, at: Date())

                        if case .error = message {
                            break
                        }
                    }
                } catch {
                    if !Task.isCancelled, let self, self.sessions[room] == token {
                        let detail = String(describing: error)
                        self.store.endSession(
                            room: room,
                            state: .failed(code: "transport", message: detail),
                            at: Date(),
                            reason: "transport · \(detail)"
                        )
                    }
                }
            } onCancel: {
                Task { await client.close() }
            }

            await client.close()
        }
    }

    func disconnect(_ room: String) {
        guard let record = store[room], record.state != .unknown else { return }
        tasks[room]?.cancel()
        store.endSession(room: room, state: .unknown, at: Date(), reason: "disconnected")
    }
}
