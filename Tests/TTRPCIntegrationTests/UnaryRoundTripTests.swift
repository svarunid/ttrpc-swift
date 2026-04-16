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

// MARK: - Test Protobuf Messages

// Simple echo messages for testing.
// In production these would be generated from .proto files.
struct EchoRequest: SwiftProtobuf.Message, Sendable {
    static let protoMessageName = "test.EchoRequest"

    var message: String = ""

    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}
    init(message: String) { self.message = message }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &message)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !message.isEmpty {
            try visitor.visitSingularStringField(value: message, fieldNumber: 1)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message other: any SwiftProtobuf.Message) -> Bool {
        guard let other = other as? EchoRequest else { return false }
        return message == other.message
    }
}

struct EchoResponse: SwiftProtobuf.Message, Sendable {
    static let protoMessageName = "test.EchoResponse"

    var reply: String = ""

    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}
    init(reply: String) { self.reply = reply }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &reply)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !reply.isEmpty {
            try visitor.visitSingularStringField(value: reply, fieldNumber: 1)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message other: any SwiftProtobuf.Message) -> Bool {
        guard let other = other as? EchoResponse else { return false }
        return reply == other.reply
    }
}

// MARK: - Test Service

struct EchoService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.Echo",
            methods: [
                "Echo": TTRPCMethodDescriptor(
                    name: "Echo",
                    handler: { context, requestData in
                        let codec = TTRPCProtobufCodec()
                        let request: EchoRequest = try codec.unmarshal(requestData)
                        let response = EchoResponse(reply: "echo: \(request.message)")
                        return try codec.marshal(response)
                    }
                ),
            ]
        )
    }
}

// MARK: - Integration Tests

@Suite("Unary Round-Trip Integration Tests")
struct UnaryRoundTripTests {

    @Test("Client-server echo round-trip")
    func echoRoundTrip() async throws {
        let socketPath = "/tmp/ttrpc-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])

        // Start server in background
        let serverTask = Task {
            try await server.serve(unixDomainSocketPath: socketPath)
        }

        // Wait for socket to appear
        try await waitForSocket(socketPath)

        // Connect client
        let client = try await TTRPCClient.connect(socketPath: socketPath)

        // Make the call
        let request = EchoRequest(message: "hello ttrpc")
        let response: EchoResponse = try await client.call(
            service: "test.Echo",
            method: "Echo",
            request: request,
            responseType: EchoResponse.self
        )

        #expect(response.reply == "echo: hello ttrpc")

        // Clean up
        await client.close()
        server.shutdown()
        serverTask.cancel()
    }

    @Test("Multiple sequential calls on one connection")
    func multipleCalls() async throws {
        let socketPath = "/tmp/ttrpc-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])

        let serverTask = Task {
            try await server.serve(unixDomainSocketPath: socketPath)
        }

        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        for i in 0..<5 {
            let request = EchoRequest(message: "message \(i)")
            let response: EchoResponse = try await client.call(
                service: "test.Echo",
                method: "Echo",
                request: request,
                responseType: EchoResponse.self
            )
            #expect(response.reply == "echo: message \(i)")
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }

    @Test("Service not found returns error")
    func serviceNotFound() async throws {
        let socketPath = "/tmp/ttrpc-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])

        let serverTask = Task {
            try await server.serve(unixDomainSocketPath: socketPath)
        }

        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        await #expect(throws: TTRPCError.self) {
            let _: EchoResponse = try await client.call(
                service: "nonexistent.Service",
                method: "Method",
                request: EchoRequest(message: "test"),
                responseType: EchoResponse.self
            )
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}
