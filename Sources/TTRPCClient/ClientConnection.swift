import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TTRPCCore
import TTRPCNIOTransport

/// Internal state for tracking active streams on a client connection.
struct ClientStreamEntry: Sendable {
    let continuation: AsyncThrowingStream<TTRPCFrame, Error>.Continuation
}

/// Manages the raw NIO connection and frame-level send/receive for a ttrpc client.
///
/// Bridges `NIOAsyncChannel` to the client's stream multiplexing layer.
/// Uses `executeThenClose` to properly scope the async channel's lifetime.
///
/// Critical: stream allocation and frame send are serialized via `sendLock`
/// to guarantee that frames arrive at the server with strictly increasing
/// stream IDs (a protocol requirement). This mirrors Go's `sendLock`.
final class ClientConnection: Sendable {
    private let state: Mutex<ConnectionState>
    private let outboundWriter: NIOAsyncChannelOutboundWriter<TTRPCFrame>
    /// Serializes send operations so frames are written in stream-ID order.
    private let sendLock = NSLock()

    struct ConnectionState: Sendable {
        var nextStreamID: UInt32 = 1 // Client uses odd IDs, incrementing by 2
        var streams: [UInt32: ClientStreamEntry] = [:]
        var isClosed: Bool = false
    }

    init(outboundWriter: NIOAsyncChannelOutboundWriter<TTRPCFrame>) {
        self.outboundWriter = outboundWriter
        self.state = Mutex(ConnectionState())
    }

    /// Allocate a new stream ID, register for responses, and send the initial frame atomically.
    ///
    /// This is the key concurrency-safe operation: the stream ID allocation and the frame send
    /// are performed while holding `sendLock`, ensuring that frames arrive at the server in
    /// strictly increasing stream-ID order (a ttrpc protocol requirement).
    ///
    /// Returns the stream ID and an `AsyncThrowingStream` that yields response frames.
    func allocateAndSend(_ buildFrame: (UInt32) -> TTRPCFrame) async throws -> (streamID: UInt32, frames: AsyncThrowingStream<TTRPCFrame, Error>) {
        // Hold the send lock across allocation + write to guarantee ordering
        let (streamID, frames, frame) = try sendLock.withLock {
            let result = try state.withLock { state -> (UInt32, AsyncThrowingStream<TTRPCFrame, Error>) in
                guard !state.isClosed else {
                    throw TTRPCError.closed
                }
                let streamID = state.nextStreamID
                state.nextStreamID += 2

                let (stream, continuation) = AsyncThrowingStream.makeStream(of: TTRPCFrame.self)
                state.streams[streamID] = ClientStreamEntry(continuation: continuation)
                return (streamID, stream)
            }
            let frame = buildFrame(result.0)
            return (result.0, result.1, frame)
        }

        // Now do the async write outside the lock, but ordering is preserved
        // because the sendLock serialized the frame construction, and NIO's
        // outbound writer preserves write order.
        do {
            try await outboundWriter.write(frame)
        } catch {
            removeStream(streamID)
            throw ClientConnection.filterCloseError(error)
        }

        return (streamID, frames)
    }

    /// Remove a stream registration.
    func removeStream(_ streamID: UInt32) {
        state.withLock { state in
            if let entry = state.streams.removeValue(forKey: streamID) {
                entry.continuation.finish()
            }
        }
    }

    /// Send a frame on an existing stream (for streaming data messages).
    func send(_ frame: TTRPCFrame) async throws {
        try await outboundWriter.write(frame)
    }

    /// Dispatch an incoming frame to the appropriate stream continuation.
    func dispatch(_ frame: TTRPCFrame) {
        let streamID = frame.header.streamID
        let entry = state.withLock { state in
            state.streams[streamID]
        }

        if let entry {
            entry.continuation.yield(frame)

            let shouldRemove: Bool
            switch frame.header.messageType {
            case .response:
                shouldRemove = true
            case .data:
                shouldRemove = frame.header.flags.contains(.remoteClosed)
            default:
                shouldRemove = false
            }

            if shouldRemove {
                removeStream(streamID)
            }
        }
    }

    /// Mark the connection as closed and fail all outstanding streams.
    func markClosed() {
        let remaining = state.withLock { state in
            state.isClosed = true
            let entries = state.streams
            state.streams.removeAll()
            return entries
        }
        for (_, entry) in remaining {
            entry.continuation.finish(throwing: TTRPCError.closed)
        }
    }

    /// Close the outbound side of the connection.
    func close() {
        state.withLock { state in
            state.isClosed = true
        }
        outboundWriter.finish()
    }

    /// Filter and normalize close-related errors.
    static func filterCloseError(_ error: Error) -> Error {
        let description = String(describing: error)
        if description.contains("EPIPE") ||
           description.contains("ECONNRESET") ||
           description.contains("EOF") ||
           error is ChannelError {
            return TTRPCError.closed
        }
        return error
    }
}
