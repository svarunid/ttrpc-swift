/// gRPC status codes used by the ttrpc protocol for error reporting.
///
/// These map to the `google.rpc.Status` codes carried in the ttrpc `Response` message.
public enum StatusCode: Int32, Sendable, Hashable {
    case ok = 0
    case cancelled = 1
    case unknown = 2
    case invalidArgument = 3
    case deadlineExceeded = 4
    case notFound = 5
    case alreadyExists = 6
    case permissionDenied = 7
    case resourceExhausted = 8
    case failedPrecondition = 9
    case aborted = 10
    case outOfRange = 11
    case unimplemented = 12
    case `internal` = 13
    case unavailable = 14
    case dataLoss = 15
    case unauthenticated = 16
}

/// Convert a Swift error to a gRPC status code.
///
/// Mirrors the Go implementation's `convertCode()` function.
public func statusCode(for error: Error) -> StatusCode {
    if let ttrpcError = error as? TTRPCError {
        switch ttrpcError {
        case .closed, .serverClosed, .streamClosed:
            return .unavailable
        case .protocolError:
            return .internal
        case .oversizedMessage:
            return .resourceExhausted
        case .invalidStreamID:
            return .internal
        case .serviceNotFound:
            return .unimplemented
        case .remoteError(let code, _):
            return StatusCode(rawValue: code) ?? .unknown
        case .deadlineExceeded:
            return .deadlineExceeded
        }
    }

    if error is CancellationError {
        return .cancelled
    }

    return .unknown
}
