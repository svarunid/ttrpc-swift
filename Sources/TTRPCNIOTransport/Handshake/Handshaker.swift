import NIOCore
import NIOPosix
import TTRPCCore

/// Protocol for ttrpc connection handshakers.
///
/// A handshaker can verify peer credentials, perform authentication,
/// or modify the connection during setup. The server calls the handshaker
/// for each accepted connection before processing requests.
public protocol TTRPCHandshaker: Sendable {
    /// Perform the handshake on an accepted connection.
    ///
    /// - Parameter channel: The NIO channel for the connection.
    /// - Returns: Peer credentials if available, or `nil`.
    func handshake(channel: Channel) throws -> TTRPCPeerCredentials?
}
