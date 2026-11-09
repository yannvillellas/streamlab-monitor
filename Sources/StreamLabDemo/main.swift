import Foundation
import StreamLabModel
import StreamLabSignalling
import StreamLabStorage

struct DemoArguments {
    var room = "studio-a"
    var role = Role.viewer
    var endpoint = SignallingEndpoint()
    var databaseURL: URL?

    static func parse(_ arguments: [String]) -> DemoArguments {
        var parsed = DemoArguments()
        var positional: [String] = []

        var index = 0
        while index < arguments.count {
            if arguments[index] == "--db", index + 1 < arguments.count {
                parsed.databaseURL = URL(fileURLWithPath: arguments[index + 1])
                index += 2
                continue
            }
            positional.append(arguments[index])
            index += 1
        }

        if positional.count > 0 { parsed.room = positional[0] }
        if positional.count > 1, let role = Role(rawValue: positional[1]) { parsed.role = role }
        if positional.count > 2 {
            parsed.endpoint = SignallingEndpoint(host: positional[2], port: parsed.endpoint.port)
        }
        if positional.count > 3, let port = Int(positional[3]) {
            parsed.endpoint = SignallingEndpoint(host: parsed.endpoint.host, port: port)
        }
        return parsed
    }
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let arguments = DemoArguments.parse(Array(CommandLine.arguments.dropFirst()))
let sessionId = "demo-" + UUID().uuidString.prefix(8)
let client = SignallingClient(endpoint: arguments.endpoint)

var history: RoomEventStore?
if let databaseURL = arguments.databaseURL {
    do {
        let store = try RoomEventStore(databaseURL: databaseURL)
        try store.register(room: arguments.room, role: arguments.role, sessionId: sessionId)
        history = store

        if let replayed = try store.replay(arguments.room) {
            emit(
                "↺ log \(databaseURL.lastPathComponent) · \(replayed.events.count) events"
                    + " · state=\(replayed.state.label)"
                    + " · peer=\(replayed.peer?.id.prefix(8) ?? "none")"
            )
        }
    } catch {
        emit("! storage disabled · \(error)")
    }
}

var store = RoomStore()
store.add(room: arguments.room, role: arguments.role, sessionId: sessionId)
store.beginJoin(room: arguments.room, at: Date())

/// Never lets a storage failure break the demo, but never hides it either.
@MainActor
func persist(_ event: RoomEvent) {
    guard let history else { return }
    do {
        try history.append(event, to: arguments.room, sessionId: sessionId)
    } catch {
        emit("! not stored · \(error)")
    }
}

if let event = store[arguments.room]?.events.last {
    persist(event)
}

emit("→ ws \(arguments.endpoint.displayName) · room \(arguments.room) · role \(arguments.role.rawValue)")

do {
    try await client.connect()
    try await client.send(.join(room: arguments.room, role: arguments.role, sessionId: sessionId))

    while true {
        let message = try await client.receive()

        let event = store.apply(message, to: arguments.room, at: Date())
        if let event {
            persist(event)
        }

        if let record = store[arguments.room] {
            let last = record.events.last?.text ?? message.typeName
            emit("← \(last)")
            emit("   state=\(record.state.label) peer=\(record.peer?.id.prefix(8) ?? "none")")
        }
    }
} catch {
    emit("✕ \(error)")

    let detail = String(describing: error)
    store.endSession(
        room: arguments.room,
        state: .failed(code: "transport", message: detail),
        at: Date(),
        reason: "transport · \(detail)"
    )
    if let event = store[arguments.room]?.events.last {
        persist(event)
    }

    await client.close()
    if let record = store[arguments.room] {
        emit("final state: \(record.state.label)")
    }
}

history?.close()
