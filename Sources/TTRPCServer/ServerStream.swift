import Foundation
import NIOCore
import SwiftProtobuf
import TTRPCCore
import TTRPCNIOTransport
import TTRPCProtobuf

/// Server-side stream implementation that handles bidirectional message exchange.
///
/// Provides `sendMessage`/`receiveMessage` for streaming handlers. The stream
/// tracks local/remote closure state per the ttrpc protocol specification.
public final class ServerStreamImpl: TTRPCServerStreamInterface, @unchecked Sendable {
    private let streamID: UInt32
    private let outbound: NIOAsyncChannelOutboundWriter<TTRPCFrame>
    private let codec: TTRPCProtobufCodec
    private let inbound: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var state: StreamState

    init(
        streamID: UInt32,
        outbound: NIOAsyncChannelOutboundWriter<TTRPCFrame>,
        codec: TTRPCProtobufCodec
    ) {
        self.streamID = streamID
        self.outbound = outbound
        self.codec = codec
        self.state = StreamState()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    /// Feed incoming data from the connection handler into this stream.
    func feedData(_ data: Data, remoteClosed: Bool) {
        if !data.isEmpty {
            inboundContinuation.yield(data)
        }
        if remoteClosed {
            state.closeRemote()
            inboundContinuation.finish()
        }
    }

    /// Signal that the remote side has closed without additional data.
    func feedRemoteClosed() {
        state.closeRemote()
        inboundContinuation.finish()
    }

    /// Send serialized data to the client.
    public func sendData(_ data: Data) async throws {
        guard !state.localClosed else {
            throw TTRPCError.streamClosed
        }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        let frame = TTRPCFrame(
            streamID: streamID,
            messageType: .data,
            flags: [],
            payload: buffer
        )
        try await outbound.write(frame)
    }

    /// Receive serialized data from the client.
    public func receiveData() async throws -> Data {
        for try await data in inbound {
            return data
        }
        throw TTRPCError.streamClosed
    }

    /// Close the send side of this stream.
    public func closeSend() async throws {
        guard !state.localClosed else { return }
        state.closeLocal()
        let frame = TTRPCFrame(
            streamID: streamID,
            messageType: .data,
            flags: [.remoteClosed, .noData],
            payload: ByteBuffer()
        )
        try await outbound.write(frame)
    }

    /// Send a terminal Response frame (used after streaming is done).
    func sendResponse(_ data: Data, status: Google_Rpc_Status) async throws {
        var ttrpcResponse = TTRPC_Response()
        ttrpcResponse.status = status
        ttrpcResponse.payload = data

        let responseData = try codec.marshal(ttrpcResponse)
        var buffer = ByteBuffer()
        buffer.writeBytes(responseData)

        let frame = TTRPCFrame(
            streamID: streamID,
            messageType: .response,
            flags: [],
            payload: buffer
        )
        try await outbound.write(frame)
    }

    /// Send an error Response frame.
    func sendErrorResponse(_ error: Error) async {
        do {
            let code = statusCode(for: error)
            let status = Google_Rpc_Status.with {
                $0.code = Int32(code.rawValue)
                $0.message = "\(error)"
            }
            try await sendResponse(Data(), status: status)
        } catch {
            // Connection broken
        }
    }
}
