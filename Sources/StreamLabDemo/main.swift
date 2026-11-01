import Foundation
import StreamLabModel
import StreamLabSignalling

struct DemoArguments {
    var room = "studio-a"
    var role = Role.viewer
    var endpoint = SignallingEndpoint()

    static func parse(_ arguments: [String]) -> DemoArguments {
        var parsed = DemoArguments()
        if let room = arguments.first { parsed.room = room }
        if arguments.count > 1, let role = Role(rawValue: arguments[1]) { parsed.role = role }
        if arguments.count > 2 { parsed.endpoint = SignallingEndpoint(host: arguments[2], port: parsed.endpoint.port) }
        if arguments.count > 3, let port = Int(arguments[3]) {
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

var store = RoomStore()
store.add(room: arguments.room, role: arguments.role, sessionId: sessionId)
store.beginJoin(room: arguments.room, at: Date())

emit("→ ws \(arguments.endpoint.displayName) · room \(arguments.room) · role \(arguments.role.rawValue)")

do {
    try await client.connect()
    try await client.send(.join(room: arguments.room, role: arguments.role, sessionId: sessionId))

    while true {
        let message = try await client.receive()

        store.apply(message, to: arguments.room, at: Date())

        if let record = store[arguments.room] {
            let last = record.events.last?.text ?? message.typeName
            emit("← \(last)")
            emit("   state=\(record.state.label) peer=\(record.peer?.id.prefix(8) ?? "none")")
        }
    }
} catch {
    emit("✕ \(error)")
    await client.close()
    if let record = store[arguments.room] {
        emit("final state: \(record.state.label)")
    }
}
