# StreamLab Monitor

A Swift client for the [Stream Lab](https://github.com/yannvillellas/stream-lab) signalling
server. It joins a room, decodes the signalling messages and shows what the room is doing: who
is in it, and what arrived.

There is no media path. The browser client owns the camera and the WebRTC negotiation; this is
the supervision side, and it speaks only the signalling protocol.

- The four room states: unknown, waiting, connected, error.
- Every message of the JSON contract, decoded from `server/src/protocol.ts`.
- An event feed per room, with the offer and ICE traffic the server relays.
- A command-line client, `streamlab-demo`, for watching a room without the app.

## Getting started

Requires Swift 6.4, or Xcode 16 for the app target.

```sh
git clone https://github.com/yannvillellas/stream-lab.git ~/src/stream-lab
(cd ~/src/stream-lab && npm install)
swift test
```

On Fedora 44 the toolchain comes from `swiftly` with `--platform fedora41`: swiftly 1.2.0 does
not know Fedora 44 yet, and the Fedora 41 build of the compiler runs on it.

To watch a real room, start the server and two clients:

```sh
# terminal 1
cd ~/src/stream-lab && npm run dev -w @stream-lab/server

# terminals 2 and 3
swift run streamlab-demo studio-a viewer
swift run streamlab-demo studio-a sender
```

The viewer prints `joined` with no peer, then `peer-joined` when the sender arrives. Kill the
viewer and the sender gets `peer-left` and falls back to waiting, still in the room.

The app target needs Xcode, which means a Mac or the CI runner:

```sh
xcodebuild build -project App/StreamLabMonitor.xcodeproj -scheme StreamLabMonitorApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project App/StreamLabMonitor.xcodeproj -scheme StreamLabMonitorApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## How it works

`StreamLabModel` holds the JSON contract and the state machine, and imports nothing but
Foundation, so it builds and tests on Linux. `ServerMessage` is an enum with one case per
variant of the TypeScript union and a hand-written `init(from:)` that reads `type` first, then
decodes only that branch: the synthesised `Codable` conformance cannot express a union, and
failing on an unknown `type` with a named error is what makes the decoder testable.

`RoomStore` is a struct. A value, so a test copies one, mutates it and compares with `==`. The
app keeps it in `RoomFeed`, a single `@Observable final class` that owns the store and one
`SignallingClient` per room: `connect()` opens the WebSocket, sends `join`, then loops on
`receive()` and applies every message on the MainActor.

`StreamLabSignalling` is an actor over `URLSessionWebSocketTask`. It compiles and runs on Linux
too, which is why the integration tests start the real Node server and check the handshake
instead of mocking it.

`NavigationSplitView` holds the room list and the room detail, with a sheet to add a room. The
same view files serve iOS and macOS.

## What is tested

Against the real server, on Linux: decoding of every message including `peer: null`, the empty
to occupied to empty transitions, `role-taken`, and the `joined` handshake over a real
WebSocket. `swift test` runs 41 tests; the four integration ones start the server on an
ephemeral port and are skipped when the stream-lab checkout is absent.

The app target is built by a macOS runner, not here: CI compiles it for iOS and macOS, runs the
tests on an iPhone simulator picked at runtime, and renders the two screens as PNG artefacts
(`ui-snapshots` from macOS, `ui-snapshots-ios` from the simulator). Nothing has been run on a
device: there is no Xcode and no Mac on this machine, so the app has only ever been compiled
and rendered, never used.

Not in scope: media, WebRTC, camera, authentication, persistence, more than two peers per room.
Only loopback has been exercised — `SignallingEndpoint(host:port:)` takes any host, but nothing
has run against a LAN address or over TLS.

## Status

The model and the transport are done and tested on Linux. The app compiles for iOS and macOS in
CI and renders its two screens, and it has never run on a device or been driven by a human.
