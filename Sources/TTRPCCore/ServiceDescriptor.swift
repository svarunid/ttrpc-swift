/// Describes a ttrpc service for registration with a server.
public struct TTRPCServiceDescriptor: Sendable {
    /// The fully-qualified service name (e.g., "containerd.runtime.task.v2.Task").
    public let name: String

    /// Unary methods offered by this service.
    public let methods: [String: TTRPCMethodDescriptor]

    /// Streaming methods offered by this service.
    public let streams: [String: TTRPCStreamDescriptor]

    public init(
        name: String,
        methods: [String: TTRPCMethodDescriptor] = [:],
        streams: [String: TTRPCStreamDescriptor] = [:]
    ) {
        self.name = name
        self.methods = methods
        self.streams = streams
    }
}

/// Describes a unary RPC method.
public struct TTRPCMethodDescriptor: Sendable {
    /// The method name.
    public let name: String

    /// The handler that processes incoming requests.
    ///
    /// Receives serialized request bytes and returns serialized response bytes.
    public let handler: @Sendable (_ context: TTRPCHandlerContext, _ requestData: Data) async throws -> Data

    public init(
        name: String,
        handler: @escaping @Sendable (_ context: TTRPCHandlerContext, _ requestData: Data) async throws -> Data
    ) {
        self.name = name
        self.handler = handler
    }
}

/// Describes a streaming RPC method.
public struct TTRPCStreamDescriptor: Sendable {
    /// The method name.
    public let name: String

    /// Whether the client sends a stream of messages.
    public let clientStreaming: Bool

    /// Whether the server sends a stream of messages.
    public let serverStreaming: Bool

    /// The handler for this streaming method.
    public let handler: @Sendable (_ context: TTRPCHandlerContext, _ stream: TTRPCServerStreamInterface) async throws -> Void

    public init(
        name: String,
        clientStreaming: Bool,
        serverStreaming: Bool,
        handler: @escaping @Sendable (_ context: TTRPCHandlerContext, _ stream: TTRPCServerStreamInterface) async throws -> Void
    ) {
        self.name = name
        self.clientStreaming = clientStreaming
        self.serverStreaming = serverStreaming
        self.handler = handler
    }
}

/// Context passed to service method handlers.
public struct TTRPCHandlerContext: Sendable {
    /// Metadata from the incoming request.
    public let metadata: TTRPCMetadata

    /// Peer credentials, if available.
    public let peerCredentials: TTRPCPeerCredentials?

    /// The deadline for this request, if set.
    public let deadline: ContinuousClock.Instant?

    public init(
        metadata: TTRPCMetadata = TTRPCMetadata(),
        peerCredentials: TTRPCPeerCredentials? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) {
        self.metadata = metadata
        self.peerCredentials = peerCredentials
        self.deadline = deadline
    }
}

/// Peer credentials obtained from the Unix domain socket.
public struct TTRPCPeerCredentials: Sendable, Hashable {
    public let uid: UInt32
    public let gid: UInt32
    public let pid: Int32

    public init(uid: UInt32, gid: UInt32, pid: Int32) {
        self.uid = uid
        self.gid = gid
        self.pid = pid
    }
}

/// Interface for server-side streaming operations.
public protocol TTRPCServerStreamInterface: Sendable {
    func sendData(_ data: Data) async throws
    func receiveData() async throws -> Data
    func closeSend() async throws
}

/// Protocol that service types conform to for registration with a server.
public protocol TTRPCServiceRegistration: Sendable {
    var serviceDescriptor: TTRPCServiceDescriptor { get }
}

import Foundation
