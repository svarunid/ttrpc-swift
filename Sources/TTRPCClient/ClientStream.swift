import Foundation
import NIOCore
import SwiftProtobuf
import TTRPCCore
import TTRPCNIOTransport
import TTRPCProtobuf

/// A client-side stream for streaming RPC patterns.
///
/// Supports all streaming patterns:
/// - **Client-streaming**: send multiple messages, receive one response via `closeAndReceive()`
/// - **Server-streaming**: send one request (done by `makeStream`), iterate `responses`
/// - **Bidirectional**: send and receive concurrently
///
/// Usage (server-streaming):
/// ```swift
/// let stream = try await client.makeStream(
///     service: "test.Events", method: "Subscribe",
///     requestType: SubscribeRequest.self, responseType: Event.self
/// )
/// try await stream.send(subscribeRequest)
/// try await stream.closeSend()
/// for try await event in stream.responses {
///     print(event)
/// }
/// ```
public struct TTRPCClientStream<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>: Sendable {
    private let connection: ClientConnection
    private let streamID: UInt32
    private let codec: TTRPCProtobufCodec
    private let inboundFrames: AsyncThrowingStream<TTRPCFrame, Error>

    init(
        connection: ClientConnection,
        streamID: UInt32,
        codec: TTRPCProtobufCodec,
        inboundFrames: AsyncThrowingStream<TTRPCFrame, Error>
    ) {
        self.connection = connection
        self.streamID = streamID
        self.codec = codec
        self.inboundFrames = inboundFrames
    }

    /// Send a message on the stream.
    ///
    /// For client-streaming and bidi patterns. The message is sent as a `Data` frame.
    public func send(_ message: Req, closeSend: Bool = false) async throws {
        let data = try codec.marshal(message)
        var buffer = ByteBuffer()
        buffer.writeBytes(data)

        let flags: MessageFlags = closeSend ? .remoteClosed : []
        let frame = TTRPCFrame(
            streamID: streamID,
            messageType: .data,
            flags: flags,
            payload: buffer
        )
        try await connection.send(frame)
    }

    /// Close the send side of the stream (signal `remoteClosed` to server).
    ///
    /// After calling this, no more messages can be sent. The server may still
    /// send responses.
    public func closeSend() async throws {
        let frame = TTRPCFrame(
            streamID: streamID,
            messageType: .data,
            flags: [.remoteClosed, .noData],
            payload: ByteBuffer()
        )
        try await connection.send(frame)
    }

    /// An `AsyncSequence` of response messages from the server.
    ///
    /// For server-streaming and bidi patterns. Yields decoded messages until
    /// the server closes its send side or sends a terminal Response frame.
    public var responses: AsyncThrowingStream<Resp, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await frame in inboundFrames {
                        switch frame.header.messageType {
                        case .response:
                            // Terminal response -- decode and finish
                            let responseData = Data(frame.payload.readableBytesView)
                            let ttrpcResponse: TTRPC_Response = try codec.unmarshal(responseData)
                            if ttrpcResponse.hasStatus && ttrpcResponse.status.code != 0 {
                                continuation.finish(throwing: TTRPCError.remoteError(
                                    code: ttrpcResponse.status.code,
                                    message: ttrpcResponse.status.message
                                ))
                            } else if !ttrpcResponse.payload.isEmpty {
                                let msg: Resp = try codec.unmarshal(ttrpcResponse.payload)
                                continuation.yield(msg)
                                continuation.finish()
                            } else {
                                continuation.finish()
                            }
                            return

                        case .data:
                            if !frame.header.flags.contains(.noData) && frame.payload.readableBytes > 0 {
                                let data = Data(frame.payload.readableBytesView)
                                let msg: Resp = try codec.unmarshal(data)
                                continuation.yield(msg)
                            }
                            if frame.header.flags.contains(.remoteClosed) {
                                continuation.finish()
                                return
                            }

                        case .request:
                            // Client shouldn't receive request frames
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Convenience for client-streaming: close send and receive the single response.
    public func closeAndReceive() async throws -> Resp {
        try await closeSend()
        for try await response in responses {
            return response
        }
        throw TTRPCError.streamClosed
    }
}
