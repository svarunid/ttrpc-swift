import Foundation
import NIOCore
import NIOPosix
import SwiftProtobuf
import TTRPCCore
import TTRPCNIOTransport
import TTRPCProtobuf

/// A ttrpc client that communicates with a ttrpc server over a Unix domain socket.
///
/// Supports unary RPC calls (and streaming in a future phase). The client manages
/// a single connection with multiplexed streams, each identified by an odd stream ID.
///
/// Usage:
/// ```swift
/// let client = try await TTRPCClient.connect(socketPath: "/run/containerd/containerd-shim.sock")
/// let response = try await client.call(
///     service: "containerd.task.v2.Task",
///     method: "State",
///     request: stateRequest,
///     responseType: StateResponse.self
/// )
/// try await client.close()
/// ```
public final class TTRPCClient: Sendable {
    private let connection: ClientConnection
    private let codec: TTRPCProtobufCodec
    private let runTask: Task<Void, Never>
    private let interceptors: [any TTRPCClientInterceptor]

    private init(
        connection: ClientConnection,
        runTask: Task<Void, Never>,
        interceptors: [any TTRPCClientInterceptor] = []
    ) {
        self.connection = connection
        self.codec = TTRPCProtobufCodec()
        self.runTask = runTask
        self.interceptors = interceptors
    }

    /// Connect to a ttrpc server at the given Unix domain socket path.
    ///
    /// - Parameters:
    ///   - socketPath: The filesystem path of the Unix domain socket.
    ///   - eventLoopGroup: The NIO event loop group to use. Defaults to the singleton.
    /// - Returns: A connected `TTRPCClient`.
    public static func connect(
        socketPath: String,
        eventLoopGroup: EventLoopGroup? = nil,
        interceptors: [any TTRPCClientInterceptor] = []
    ) async throws -> TTRPCClient {
        let group = eventLoopGroup ?? MultiThreadedEventLoopGroup.singleton
        let asyncChannel = try await TTRPCUnixTransport.connect(path: socketPath, eventLoopGroup: group)

        // We need to get access to the outbound writer and inbound stream
        // via executeThenClose, but keep the client alive beyond that scope.
        // Use a continuation to bridge the scoped API.
        let connection: ClientConnection = await withCheckedContinuation { continuation in
            Task {
                try await asyncChannel.executeThenClose { inbound, outbound in
                    let conn = ClientConnection(outboundWriter: outbound)
                    continuation.resume(returning: conn)

                    // Run the receive loop within the executeThenClose scope
                    do {
                        for try await frame in inbound {
                            conn.dispatch(frame)
                        }
                    } catch {
                        // Connection error
                    }

                    conn.markClosed()
                }
            }
        }

        let runTask = Task<Void, Never> {} // The actual work happens in the executeThenClose task above
        return TTRPCClient(connection: connection, runTask: runTask, interceptors: interceptors)
    }

    /// Perform a unary RPC call.
    ///
    /// Serializes the request, sends it as a single ttrpc request frame (unary: no streaming flags),
    /// waits for the response frame, and deserializes the result.
    ///
    /// - Parameters:
    ///   - service: The fully-qualified service name.
    ///   - method: The method name.
    ///   - request: The protobuf request message.
    ///   - responseType: The expected protobuf response message type.
    ///   - timeout: Optional deadline duration for the call.
    ///   - metadata: Optional metadata to send with the request.
    /// - Returns: The deserialized response message.
    public func call<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(
        service: String,
        method: String,
        request: Req,
        responseType: Resp.Type,
        timeout: Duration? = nil,
        metadata: TTRPCMetadata? = nil
    ) async throws -> Resp {
        // Apply timeout if specified
        if let timeout {
            return try await withThrowingTaskGroup(of: Resp.self) { group in
                group.addTask {
                    try await self.executeCall(
                        service: service, method: method, request: request,
                        responseType: responseType, timeout: timeout, metadata: metadata
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw TTRPCError.deadlineExceeded
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }
        return try await executeCall(
            service: service, method: method, request: request,
            responseType: responseType, timeout: timeout, metadata: metadata
        )
    }

    private func executeCall<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(
        service: String,
        method: String,
        request: Req,
        responseType: Resp.Type,
        timeout: Duration? = nil,
        metadata: TTRPCMetadata? = nil
    ) async throws -> Resp {
        // Serialize the inner request payload
        let payloadData = try codec.marshal(request)

        // Build the ttrpc Request envelope
        var ttrpcRequest = TTRPC_Request()
        ttrpcRequest.service = service
        ttrpcRequest.method = method
        ttrpcRequest.payload = payloadData

        if let timeout {
            let nanos = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
            ttrpcRequest.timeoutNano = nanos
        }

        if let metadata, !metadata.isEmpty {
            ttrpcRequest.metadata = metadata.pairs.map { pair in
                var kv = TTRPC_KeyValue()
                kv.key = pair.key
                kv.value = pair.value
                return kv
            }
        }

        // Run through client interceptors if any
        var finalPayload = payloadData
        if !interceptors.isEmpty {
            let ctx = ClientInterceptorContext(
                method: "/\(service)/\(method)",
                metadata: metadata ?? TTRPCMetadata()
            )
            let chain = chainClientInterceptors(interceptors) { data, context in
                return data // pass through
            }
            finalPayload = try await chain(payloadData, ctx)
            // Update request with potentially modified payload
            ttrpcRequest.payload = finalPayload
        }

        // Serialize the envelope
        let envelopeData = try codec.marshal(ttrpcRequest)

        // Allocate stream + send atomically to preserve stream-ID ordering
        let (_, frames) = try await connection.allocateAndSend { streamID in
            var payloadBuffer = ByteBuffer()
            payloadBuffer.writeBytes(envelopeData)
            return TTRPCFrame(
                streamID: streamID,
                messageType: .request,
                flags: [],
                payload: payloadBuffer
            )
        }

        // Wait for the response frame
        var responseFrame: TTRPCFrame?
        for try await f in frames {
            responseFrame = f
            break // Unary: exactly one response
        }

        guard let responseFrame else {
            throw TTRPCError.closed
        }

        // Deserialize the ttrpc Response envelope
        let responseData = Data(responseFrame.payload.readableBytesView)
        let ttrpcResponse: TTRPC_Response = try codec.unmarshal(responseData)

        // Check for error status
        if ttrpcResponse.hasStatus && ttrpcResponse.status.code != 0 {
            throw TTRPCError.remoteError(
                code: ttrpcResponse.status.code,
                message: ttrpcResponse.status.message
            )
        }

        // Deserialize the inner response payload
        let response: Resp = try codec.unmarshal(ttrpcResponse.payload)
        return response
    }

    /// Create a new stream for streaming RPC patterns.
    ///
    /// The initial Request frame is sent with appropriate flags based on the streaming
    /// direction. For server-streaming, the request payload is included and the client
    /// side is marked closed. For client-streaming and bidi, the request is sent with
    /// `remoteOpen` to indicate more data will follow.
    ///
    /// - Parameters:
    ///   - service: The fully-qualified service name.
    ///   - method: The method name.
    ///   - request: The initial request message (carries routing info + optional first payload).
    ///   - requestType: The type of messages the client will send.
    ///   - responseType: The type of messages the server will send.
    ///   - clientStreaming: Whether the client will send multiple messages.
    ///   - serverStreaming: Whether the server will send multiple messages.
    ///   - timeout: Optional deadline duration.
    ///   - metadata: Optional metadata.
    /// - Returns: A `TTRPCClientStream` for sending/receiving messages.
    public func makeStream<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(
        service: String,
        method: String,
        request: Req,
        requestType: Req.Type = Req.self,
        responseType: Resp.Type,
        clientStreaming: Bool,
        serverStreaming: Bool,
        timeout: Duration? = nil,
        metadata: TTRPCMetadata? = nil
    ) async throws -> TTRPCClientStream<Req, Resp> {
        let payloadData = try codec.marshal(request)

        // Build the ttrpc Request envelope
        var ttrpcRequest = TTRPC_Request()
        ttrpcRequest.service = service
        ttrpcRequest.method = method
        ttrpcRequest.payload = payloadData

        if let timeout {
            let nanos = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
            ttrpcRequest.timeoutNano = nanos
        }

        if let metadata, !metadata.isEmpty {
            ttrpcRequest.metadata = metadata.pairs.map { pair in
                var kv = TTRPC_KeyValue()
                kv.key = pair.key
                kv.value = pair.value
                return kv
            }
        }

        let envelopeData = try codec.marshal(ttrpcRequest)

        // Determine flags
        let flags: MessageFlags = clientStreaming ? .remoteOpen : .remoteClosed

        // Allocate stream + send atomically to preserve stream-ID ordering
        let (streamID, frames) = try await connection.allocateAndSend { streamID in
            var payloadBuffer = ByteBuffer()
            payloadBuffer.writeBytes(envelopeData)
            return TTRPCFrame(
                streamID: streamID,
                messageType: .request,
                flags: flags,
                payload: payloadBuffer
            )
        }

        return TTRPCClientStream(
            connection: connection,
            streamID: streamID,
            codec: codec,
            inboundFrames: frames
        )
    }

    /// Close the client connection.
    public func close() async {
        connection.close()
        runTask.cancel()
    }
}
