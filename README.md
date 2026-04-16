# ttrpc-swift

A pure-Swift implementation of the [containerd ttrpc protocol](https://github.com/containerd/ttrpc) — a lightweight RPC framework for low-latency IPC over Unix domain sockets.

Wire-compatible with the Go and Rust implementations.

## Features

- **Unary RPCs** — single request, single response
- **Streaming RPCs** — client-streaming, server-streaming, and bidirectional
- **Interceptors** — client and server middleware chains
- **Metadata** — key-value pairs propagated with requests via `@TaskLocal`
- **Timeouts** — deadline enforcement with automatic cancellation
- **Unix credentials** — peer UID/GID extraction via `SO_PEERCRED` / `LOCAL_PEERCRED`
- **Code generation** — `protoc-gen-swift-ttrpc` plugin generates typed stubs from `.proto` files
- **Swift 6** — strict concurrency, `async`/`await`, structured concurrency throughout

## Requirements

- Swift 6.1+
- macOS 15+ or Linux

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/ttrpc-swift.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "TTRPC", package: "ttrpc-swift"),
        ]
    ),
]
```

## Quick Start

### Server

```swift
import TTRPCCore
import TTRPCServer
import TTRPCProtobuf

// Implement the service protocol (or use generated stubs)
struct MyEchoService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "example.Echo",
            methods: [
                "Echo": TTRPCMethodDescriptor(name: "Echo") { context, data in
                    let codec = TTRPCProtobufCodec()
                    let request: EchoRequest = try codec.unmarshal(data)
                    let response = EchoResponse.with { $0.reply = "echo: \(request.message)" }
                    return try codec.marshal(response)
                },
            ]
        )
    }
}

let server = TTRPCServer(services: [MyEchoService()])
try await server.serve(unixDomainSocketPath: "/tmp/my-service.sock")
```

### Client

```swift
import TTRPCClient

let client = try await TTRPCClient.connect(socketPath: "/tmp/my-service.sock")

let response: EchoResponse = try await client.call(
    service: "example.Echo",
    method: "Echo",
    request: EchoRequest.with { $0.message = "hello" },
    responseType: EchoResponse.self
)
print(response.reply) // "echo: hello"

await client.close()
```

### Code Generation

Generate typed client and server stubs from `.proto` service definitions:

```bash
# Build the plugin
swift build --product protoc-gen-swift-ttrpc

# Generate both message types and ttrpc stubs
protoc \
    --swift_out=. \
    --plugin=protoc-gen-swift-ttrpc=.build/debug/protoc-gen-swift-ttrpc \
    --swift-ttrpc_out=. \
    your_service.proto
```

This produces a `.ttrpc.swift` file with:
- A server **protocol** (`YourService_TTRPCService`) with async method stubs
- A **service descriptor** extension for registration
- A typed **client struct** (`YourService_TTRPCClient`) with call methods

### Streaming

```swift
// Server-streaming: client sends one request, receives a stream
let stream = try await client.makeStream(
    service: "example.Events", method: "Subscribe",
    request: subscribeRequest,
    responseType: Event.self,
    clientStreaming: false, serverStreaming: true
)
for try await event in stream.responses {
    print(event)
}

// Client-streaming: client sends a stream, receives one response
let stream = try await client.makeStream(
    service: "example.Batch", method: "Upload",
    request: BatchRequest(),
    responseType: BatchResponse.self,
    clientStreaming: true, serverStreaming: false
)
for item in items {
    try await stream.send(item)
}
let response = try await stream.closeAndReceive()
```

### Interceptors

```swift
struct LoggingInterceptor: TTRPCClientInterceptor {
    func intercept(
        request: Data,
        context: ClientInterceptorContext,
        next: @Sendable (Data, ClientInterceptorContext) async throws -> Data
    ) async throws -> Data {
        print("Calling \(context.method)")
        return try await next(request, context)
    }
}

let client = try await TTRPCClient.connect(
    socketPath: "/tmp/service.sock",
    interceptors: [LoggingInterceptor()]
)
```

## Architecture

```
TTRPCCore          Protocol types (Frame, StreamState, Metadata, Interceptors)
TTRPCProtobuf      Protobuf codec + generated Request/Response messages
TTRPCNIOTransport  SwiftNIO frame encoder/decoder, Unix socket transport
TTRPCClient        Client with unary + streaming RPCs
TTRPCServer        Server with service registration and dispatch
protoc-gen-swift-ttrpc  Code generation plugin
```

## Protocol

The ttrpc wire protocol uses a 10-byte header + variable payload:

| Bytes | Field | Description |
|-------|-------|-------------|
| 0-3 | Length | Data length (uint32 big-endian, first byte reserved = 0) |
| 4-7 | Stream ID | Stream identifier (uint32 big-endian) |
| 8 | Type | Message type: Request(0x01), Response(0x02), Data(0x03) |
| 9 | Flags | remoteClosed(0x01), remoteOpen(0x02), noData(0x04) |

Max message size: 4 MB. Stream IDs: odd = client-initiated, even = server-initiated.

See the full [protocol specification](https://github.com/containerd/ttrpc/blob/main/PROTOCOL.md).

## License

Apache License 2.0
