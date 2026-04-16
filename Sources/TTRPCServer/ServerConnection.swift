import Foundation
import NIOCore
import SwiftProtobuf
import TTRPCCore
import TTRPCNIOTransport
import TTRPCProtobuf

/// Handles a single client connection on the server side.
///
/// Validates incoming stream IDs (must be odd, must increase monotonically),
/// dispatches requests to the service router, and sends responses back.
/// Supports both unary and streaming RPC patterns.
actor ServerConnection {
    private let router: ServiceRouter
    private let codec: TTRPCProtobufCodec
    private let interceptors: [any TTRPCServerInterceptor]
    private let peerCredentials: TTRPCPeerCredentials?

    private var lastStreamID: UInt32 = 0
    /// Active streaming handlers, keyed by stream ID
    private var activeStreams: [UInt32: ServerStreamImpl] = [:]

    init(
        router: ServiceRouter,
        interceptors: [any TTRPCServerInterceptor] = [],
        peerCredentials: TTRPCPeerCredentials?
    ) {
        self.router = router
        self.codec = TTRPCProtobufCodec()
        self.interceptors = interceptors
        self.peerCredentials = peerCredentials
    }

    /// Run the connection handler using the given async channel.
    func run(channel: NIOAsyncChannel<TTRPCFrame, TTRPCFrame>) async {
        do {
            try await channel.executeThenClose { inbound, outbound in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for try await frame in inbound {
                        switch frame.header.messageType {
                        case .request:
                            try validateRequestStreamID(frame.header.streamID)

                            let streamID = frame.header.streamID
                            let requestData = Data(frame.payload.readableBytesView)
                            let flags = frame.header.flags

                            // Determine if this is a unary or streaming request
                            let isUnary = flags.rawValue == 0 // No flags = legacy unary
                            let isRemoteClosed = flags.contains(.remoteClosed)
                            let isRemoteOpen = flags.contains(.remoteOpen)

                            if isUnary || (isRemoteClosed && !isRemoteOpen) {
                                // Unary or server-streaming: client sends one message
                                // Check if it's a streaming method
                                let ttrpcRequest: TTRPC_Request = try codec.unmarshal(requestData)
                                let isStreamMethod = router.hasStreamMethod(
                                    service: ttrpcRequest.service,
                                    method: ttrpcRequest.method
                                )

                                if isStreamMethod && !isUnary {
                                    // Server-streaming: start stream handler
                                    let serverStream = ServerStreamImpl(
                                        streamID: streamID,
                                        outbound: outbound,
                                        codec: codec
                                    )
                                    // Feed the initial request payload and mark remote closed
                                    serverStream.feedData(ttrpcRequest.payload, remoteClosed: true)
                                    activeStreams[streamID] = serverStream

                                    group.addTask { [self] in
                                        await self.handleStreamingRequest(
                                            streamID: streamID,
                                            ttrpcRequest: ttrpcRequest,
                                            serverStream: serverStream,
                                            outbound: outbound
                                        )
                                    }
                                } else {
                                    // Unary request
                                    group.addTask { [self] in
                                        await self.handleUnaryRequest(
                                            streamID: streamID,
                                            requestData: requestData,
                                            outbound: outbound
                                        )
                                    }
                                }
                            } else if isRemoteOpen {
                                // Client-streaming or bidi: client will send more data
                                let ttrpcRequest: TTRPC_Request = try codec.unmarshal(requestData)
                                let serverStream = ServerStreamImpl(
                                    streamID: streamID,
                                    outbound: outbound,
                                    codec: codec
                                )
                                // Feed initial payload if non-empty
                                if !ttrpcRequest.payload.isEmpty {
                                    serverStream.feedData(ttrpcRequest.payload, remoteClosed: false)
                                }
                                activeStreams[streamID] = serverStream

                                group.addTask { [self] in
                                    await self.handleStreamingRequest(
                                        streamID: streamID,
                                        ttrpcRequest: ttrpcRequest,
                                        serverStream: serverStream,
                                        outbound: outbound
                                    )
                                }
                            }

                        case .data:
                            // Route data to the appropriate active stream
                            let streamID = frame.header.streamID
                            if let serverStream = activeStreams[streamID] {
                                let data = Data(frame.payload.readableBytesView)
                                let remoteClosed = frame.header.flags.contains(.remoteClosed)
                                let hasData = !frame.header.flags.contains(.noData) && !data.isEmpty

                                if hasData {
                                    serverStream.feedData(data, remoteClosed: remoteClosed)
                                } else if remoteClosed {
                                    serverStream.feedRemoteClosed()
                                }

                                if remoteClosed {
                                    activeStreams.removeValue(forKey: streamID)
                                }
                            }

                        case .response:
                            // Server should not receive response frames from client
                            break
                        }
                    }

                    // Wait for all in-flight handlers to complete
                    try await group.waitForAll()
                }
            }
        } catch {
            // Connection error or cancellation -- normal shutdown path
        }
    }

    /// Validate that a request stream ID is odd and strictly increasing.
    private func validateRequestStreamID(_ streamID: UInt32) throws {
        guard streamID & 1 == 1 else {
            throw TTRPCError.invalidStreamID(streamID)
        }
        guard streamID > lastStreamID else {
            throw TTRPCError.protocolError("stream ID \(streamID) must be greater than last ID \(lastStreamID)")
        }
        lastStreamID = streamID
    }

    // MARK: - Unary Handling

    /// Handle a unary (non-streaming) request with interceptor and timeout support.
    private func handleUnaryRequest(
        streamID: UInt32,
        requestData: Data,
        outbound: NIOAsyncChannelOutboundWriter<TTRPCFrame>
    ) async {
        do {
            let ttrpcRequest: TTRPC_Request = try codec.unmarshal(requestData)
            let context = buildHandlerContext(from: ttrpcRequest)

            let methodDesc = try router.lookupMethod(
                service: ttrpcRequest.service,
                method: ttrpcRequest.method
            )

            // Build the handler chain with interceptors
            let handler: @Sendable (Data, ServerInterceptorContext) async throws -> Data = { data, _ in
                try await methodDesc.handler(context, data)
            }
            let chain = chainServerInterceptors(interceptors, finally: handler)

            let interceptorCtx = ServerInterceptorContext(
                method: "/\(ttrpcRequest.service)/\(ttrpcRequest.method)",
                metadata: context.metadata,
                peerCredentials: peerCredentials
            )

            // Execute with optional timeout
            let responsePayload: Data
            if let deadline = context.deadline {
                let remaining = deadline - .now
                responsePayload = try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        try await chain(ttrpcRequest.payload, interceptorCtx)
                    }
                    group.addTask {
                        try await Task.sleep(for: remaining)
                        throw TTRPCError.deadlineExceeded
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
            } else {
                responsePayload = try await chain(ttrpcRequest.payload, interceptorCtx)
            }

            var ttrpcResponse = TTRPC_Response()
            ttrpcResponse.status = Google_Rpc_Status.with {
                $0.code = Int32(StatusCode.ok.rawValue)
            }
            ttrpcResponse.payload = responsePayload

            let responseData = try codec.marshal(ttrpcResponse)
            try await sendResponse(streamID: streamID, data: responseData, outbound: outbound)

        } catch {
            await sendErrorResponse(streamID: streamID, error: error, outbound: outbound)
        }
    }

    // MARK: - Streaming Handling

    /// Handle a streaming request.
    private func handleStreamingRequest(
        streamID: UInt32,
        ttrpcRequest: TTRPC_Request,
        serverStream: ServerStreamImpl,
        outbound: NIOAsyncChannelOutboundWriter<TTRPCFrame>
    ) async {
        do {
            let context = buildHandlerContext(from: ttrpcRequest)

            let streamDesc = try router.lookupStream(
                service: ttrpcRequest.service,
                method: ttrpcRequest.method
            )

            // Run the streaming handler
            try await streamDesc.handler(context, serverStream)

            // Send terminal response after handler completes
            let okStatus = Google_Rpc_Status.with {
                $0.code = Int32(StatusCode.ok.rawValue)
            }
            try await serverStream.sendResponse(Data(), status: okStatus)

        } catch {
            await serverStream.sendErrorResponse(error)
        }
    }

    // MARK: - Helpers

    private func buildHandlerContext(from ttrpcRequest: TTRPC_Request) -> TTRPCHandlerContext {
        var metadata = TTRPCMetadata()
        for kv in ttrpcRequest.metadata {
            metadata.append(kv.key, value: kv.value)
        }

        var deadline: ContinuousClock.Instant? = nil
        if ttrpcRequest.timeoutNano > 0 {
            let duration = Duration.nanoseconds(ttrpcRequest.timeoutNano)
            deadline = .now + duration
        }

        return TTRPCHandlerContext(
            metadata: metadata,
            peerCredentials: peerCredentials,
            deadline: deadline
        )
    }

    /// Send a response frame.
    private func sendResponse(
        streamID: UInt32,
        data: Data,
        outbound: NIOAsyncChannelOutboundWriter<TTRPCFrame>
    ) async throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)

        let frame = TTRPCFrame(
            streamID: streamID,
            messageType: .response,
            flags: [],
            payload: buffer
        )
        try await outbound.write(frame)
    }

    /// Send an error response frame.
    private func sendErrorResponse(
        streamID: UInt32,
        error: Error,
        outbound: NIOAsyncChannelOutboundWriter<TTRPCFrame>
    ) async {
        do {
            let code = statusCode(for: error)
            var ttrpcResponse = TTRPC_Response()
            ttrpcResponse.status = Google_Rpc_Status.with {
                $0.code = Int32(code.rawValue)
                $0.message = "\(error)"
            }

            let responseData = try codec.marshal(ttrpcResponse)
            try await sendResponse(streamID: streamID, data: responseData, outbound: outbound)
        } catch {
            // Connection broken
        }
    }
}
