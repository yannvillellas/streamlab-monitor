import Foundation
import XCTest

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@testable import StreamLabModel
@testable import StreamLabSignalling

struct SignallingServerUnavailable: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct SignallingServer {
    let port: Int
    let process: Process
    let logURL: URL

    /// Whether the tests run in CI, where the workflow provisions the server.
    static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// Fails in CI and skips locally: the sibling checkout is optional on a developer machine.
    static func unavailable(_ message: String) -> Error {
        isCI ? SignallingServerUnavailable(message: message) : XCTSkip(message)
    }

    static func resolveRepository() throws -> URL {
        let environment = ProcessInfo.processInfo.environment["STREAM_LAB_DIR"]
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates: [URL] = [
            environment.map { URL(fileURLWithPath: $0) },
            workingDirectory.appendingPathComponent("stream-lab"),
            workingDirectory.deletingLastPathComponent().appendingPathComponent("stream-lab"),
        ].compactMap { $0 }

        for candidate in candidates {
            let entry = candidate
                .appendingPathComponent("server/src/index.ts")
            let tsx = candidate.appendingPathComponent("node_modules/tsx/dist/cli.mjs")
            if FileManager.default.fileExists(atPath: entry.path),
               FileManager.default.fileExists(atPath: tsx.path)
            {
                return candidate
            }
        }

        throw unavailable(
            """
            No usable stream-lab checkout. Expected server/src/index.ts and \
            node_modules/tsx/dist/cli.mjs in STREAM_LAB_DIR or ./stream-lab. \
            Run `npm install` in the stream-lab clone.
            """
        )
    }

    static func start() async throws -> SignallingServer {
        let repository = try resolveRepository()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("signalling-\(UUID().uuidString).log")

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            throw Self.unavailable("Cannot write the server log to \(logURL.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node",
            repository.appendingPathComponent("node_modules/tsx/dist/cli.mjs").path,
            repository.appendingPathComponent("server/src/index.ts").path,
        ]
        process.currentDirectoryURL = repository
        process.standardOutput = logHandle
        process.standardError = logHandle

        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = "0" // let the OS pick, so parallel runs never collide
        environment["HOST"] = "127.0.0.1"
        process.environment = environment

        try process.run()

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)

            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if let range = log.range(of: #"listening on 127\.0\.0\.1:(\d+)"#, options: .regularExpression),
               let port = Int(log[range].split(separator: ":").last ?? "")
            {
                return SignallingServer(port: port, process: process, logURL: logURL)
            }

            if !process.isRunning {
                throw Self.unavailable("The Node server exited early:\n\(log)")
            }
        }

        process.terminate()
        throw Self.unavailable("The Node server did not report a port within 30s")
    }

    var endpoint: SignallingEndpoint {
        SignallingEndpoint(host: "127.0.0.1", port: port)
    }

    /// Kills the child without ever waiting unboundedly: a server that ignores SIGTERM used to
    /// block `waitUntilExit()` and hold the whole test job until its ceiling.
    func stop() {
        guard process.isRunning else { return }

        process.terminate()

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// Races `operation` against a deadline and **does not wait** for the loser.
///
/// A structured task group cannot do this: it awaits its children on exit, and
/// `URLSessionWebSocketTask.receive()` ignores cancellation, so a timed-out wait would keep the
/// whole suite alive. The operation task is abandoned on timeout; it cannot block the tests, and
/// the process exits with the runner.
func withTimeout<T: Sendable>(
    seconds: Double = 10,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let race = TimeoutRace(continuation: continuation)

        let abandoned = Task {
            do {
                race.finish(.success(try await operation()))
            } catch {
                race.finish(.failure(error))
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            abandoned.cancel()
            race.finish(.failure(TimeoutError(seconds: seconds)))
        }
    }
}

private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    /// The first result wins; later ones are dropped, so the continuation is resumed once.
    func finish(_ result: Result<T, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "timed out after \(seconds)s" }
}

final class SignallingIntegrationTests: XCTestCase {
    private var server: SignallingServer?

    override func setUp() async throws {
        #if os(macOS)
        // A hung test fails in a minute instead of holding the job until its ceiling.
        executionTimeAllowance = 60
        #endif
        server = try await SignallingServer.start()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
    }

    func testJoinReceivesJoinedFromTheRealServer() async throws {
        let server = try XCTUnwrap(server)
        let client = SignallingClient(endpoint: server.endpoint)
        defer { Task { await client.close() } }

        let response = try await withTimeout {
            try await client.join("studio-a", role: .viewer, sessionId: "session-a")
        }

        guard case .joined(let peerId, let room, let role, let peer) = response else {
            return XCTFail("Expected .joined, got \(response)")
        }

        XCTAssertFalse(peerId.isEmpty)
        XCTAssertEqual(room, "studio-a")
        XCTAssertEqual(role, .viewer)
        XCTAssertNil(peer, "first client in a room has no peer")
    }

    func testSecondPeerSeesTheFirstAndNotifiesIt() async throws {
        let server = try XCTUnwrap(server)

        let viewer = SignallingClient(endpoint: server.endpoint)
        let sender = SignallingClient(endpoint: server.endpoint)
        defer {
            Task { await sender.close() }
            Task { await viewer.close() }
        }

        let viewerJoin = try await withTimeout {
            try await viewer.join("studio-b", role: .viewer, sessionId: "viewer-session")
        }
        guard case .joined(let viewerId, _, _, _) = viewerJoin else {
            return XCTFail("viewer did not join: \(viewerJoin)")
        }

        let senderJoin = try await withTimeout {
            try await sender.join("studio-b", role: .sender, sessionId: "sender-session")
        }
        guard case .joined(_, _, .sender, let peer) = senderJoin else {
            return XCTFail("sender did not join cleanly: \(senderJoin)")
        }
        XCTAssertEqual(peer?.id, viewerId, "the sender must be paired with the waiting viewer")

        let notification = try await withTimeout {
            let message = try await viewer.receive()
            return message
        }
        guard case .peerJoined(let joined) = notification else {
            return XCTFail("Expected .peerJoined, got \(notification)")
        }
        XCTAssertEqual(joined.role, .sender)
        XCTAssertNotEqual(joined.id, viewerId)
    }

    func testRoleTakenIsReportedAsAnError() async throws {
        let server = try XCTUnwrap(server)

        let first = SignallingClient(endpoint: server.endpoint)
        let second = SignallingClient(endpoint: server.endpoint)
        defer {
            Task { await second.close() }
            Task { await first.close() }
        }

        _ = try await withTimeout {
            try await first.join("studio-c", role: .viewer, sessionId: "first")
        }

        let response = try await withTimeout {
            try await second.join("studio-c", role: .viewer, sessionId: "second")
        }

        guard case .error(let code, let message) = response else {
            return XCTFail("Expected .error, got \(response)")
        }
        XCTAssertEqual(code, ServerMessage.ErrorCode.roleTaken)
        XCTAssertFalse(message.isEmpty)

        var record = RoomRecord(room: "studio-c", role: .viewer)
        record.beginJoin(at: Date())
        record.apply(response, at: Date())
        XCTAssertEqual(record.state, .failed(code: "role-taken", message: message))
    }

    func testConnectionToAClosedPortFails() async throws {
        let client = SignallingClient(endpoint: SignallingEndpoint(port: 1))
        defer { Task { await client.close() } }

        do {
            _ = try await withTimeout(seconds: 10) {
                try await client.join("studio-d", role: .viewer, sessionId: "nowhere")
            }
            XCTFail("Expected a transport failure")
        } catch is TimeoutError {
            XCTFail("The client hung instead of failing")
        } catch {
        }
    }
}
