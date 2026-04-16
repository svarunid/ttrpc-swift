import Foundation

/// Context passed to client interceptors.
public struct ClientInterceptorContext: Sendable {
    /// The fully-qualified method path (e.g., "/service.Name/MethodName").
    public let method: String

    /// Metadata for the outgoing request.
    public var metadata: TTRPCMetadata

    public init(method: String, metadata: TTRPCMetadata = TTRPCMetadata()) {
        self.method = method
        self.metadata = metadata
    }
}

/// Context passed to server interceptors.
public struct ServerInterceptorContext: Sendable {
    /// The fully-qualified method path.
    public let method: String

    /// Metadata from the incoming request.
    public let metadata: TTRPCMetadata

    /// Peer credentials, if available.
    public let peerCredentials: TTRPCPeerCredentials?

    public init(
        method: String,
        metadata: TTRPCMetadata = TTRPCMetadata(),
        peerCredentials: TTRPCPeerCredentials? = nil
    ) {
        self.method = method
        self.metadata = metadata
        self.peerCredentials = peerCredentials
    }
}

/// A client-side unary interceptor.
///
/// Interceptors form a chain. Each interceptor can inspect/modify the request,
/// call `next` to continue the chain, and inspect/modify the response.
public protocol TTRPCClientInterceptor: Sendable {
    func intercept(
        request: Data,
        context: ClientInterceptorContext,
        next: @Sendable (Data, ClientInterceptorContext) async throws -> Data
    ) async throws -> Data
}

/// A server-side unary interceptor.
public protocol TTRPCServerInterceptor: Sendable {
    func intercept(
        request: Data,
        context: ServerInterceptorContext,
        next: @Sendable (Data, ServerInterceptorContext) async throws -> Data
    ) async throws -> Data
}

/// Build a chained interceptor function from an array of interceptors.
public func chainClientInterceptors(
    _ interceptors: [any TTRPCClientInterceptor],
    finally handler: @escaping @Sendable (Data, ClientInterceptorContext) async throws -> Data
) -> @Sendable (Data, ClientInterceptorContext) async throws -> Data {
    var chain = handler
    for interceptor in interceptors.reversed() {
        let next = chain
        chain = { data, context in
            try await interceptor.intercept(request: data, context: context, next: next)
        }
    }
    return chain
}

/// Build a chained server interceptor function from an array of interceptors.
public func chainServerInterceptors(
    _ interceptors: [any TTRPCServerInterceptor],
    finally handler: @escaping @Sendable (Data, ServerInterceptorContext) async throws -> Data
) -> @Sendable (Data, ServerInterceptorContext) async throws -> Data {
    var chain = handler
    for interceptor in interceptors.reversed() {
        let next = chain
        chain = { data, context in
            try await interceptor.intercept(request: data, context: context, next: next)
        }
    }
    return chain
}
