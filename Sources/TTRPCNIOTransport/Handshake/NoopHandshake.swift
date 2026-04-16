import NIOCore
import TTRPCCore

/// A no-op handshaker that accepts all connections without authentication.
public struct NoopHandshaker: TTRPCHandshaker {
    public init() {}

    public func handshake(channel: Channel) throws -> TTRPCPeerCredentials? {
        nil
    }
}
