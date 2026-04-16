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

// MARK: - Streaming Stress Services

/// Server-streaming service that sends exactly N messages with sequence numbers.
struct SequenceService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.Sequence",
            streams: [
                "Generate": TTRPCStreamDescriptor(
                    name: "Generate",
                    clientStreaming: false,
                    serverStreaming: true,
                    handler: { context, stream in
                        let codec = TTRPCProtobufCodec()
                        let data = try await stream.receiveData()
                        let request: EchoRequest = try codec.unmarshal(data)
                        let count = Int(request.message) ?? 10

                        for i in 0..<count {
                            let response = EchoResponse(reply: "seq:\(i)")
                            let respData = try codec.marshal(response)
                            try await stream.sendData(respData)
                        }
                        try await stream.closeSend()
                    }
                ),
            ]
        )
    }
}

/// Bidi service that echoes with sequence tracking.
struct BidiSequenceService: TTRPCServiceRegistration {
    var serviceDescriptor: TTRPCServiceDescriptor {
        TTRPCServiceDescriptor(
            name: "test.BidiSequence",
            streams: [
                "Echo": TTRPCStreamDescriptor(
                    name: "Echo",
                    clientStreaming: true,
                    serverStreaming: true,
                    handler: { context, stream in
                        let codec = TTRPCProtobufCodec()
                        var seq = 0
                        while true {
                            do {
                                let data = try await stream.receiveData()
                                let msg: EchoRequest = try codec.unmarshal(data)
                                let response = EchoResponse(reply: "echo[\(seq)]:\(msg.message)")
                                let respData = try codec.marshal(response)
                                try await stream.sendData(respData)
                                seq += 1
                            } catch {
                                break
                            }
                        }
                        try await stream.closeSend()
                    }
                ),
            ]
        )
    }
}

// MARK: - Streaming Stress Tests (mirrors Go: TestStreamClient with 100 messages)

@Suite("Streaming Stress Tests")
struct StreamingStressTests {

    @Test("Server-streaming with 100 messages preserves order and content")
    func serverStreaming100Messages() async throws {
        let socketPath = "/tmp/ttrpc-stress-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [SequenceService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        let count = 100
        let stream: TTRPCClientStream<EchoRequest, EchoResponse> = try await client.makeStream(
            service: "test.Sequence",
            method: "Generate",
            request: EchoRequest(message: "\(count)"),
            responseType: EchoResponse.self,
            clientStreaming: false,
            serverStreaming: true
        )

        var received: [String] = []
        for try await response in stream.responses {
            received.append(response.reply)
        }

        // Verify count
        #expect(received.count == count)

        // Verify sequence ordering
        for i in 0..<count {
            #expect(received[i] == "seq:\(i)")
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }

    @Test("Bidi streaming with 100 send/receive pairs")
    func bidiStreaming100Messages() async throws {
        let socketPath = "/tmp/ttrpc-stress-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [BidiSequenceService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        let count = 100
        let stream: TTRPCClientStream<EchoRequest, EchoResponse> = try await client.makeStream(
            service: "test.BidiSequence",
            method: "Echo",
            request: EchoRequest(message: ""),
            responseType: EchoResponse.self,
            clientStreaming: true,
            serverStreaming: true
        )

        // Send all messages
        for i in 0..<count {
            try await stream.send(EchoRequest(message: "msg-\(i)"))
        }
        try await stream.closeSend()

        // Receive all responses
        var received: [String] = []
        for try await response in stream.responses {
            received.append(response.reply)
        }

        // Verify count and sequence
        #expect(received.count == count)
        for i in 0..<count {
            #expect(received[i] == "echo[\(i)]:msg-\(i)")
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}

// MARK: - Varying Message Sizes (mirrors Go: TestReadWriteMessage)

@Suite("Varying Message Size Tests")
struct VaryingMessageSizeTests {

    @Test("Messages of varying sizes round-trip correctly")
    func varyingMessageSizes() async throws {
        let socketPath = "/tmp/ttrpc-sizes-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TTRPCServer(services: [EchoService()])
        let serverTask = Task { try await server.serve(unixDomainSocketPath: socketPath) }
        try await waitForSocket(socketPath)

        let client = try await TTRPCClient.connect(socketPath: socketPath)

        let testMessages = [
            "",                                    // empty
            "a",                                   // 1 byte
            "hello",                               // 5 bytes
            "this is a test",                      // 14 bytes
            String(repeating: "x", count: 100),    // 100 bytes
            String(repeating: "y", count: 1000),   // 1 KB
            String(repeating: "z", count: 10000),  // 10 KB
            String(repeating: "w", count: 100000), // 100 KB
            String(repeating: "v", count: 1000000),// 1 MB
        ]

        for msg in testMessages {
            let resp: EchoResponse = try await client.call(
                service: "test.Echo", method: "Echo",
                request: EchoRequest(message: msg),
                responseType: EchoResponse.self
            )
            #expect(resp.reply == "echo: \(msg)")
        }

        await client.close()
        server.shutdown()
        serverTask.cancel()
    }
}
