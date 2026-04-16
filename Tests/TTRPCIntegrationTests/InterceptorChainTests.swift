import Testing
import Foundation
import SwiftProtobuf
@testable import TTRPCCore
@testable import TTRPCProtobuf
@testable import TTRPCClient
@testable import TTRPCServer

// MARK: - Shared log for tracking interceptor execution order (reuses ThreadSafeLog)

// MARK: - Order-tracking interceptors

final class OrderTrackingClientInterceptor: TTRPCClientInterceptor, @unchecked Sendable {
    let id: String
    let log: ThreadSafeLog

    init(id: String, log: ThreadSafeLog) {
        self.id = id
        self.log = log
    }

    func intercept(
        request: Data,
        context: ClientInterceptorContext,
        next: @Sendable (Data, ClientInterceptorContext) async throws -> Data
    ) async throws -> Data {
        log.append("client-\(id)-before")
        let result = try await next(request, context)
        log.append("client-\(id)-after")
        return result
    }
}

final class OrderTrackingServerInterceptor: TTRPCServerInterceptor, @unchecked Sendable {
    let id: String
    let log: ThreadSafeLog

    init(id: String, log: ThreadSafeLog) {
        self.id = id
        self.log = log
    }

    func intercept(
        request: Data,
        context: ServerInterceptorContext,
        next: @Sendable (Data, ServerInterceptorContext) async throws -> Data
    ) async throws -> Data {
        log.append("server-\(id)-before")
        let result = try await next(request, context)
        log.append("server-\(id)-after")
        return result
    }
}

// MARK: - Interceptor Chain Tests (mirrors Go: TestChainUnary*Interceptor)

@Suite("Interceptor Chain Tests")
struct InterceptorChainTests {

    @Test("Multiple client interceptors execute in order")
    func clientInterceptorChainOrder() async throws {
        let socketPath = "/tmp/ttrpc-chain-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let log = ThreadSafeLog()

        let interceptors: [any TTRPCClientInterceptor] = [
            OrderTrackingClientInterceptor(id: "1", log: log),
            OrderTrackingClientInterceptor(id: "2", log: log),
            OrderTrackingClientInterceptor(id: "3", log: log),
        ]

        let client = try await TTRPCClient.connect(
            socketPath: socketPath,
            interceptors: interceptors
        )

        let _: EchoResponse = try await client.call(
            service: "test.Echo", method: "Echo",
            request: EchoRequest(message: "chain-test"),
            responseType: EchoResponse.self
        )

        // Before hooks execute outer-to-inner (1,2,3), after hooks inner-to-outer (3,2,1)
        #expect(log.entries == [
            "client-1-before",
            "client-2-before",
            "client-3-before",
            "client-3-after",
            "client-2-after",
            "client-1-after",
        ])

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }

    @Test("Multiple server interceptors execute in order")
    func serverInterceptorChainOrder() async throws {
        let socketPath = "/tmp/ttrpc-chain-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let log = ThreadSafeLog()

        let interceptors: [any TTRPCServerInterceptor] = [
            OrderTrackingServerInterceptor(id: "A", log: log),
            OrderTrackingServerInterceptor(id: "B", log: log),
            OrderTrackingServerInterceptor(id: "C", log: log),
        ]

        let server = TTRPCServer(
            services: [EchoService()],
            interceptors: interceptors
        )
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        let _: EchoResponse = try await client.call(
            service: "test.Echo", method: "Echo",
            request: EchoRequest(message: "chain-test"),
            responseType: EchoResponse.self
        )

        // Give server interceptors time to complete
        try await Task.sleep(for: .milliseconds(10))

        #expect(log.entries == [
            "server-A-before",
            "server-B-before",
            "server-C-before",
            "server-C-after",
            "server-B-after",
            "server-A-after",
        ])

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }

    @Test("Combined client and server interceptor chains both execute")
    func combinedChains() async throws {
        let socketPath = "/tmp/ttrpc-chain-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let clientLog = ThreadSafeLog()
        let serverLog = ThreadSafeLog()

        let server = TTRPCServer(
            services: [EchoService()],
            interceptors: [
                OrderTrackingServerInterceptor(id: "S1", log: serverLog),
                OrderTrackingServerInterceptor(id: "S2", log: serverLog),
            ]
        )
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(
            socketPath: socketPath,
            interceptors: [
                OrderTrackingClientInterceptor(id: "C1", log: clientLog),
                OrderTrackingClientInterceptor(id: "C2", log: clientLog),
            ]
        )

        let resp: EchoResponse = try await client.call(
            service: "test.Echo", method: "Echo",
            request: EchoRequest(message: "combined"),
            responseType: EchoResponse.self
        )
        #expect(resp.reply == "echo: combined")

        try await Task.sleep(for: .milliseconds(10))

        #expect(clientLog.entries.count == 4)
        #expect(serverLog.entries.count == 4)

        #expect(clientLog.entries[0] == "client-C1-before")
        #expect(clientLog.entries[1] == "client-C2-before")

        #expect(serverLog.entries[0] == "server-S1-before")
        #expect(serverLog.entries[1] == "server-S2-before")

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}
