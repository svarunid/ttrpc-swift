import NIOCore
import NIOPosix
import TTRPCCore

/// Provides Unix domain socket transport for ttrpc connections.
///
/// Sets up the NIO channel pipeline with frame encoder/decoder handlers
/// and provides async interfaces for both client connections and server listeners.
public enum TTRPCUnixTransport {

    // MARK: - Client

    /// Connect to a ttrpc server over a Unix domain socket.
    ///
    /// - Parameters:
    ///   - path: The filesystem path of the Unix domain socket.
    ///   - eventLoopGroup: The NIO event loop group to use.
    /// - Returns: An `NIOAsyncChannel` for sending and receiving `TTRPCFrame`s.
    public static func connect(
        path: String,
        eventLoopGroup: EventLoopGroup
    ) async throws -> NIOAsyncChannel<TTRPCFrame, TTRPCFrame> {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)

        return try await bootstrap.connect(
            unixDomainSocketPath: path
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers([
                    ByteToMessageHandler(TTRPCFrameDecoder()),
                    MessageToByteHandler(TTRPCFrameEncoder()),
                ])
                return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
            }
        }
    }

    // MARK: - Server

    /// Bind and listen on a Unix domain socket for incoming ttrpc connections.
    ///
    /// - Parameters:
    ///   - path: The filesystem path to bind the Unix domain socket.
    ///   - eventLoopGroup: The NIO event loop group to use.
    /// - Returns: A bound server channel that yields accepted client connections.
    public static func listen(
        path: String,
        eventLoopGroup: EventLoopGroup
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<TTRPCFrame, TTRPCFrame>, Never> {
        let serverBootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

        return try await serverBootstrap.bind(
            unixDomainSocketPath: path
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers([
                    ByteToMessageHandler(TTRPCFrameDecoder()),
                    MessageToByteHandler(TTRPCFrameEncoder()),
                ])
                return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
            }
        }
    }
}
