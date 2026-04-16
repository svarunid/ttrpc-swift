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

// MARK: - Slow Service for in-flight request tests

struct DelayEchoService: TTRPCServiceRegistration {
    let delay: Duration

    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.DelayEcho",
            methods: [
                "Echo": TTRPCMethodDescriptor(
                    name: "Echo",
                    handler: { [delay] context, requestData in
                        try await Task.sleep(for: delay)
                        let codec = TTRPCProtobufCodec()
                        let request: EchoRequest = try codec.unmarshal(requestData)
                        let response = EchoResponse(reply: "delayed: \(request.message)")
                        return try codec.marshal(response)
                    }
                ),
            ]
        )
    }
}

/// Service that reports whether the deadline was set in the handler context.
struct DeadlineReportService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.DeadlineReport",
            methods: [
                "Check": TTRPCMethodDescriptor(
                    name: "Check",
                    handler: { context, requestData in
                        let codec = TTRPCProtobufCodec()
                        let hasDeadline = context.deadline != nil
                        let response = EchoResponse(reply: "deadline=\(hasDeadline)")
                        return try codec.marshal(response)
                    }
                ),
            ]
        )
    }
}

// MARK: - Server Lifecycle Tests (mirrors Go: TestServerShutdown, TestServerClose, etc.)

@Suite("Server Lifecycle Tests")
struct ServerLifecycleTests {

    @Test("Graceful shutdown completes in-flight requests")
    func shutdownWithInflightRequests() async throws {
        let socketPath = "/tmp/ttrpc-lifecycle-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        // Service with a 150ms delay
        let server = TTRPCServer(services: [DelayEchoService(delay: .milliseconds(150))])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        // Start a call that will be in-flight when we shutdown
        let callTask = Task {
            try await client.call(
                service: "test.DelayEcho",
                method: "Echo",
                request: EchoRequest(message: "inflight"),
                responseType: EchoResponse.self
            )
        }

        // Let the request reach the server, then shutdown
        try await waitForSocket(socketPath)
        server.shutdown()

        // The in-flight request should still complete (graceful shutdown)
        let response = try await callTask.value
        #expect(response.reply == "delayed: inflight")

        await client.close()
        serverTask.cancel()
    }

    @Test("Server cancellation stops accepting new connections")
    func serverCancellation() async throws {
        let socketPath = "/tmp/ttrpc-lifecycle-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        // First client works fine
        let client1 = try await TTRPCClient.connect(socketPath: socketPath)
        let resp: EchoResponse = try await client1.call(
            service: "test.Echo", method: "Echo",
            request: EchoRequest(message: "before"),
            responseType: EchoResponse.self
        )
        #expect(resp.reply == "echo: before")
        await client1.close()

        // Shutdown the server and wait for it to fully stop
        server.shutdown()
        _ = try? await serverTask.value

        // Socket file should be cleaned up
        let exists = FileManager.default.fileExists(atPath: socketPath)
        #expect(!exists)
    }

    @Test("Immediate server shutdown shortly after init does not hang")
    func immediateShutdown() async throws {
        let socketPath = "/tmp/ttrpc-lifecycle-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }

        // Shutdown immediately without any clients connecting
        try await Task.sleep(for: .milliseconds(10))
        server.shutdown()

        // Should not hang -- wait with timeout
        let completed = await Task {
            try? await serverTask.value
            return true
        }.value
        #expect(completed)
    }
}

// MARK: - Client Resilience Tests (mirrors Go: TestClientEOF)

@Suite("Client Resilience Tests")
struct ClientResilienceTests {

    @Test("Client receives error after server closes")
    func clientAfterServerClose() async throws {
        let socketPath = "/tmp/ttrpc-resilience-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        // First call succeeds
        let resp: EchoResponse = try await client.call(
            service: "test.Echo", method: "Echo",
            request: EchoRequest(message: "ok"),
            responseType: EchoResponse.self
        )
        #expect(resp.reply == "echo: ok")

        // Kill the server
        server.shutdown()
        serverTask.cancel()
        try await Task.sleep(for: .milliseconds(50))

        // Subsequent call should fail
        await #expect(throws: Error.self) {
            let _: EchoResponse = try await client.call(
                service: "test.Echo", method: "Echo",
                request: EchoRequest(message: "after-close"),
                responseType: EchoResponse.self
            )
        }

        await client.close()
    }
}

// MARK: - Concurrent Request Tests (mirrors Go: TestServer concurrent goroutines)

@Suite("Concurrent Request Tests")
struct ConcurrentRequestTests {

    @Test("Multiple concurrent unary calls on single connection")
    func concurrentUnaryCalls() async throws {
        let socketPath = "/tmp/ttrpc-concurrent-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        // Fire 20 concurrent requests on the same connection
        let count = 20
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<count {
                group.addTask {
                    let resp: EchoResponse = try await client.call(
                        service: "test.Echo", method: "Echo",
                        request: EchoRequest(message: "msg-\(i)"),
                        responseType: EchoResponse.self
                    )
                    return (i, resp.reply)
                }
            }

            var results: [Int: String] = [:]
            for try await (i, reply) in group {
                results[i] = reply
            }

            #expect(results.count == count)
            for i in 0..<count {
                #expect(results[i] == "echo: msg-\(i)")
            }
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }

    @Test("Multiple clients connecting to same server")
    func multipleClients() async throws {
        let socketPath = "/tmp/ttrpc-concurrent-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let clientCount = 5
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<clientCount {
                group.addTask {
                    let client = try await TTRPCClient.connect(socketPath: socketPath)
                    let resp: EchoResponse = try await client.call(
                        service: "test.Echo", method: "Echo",
                        request: EchoRequest(message: "client-\(i)"),
                        responseType: EchoResponse.self
                    )
                    await client.close()
                    return resp.reply
                }
            }

            var replies: [String] = []
            for try await reply in group {
                replies.append(reply)
            }
            #expect(replies.count == clientCount)
        }

        server.shutdown()
        serverTask.cancel()
    }
}

// MARK: - Deadline Propagation Tests (mirrors Go: TestServerRequestTimeout)

@Suite("Deadline Propagation Tests")
struct DeadlinePropagationTests {

    @Test("Server handler receives deadline from client timeout")
    func deadlineInContext() async throws {
        let socketPath = "/tmp/ttrpc-deadline-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [DeadlineReportService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        // Call with timeout -- server should see the deadline
        let resp: EchoResponse = try await client.call(
            service: "test.DeadlineReport", method: "Check",
            request: EchoRequest(message: "test"),
            responseType: EchoResponse.self,
            timeout: .seconds(5)
        )
        #expect(resp.reply == "deadline=true")

        // Call without timeout -- server should not see a deadline
        let resp2: EchoResponse = try await client.call(
            service: "test.DeadlineReport", method: "Check",
            request: EchoRequest(message: "test"),
            responseType: EchoResponse.self
        )
        #expect(resp2.reply == "deadline=false")

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}

// MARK: - Oversize Message End-to-End Tests (mirrors Go: TestOversizeCall)

@Suite("Oversize Message Tests")
struct OversizeMessageTests {

    @Test("Oversized request payload rejected end-to-end")
    func oversizedPayload() async throws {
        let socketPath = "/tmp/ttrpc-oversize-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        // Create a message that will produce a payload > 4MB when serialized
        let largeMessage = String(repeating: "x", count: 5 * 1024 * 1024) // 5MB
        await #expect(throws: Error.self) {
            let _: EchoResponse = try await client.call(
                service: "test.Echo", method: "Echo",
                request: EchoRequest(message: largeMessage),
                responseType: EchoResponse.self
            )
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}

// MARK: - Unimplemented Status Code Tests (mirrors Go: TestServerUnimplemented)

@Suite("Status Code Tests")
struct StatusCodeTests {

    @Test("Unimplemented service returns correct gRPC status code")
    func unimplementedStatus() async throws {
        let socketPath = "/tmp/ttrpc-status-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        do {
            let _: EchoResponse = try await client.call(
                service: "nonexistent.Service", method: "Method",
                request: EchoRequest(message: "test"),
                responseType: EchoResponse.self
            )
            Issue.record("Expected error")
        } catch let error as TTRPCError {
            switch error {
            case .remoteError(let code, _):
                // Should be Unimplemented (12)
                #expect(code == StatusCode.unimplemented.rawValue)
            default:
                Issue.record("Expected remoteError, got \(error)")
            }
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }

    @Test("Unimplemented method on existing service returns correct status")
    func unimplementedMethod() async throws {
        let socketPath = "/tmp/ttrpc-status-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        do {
            let _: EchoResponse = try await client.call(
                service: "test.Echo", method: "NonExistentMethod",
                request: EchoRequest(message: "test"),
                responseType: EchoResponse.self
            )
            Issue.record("Expected error")
        } catch let error as TTRPCError {
            switch error {
            case .remoteError(let code, _):
                #expect(code == StatusCode.unimplemented.rawValue)
            default:
                Issue.record("Expected remoteError, got \(error)")
            }
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}
