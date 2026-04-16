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

// Reuse EchoRequest/EchoResponse from UnaryRoundTripTests.

// MARK: - Streaming Test Services

/// Server-streaming service: client sends one request, server sends N responses.
struct CountService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.Count",
            streams: [
                "CountUp": TTRPCStreamDescriptor(
                    name: "CountUp",
                    clientStreaming: false,
                    serverStreaming: true,
                    handler: { context, stream in
                        // Receive the single request (how many to count)
                        let requestData = try await stream.receiveData()
                        let codec = TTRPCProtobufCodec()
                        let request: EchoRequest = try codec.unmarshal(requestData)
                        let count = Int(request.message) ?? 3

                        // Send N responses
                        for i in 1...count {
                            let response = EchoResponse(reply: "count: \(i)")
                            let data = try codec.marshal(response)
                            try await stream.sendData(data)
                        }
                        try await stream.closeSend()
                    }
                ),
            ]
        )
    }
}

/// Client-streaming service: client sends N messages, server sends one response.
struct CollectService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.Collect",
            streams: [
                "Collect": TTRPCStreamDescriptor(
                    name: "Collect",
                    clientStreaming: true,
                    serverStreaming: false,
                    handler: { context, stream in
                        let codec = TTRPCProtobufCodec()
                        var collected: [String] = []

                        // Receive all messages from client
                        while true {
                            do {
                                let data = try await stream.receiveData()
                                let msg: EchoRequest = try codec.unmarshal(data)
                                collected.append(msg.message)
                            } catch {
                                break // Stream closed
                            }
                        }

                        // Send aggregated response via the terminal Response frame
                        // (The ServerConnection sends the terminal response after handler returns)
                        // We store the result in stream data for the terminal response
                        let response = EchoResponse(reply: "collected: \(collected.joined(separator: ", "))")
                        let data = try codec.marshal(response)
                        try await stream.sendData(data)
                        try await stream.closeSend()
                    }
                ),
            ]
        )
    }
}

/// Bidi streaming service: echo each message back with a prefix.
struct BidiEchoService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.BidiEcho",
            streams: [
                "Echo": TTRPCStreamDescriptor(
                    name: "Echo",
                    clientStreaming: true,
                    serverStreaming: true,
                    handler: { context, stream in
                        let codec = TTRPCProtobufCodec()

                        // Echo each message back
                        while true {
                            do {
                                let data = try await stream.receiveData()
                                let msg: EchoRequest = try codec.unmarshal(data)
                                let response = EchoResponse(reply: "bidi: \(msg.message)")
                                let respData = try codec.marshal(response)
                                try await stream.sendData(respData)
                            } catch {
                                break // Stream closed
                            }
                        }
                        try await stream.closeSend()
                    }
                ),
            ]
        )
    }
}

// MARK: - Streaming Tests

@Suite("Server-Streaming Integration Tests")
struct ServerStreamingTests {

    @Test("Server sends multiple responses")
    func serverStreaming() async throws {
        let socketPath = "/tmp/ttrpc-stream-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [CountService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        let request = EchoRequest(message: "5")
        let stream: TTRPCClientStream<EchoRequest, EchoResponse> = try await client.makeStream(
            service: "test.Count",
            method: "CountUp",
            request: request,
            responseType: EchoResponse.self,
            clientStreaming: false,
            serverStreaming: true
        )

        var received: [String] = []
        for try await response in stream.responses {
            received.append(response.reply)
        }

        #expect(received.count == 5)
        #expect(received[0] == "count: 1")
        #expect(received[4] == "count: 5")

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}

@Suite("Client-Streaming Integration Tests")
struct ClientStreamingTests {

    @Test("Client sends multiple messages, server responds once")
    func clientStreaming() async throws {
        let socketPath = "/tmp/ttrpc-stream-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [CollectService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        // Use an empty initial request
        let stream: TTRPCClientStream<EchoRequest, EchoResponse> = try await client.makeStream(
            service: "test.Collect",
            method: "Collect",
            request: EchoRequest(message: ""),
            responseType: EchoResponse.self,
            clientStreaming: true,
            serverStreaming: false
        )

        // Send several messages
        try await stream.send(EchoRequest(message: "alpha"))
        try await stream.send(EchoRequest(message: "beta"))
        try await stream.send(EchoRequest(message: "gamma"), closeSend: true)

        // Receive the aggregated response
        var received: [String] = []
        for try await response in stream.responses {
            received.append(response.reply)
        }

        #expect(received.count >= 1)
        // The collect service sends back the collected messages
        #expect(received.last?.contains("alpha") == true)
        #expect(received.last?.contains("beta") == true)
        #expect(received.last?.contains("gamma") == true)

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}

@Suite("Bidirectional Streaming Integration Tests")
struct BidiStreamingTests {

    @Test("Client and server exchange messages bidirectionally")
    func bidiStreaming() async throws {
        let socketPath = "/tmp/ttrpc-stream-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [BidiEchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        let stream: TTRPCClientStream<EchoRequest, EchoResponse> = try await client.makeStream(
            service: "test.BidiEcho",
            method: "Echo",
            request: EchoRequest(message: ""),
            responseType: EchoResponse.self,
            clientStreaming: true,
            serverStreaming: true
        )

        // Send messages and collect responses concurrently
        let messages = ["hello", "world", "ttrpc"]

        // Send all messages then close
        for msg in messages {
            try await stream.send(EchoRequest(message: msg))
        }
        try await stream.closeSend()

        // Collect responses
        var received: [String] = []
        for try await response in stream.responses {
            received.append(response.reply)
        }

        #expect(received.count == 3)
        #expect(received[0] == "bidi: hello")
        #expect(received[1] == "bidi: world")
        #expect(received[2] == "bidi: ttrpc")

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}
