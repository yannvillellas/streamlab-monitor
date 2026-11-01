import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StreamLabModel

public struct SignallingEndpoint: Equatable, Sendable {
    public enum Scheme: String, Sendable {
        case ws
        case wss
    }

    public let scheme: Scheme
    public let host: String
    public let port: Int

    public init(scheme: Scheme = .ws, host: String = "127.0.0.1", port: Int = 8080) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        guard let url = components.url else {
            preconditionFailure("Invalid signalling endpoint \(scheme.rawValue)://\(host):\(port)")
        }
        return url
    }

    public var displayName: String {
        "\(scheme.rawValue)://\(host):\(port)"
    }
}

public enum SignallingTransportError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case unsupportedFrame
    case decodeFailed(String)
    case sendFailed(String)
    case receiveFailed(String)

    public var description: String {
        switch self {
        case .notConnected: "not connected"
        case .unsupportedFrame: "unsupported WebSocket frame"
        case .decodeFailed(let detail): "decoding failed: \(detail)"
        case .sendFailed(let detail): "send failed: \(detail)"
        case .receiveFailed(let detail): "receive failed: \(detail)"
        }
    }
}

public actor SignallingClient {
    public nonisolated let endpoint: SignallingEndpoint

    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isClosed = false

    public init(endpoint: SignallingEndpoint = SignallingEndpoint()) {
        self.endpoint = endpoint

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.configuration = configuration
    }

    public var isOpen: Bool {
        task != nil && !isClosed
    }

    public func connect() throws {
        guard task == nil else { return }

        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: endpoint.url)

        self.session = session
        self.task = task
        self.isClosed = false

        task.resume()
    }

    public func send(_ message: ClientMessage) async throws {
        guard let task, !isClosed else { throw SignallingTransportError.notConnected }

        let text: String
        do {
            text = try message.jsonString()
        } catch {
            throw SignallingTransportError.sendFailed(String(describing: error))
        }

        do {
            try await task.send(.string(text))
        } catch {
            throw SignallingTransportError.sendFailed(String(describing: error))
        }
    }

    public func receive() async throws -> ServerMessage {
        guard let task, !isClosed else { throw SignallingTransportError.notConnected }

        let frame: URLSessionWebSocketTask.Message
        do {
            frame = try await task.receive()
        } catch {
            throw SignallingTransportError.receiveFailed(String(describing: error))
        }

        let data: Data
        switch frame {
        case .string(let text): data = Data(text.utf8)
        case .data(let binary): data = binary
        @unknown default: throw SignallingTransportError.unsupportedFrame
        }

        do {
            return try ServerMessage.decode(from: data)
        } catch {
            throw SignallingTransportError.decodeFailed(String(describing: error))
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    public func join(_ room: String, role: Role, sessionId: String) async throws -> ServerMessage {
        try connect()
        try await send(.join(room: room, role: role, sessionId: sessionId))

        while true {
            let message = try await receive()
            switch message {
            case .joined, .error:
                return message
            default:
                continue
            }
        }
    }
}
