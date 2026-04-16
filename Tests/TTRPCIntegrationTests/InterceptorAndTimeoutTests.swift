import Testing
import Foundation
import NIOCore
import NIOPosix
import SwiftProtobuf
@testable import TTRPCCore
@testable import TTRPCProtobuf
@testable import TTRPCClient
@testable import TTRPCServer
@testable import TTRPCNIOTransport

// MARK: - Thread-safe log for tests

final class ThreadSafeLog: @unchecked Sendable {
    private var _entries: [String] = []
    private let lock = NSLock()

    func append(_ entry: String) {
        lock.withLock { _entries.append(entry) }
    }

    var entries: [String] {
        lock.withLock { _entries }
    }
}

// MARK: - Test Interceptors

/// A client interceptor that records invocations for testing.
final class RecordingClientInterceptor: TTRPCClientInterceptor, @unchecked Sendable {
    private let log = ThreadSafeLog()

    var calls: [String] { log.entries }

    func intercept(
        request: Data,
        context: ClientInterceptorContext,
        next: @Sendable (Data, ClientInterceptorContext) async throws -> Data
    ) async throws -> Data {
        log.append(context.method)
        return try await next(request, context)
    }
}

/// A server interceptor that records invocations for testing.
final class RecordingServerInterceptor: TTRPCServerInterceptor, @unchecked Sendable {
    private let log = ThreadSafeLog()

    var calls: [String] { log.entries }

    func intercept(
        request: Data,
        context: ServerInterceptorContext,
        next: @Sendable (Data, ServerInterceptorContext) async throws -> Data
    ) async throws -> Data {
        log.append(context.method)
        return try await next(request, context)
    }
}

/// A slow echo service that sleeps before responding (for timeout tests).
struct SlowEchoService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.SlowEcho",
            methods: [
                "Echo": TTRPCMethodDescriptor(
                    name: "Echo",
                    handler: { context, requestData in
                        try await Task.sleep(for: .seconds(2))
                        let codec = TTRPCProtobufCodec()
                        let request: EchoRequest = try codec.unmarshal(requestData)
                        let response = EchoResponse(reply: "slow: \(request.message)")
                        return try codec.marshal(response)
                    }
                ),
            ]
        )
    }
}

/// A metadata-echoing service that returns request metadata in the response.
struct MetadataEchoService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.MetadataEcho",
            methods: [
                "Echo": TTRPCMethodDescriptor(
                    name: "Echo",
                    handler: { context, requestData in
                        // Return the metadata as the response message
                        let pairs = context.metadata.pairs
                            .map { "\($0.key)=\($0.value)" }
                            .sorted()
                            .joined(separator: ";")
                        let response = EchoResponse(reply: "metadata: \(pairs)")
                        return try TTRPCProtobufCodec().marshal(response)
                    }
                ),
            ]
        )
    }
}

// MARK: - Tests

@Suite("Interceptor Tests")
struct InterceptorTests {

    @Test("Client interceptor is invoked")
    func clientInterceptor() async throws {
        let socketPath = "/tmp/ttrpc-intercept-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let interceptor = RecordingClientInterceptor()
        let client = try await TTRPCClient.connect(
            socketPath: socketPath,
            interceptors: [interceptor]
        )

        let _: EchoResponse = try await client.call(
            service: "test.Echo",
            method: "Echo",
            request: EchoRequest(message: "hi"),
            responseType: EchoResponse.self
        )

        #expect(interceptor.calls.count == 1)
        #expect(interceptor.calls[0] == "/test.Echo/Echo")

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }

    @Test("Server interceptor is invoked")
    func serverInterceptor() async throws {
        let socketPath = "/tmp/ttrpc-intercept-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let interceptor = RecordingServerInterceptor()
        let server = TTRPCServer(
            services: [EchoService()],
            interceptors: [interceptor]
        )
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        let _: EchoResponse = try await client.call(
            service: "test.Echo",
            method: "Echo",
            request: EchoRequest(message: "hi"),
            responseType: EchoResponse.self
        )

        #expect(interceptor.calls.count == 1)
        #expect(interceptor.calls[0] == "/test.Echo/Echo")

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}

@Suite("Metadata Round-Trip Tests")
struct MetadataRoundTripTests {

    @Test("Metadata is propagated from client to server handler")
    func metadataPropagation() async throws {
        let socketPath = "/tmp/ttrpc-metadata-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [MetadataEchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        let metadata = TTRPCMetadata([
            ("x-request-id", "abc-123"),
            ("x-tenant", "acme"),
        ])

        let response: EchoResponse = try await client.call(
            service: "test.MetadataEcho",
            method: "Echo",
            request: EchoRequest(message: "test"),
            responseType: EchoResponse.self,
            metadata: metadata
        )

        #expect(response.reply.contains("x-request-id=abc-123"))
        #expect(response.reply.contains("x-tenant=acme"))

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}

@Suite("Timeout Tests")
struct TimeoutTests {

    @Test("Client timeout cancels slow request")
    func clientTimeout() async throws {
        let socketPath = "/tmp/ttrpc-timeout-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [SlowEchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        await #expect(throws: TTRPCError.self) {
            let _: EchoResponse = try await client.call(
                service: "test.SlowEcho",
                method: "Echo",
                request: EchoRequest(message: "test"),
                responseType: EchoResponse.self,
                timeout: .milliseconds(100)
            )
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}
