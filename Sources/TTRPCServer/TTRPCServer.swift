import Foundation
import NIOCore
import NIOPosix
import TTRPCCore
import TTRPCNIOTransport

/// A ttrpc server that listens on a Unix domain socket and dispatches RPCs
/// to registered service handlers.
///
/// Usage:
/// ```swift
/// let server = TTRPCServer(services: [MyService()])
/// try await server.serve(unixDomainSocketPath: "/tmp/my-service.sock")
/// ```
///
/// The server uses structured concurrency: each accepted connection runs as a
/// child task. Calling `shutdown()` or cancelling the task running `serve()`
/// will gracefully drain all connections.
public final class TTRPCServer: Sendable {
    private let router: ServiceRouter
    private let handshaker: any TTRPCHandshaker
    private let interceptors: [any TTRPCServerInterceptor]
    private let shutdownSignal: AsyncStream<Void>
    private let shutdownContinuation: AsyncStream<Void>.Continuation

    /// Create a new ttrpc server.
    ///
    /// - Parameters:
    ///   - services: The service implementations to register.
    ///   - interceptors: Server-side interceptors applied to every request.
    ///   - handshaker: Optional connection handshaker for authentication.
    public init(
        services: [any TTRPCServiceRegistration],
        interceptors: [any TTRPCServerInterceptor] = [],
        handshaker: (any TTRPCHandshaker)? = nil
    ) {
        self.router = ServiceRouter(services: services)
        self.handshaker = handshaker ?? NoopHandshaker()
        self.interceptors = interceptors
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        self.shutdownSignal = stream
        self.shutdownContinuation = continuation
    }

    /// Start serving on a Unix domain socket.
    ///
    /// This method blocks until the server is shut down (via `shutdown()` or task cancellation).
    /// It removes any existing socket file at the path before binding.
    ///
    /// - Parameters:
    ///   - path: The filesystem path for the Unix domain socket.
    ///   - eventLoopGroup: The NIO event loop group. Defaults to the singleton.
    public func serve(
        unixDomainSocketPath path: String,
        eventLoopGroup: EventLoopGroup? = nil
    ) async throws {
        // Remove stale socket file if it exists
        try? FileManager.default.removeItem(atPath: path)

        let group = eventLoopGroup ?? MultiThreadedEventLoopGroup.singleton
        let serverChannel = try await TTRPCUnixTransport.listen(path: path, eventLoopGroup: group)

        // Use a stream to bridge accepted connections into the task group
        let (connectionStream, connectionContinuation) = AsyncStream.makeStream(
            of: NIOAsyncChannel<TTRPCFrame, TTRPCFrame>.self
        )

        await withTaskGroup(of: Void.self) { taskGroup in
            // Task 1: Accept connections and push them into the stream
            taskGroup.addTask { [handshaker = self.handshaker] in
                do {
                    try await serverChannel.executeThenClose { inbound in
                        for try await clientChannel in inbound {
                            _ = try? handshaker.handshake(channel: clientChannel.channel)
                            connectionContinuation.yield(clientChannel)
                        }
                    }
                } catch {
                    // Server channel closed
                }
                connectionContinuation.finish()
            }

            // Task 2: Wait for shutdown signal
            taskGroup.addTask {
                for await _ in self.shutdownSignal {
                    return
                }
            }

            // Main loop: consume accepted connections and spawn handlers
            for await clientChannel in connectionStream {
                let credentials = try? self.handshaker.handshake(channel: clientChannel.channel)
                let connection = ServerConnection(
                    router: self.router,
                    interceptors: self.interceptors,
                    peerCredentials: credentials
                )
                taskGroup.addTask {
                    await connection.run(channel: clientChannel)
                }
            }

            // connectionStream finished, cancel all remaining tasks
            taskGroup.cancelAll()
        }

        // Clean up socket file
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Gracefully shut down the server.
    ///
    /// Signals the serve loop to stop accepting new connections and waits
    /// for in-flight requests to complete.
    public func shutdown() {
        shutdownContinuation.yield()
        shutdownContinuation.finish()
    }
}
