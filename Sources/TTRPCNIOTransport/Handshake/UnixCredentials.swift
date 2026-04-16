#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import NIOCore
import NIOPosix
import TTRPCCore

/// A NIO channel handler that extracts Unix peer credentials from the socket
/// during channel activation and stores them in a promise.
///
/// This handler must be the first handler added to the pipeline so it runs
/// before the channel is handed off to async code.
public final class PeerCredentialsHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<TTRPCPeerCredentials?>

    public init(promise: EventLoopPromise<TTRPCPeerCredentials?>) {
        self.promise = promise
    }

    public func channelActive(context: ChannelHandlerContext) {
        let credentials: TTRPCPeerCredentials?
        do {
            credentials = try Self.extractCredentials(channel: context.channel)
        } catch {
            credentials = nil
        }
        promise.succeed(credentials)

        // Remove ourselves from the pipeline -- we're done
        context.pipeline.removeHandler(context: context, promise: nil)
        context.fireChannelActive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    /// Extract peer credentials from a channel's underlying socket.
    ///
    /// Uses platform-specific syscalls:
    /// - macOS: `getpeereid()`
    /// - Linux: `SO_PEERCRED` via `getsockopt()`
    static func extractCredentials(channel: Channel) throws -> TTRPCPeerCredentials? {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        // On macOS, we use LOCAL_PEERCRED socket option via NIO's socket option provider
        guard let provider = channel as? (any SocketOptionProvider) else {
            return nil
        }
        // Use NIO's socket option to get SO_PEERCRED equivalent
        // On Darwin, we can request LOCAL_PEERCRED via the raw socket option
        do {
            let cred: xucred = try provider.unsafeGetSocketOption(
                level: SOL_LOCAL,
                name: LOCAL_PEERCRED
            ).wait()
            return TTRPCPeerCredentials(
                uid: cred.cr_uid,
                gid: cred.cr_groups.0,  // First group is the primary GID
                pid: 0  // macOS LOCAL_PEERCRED doesn't provide PID
            )
        } catch {
            return nil
        }
        #elseif os(Linux)
        guard let provider = channel as? (any SocketOptionProvider) else {
            return nil
        }
        do {
            let cred: ucred = try provider.unsafeGetSocketOption(
                level: SOL_SOCKET,
                name: SO_PEERCRED
            ).wait()
            return TTRPCPeerCredentials(
                uid: UInt32(cred.uid),
                gid: UInt32(cred.gid),
                pid: cred.pid
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

/// A handshaker that validates Unix peer credentials.
///
/// Uses `PeerCredentialsHandler` to extract credentials from the socket,
/// then applies the configured validation policy.
public struct UnixCredentialsHandshaker: TTRPCHandshaker {
    public enum Validation: Sendable {
        /// Accept any peer.
        case any
        /// Require the peer to have the specified UID and GID. Use -1 as wildcard.
        case requireUIDGID(uid: Int32, gid: Int32)
        /// Require the peer to be root (UID 0, GID 0).
        case requireRoot
        /// Require the peer to be the same user as this process.
        case requireSameUser
    }

    private let validation: Validation

    public init(validation: Validation = .any) {
        self.validation = validation
    }

    public func handshake(channel: Channel) throws -> TTRPCPeerCredentials? {
        let credentials = try PeerCredentialsHandler.extractCredentials(channel: channel)

        guard let credentials else {
            if case .any = validation {
                return nil
            }
            throw TTRPCError.protocolError("unable to extract peer credentials")
        }

        switch validation {
        case .any:
            break
        case .requireUIDGID(let uid, let gid):
            if uid != -1 && credentials.uid != UInt32(uid) {
                throw TTRPCError.protocolError("peer UID \(credentials.uid) does not match required \(uid)")
            }
            if gid != -1 && credentials.gid != UInt32(gid) {
                throw TTRPCError.protocolError("peer GID \(credentials.gid) does not match required \(gid)")
            }
        case .requireRoot:
            guard credentials.uid == 0 && credentials.gid == 0 else {
                throw TTRPCError.protocolError("peer is not root (uid=\(credentials.uid), gid=\(credentials.gid))")
            }
        case .requireSameUser:
            let myUID = getuid()
            guard credentials.uid == myUID else {
                throw TTRPCError.protocolError("peer UID \(credentials.uid) does not match process UID \(myUID)")
            }
        }

        return credentials
    }
}
