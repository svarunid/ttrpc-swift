/// Errors produced by the ttrpc protocol implementation.
public enum TTRPCError: Error, Sendable, Hashable {
    /// A protocol-level violation was detected.
    case protocolError(String)

    /// The client connection has been closed.
    case closed

    /// The server has been shut down.
    case serverClosed

    /// The stream has been closed.
    case streamClosed

    /// A message exceeded the maximum allowed size (4 MB).
    case oversizedMessage(actualLength: Int, maximumLength: Int)

    /// An invalid stream ID was received.
    case invalidStreamID(UInt32)

    /// No registered service/method matched the request.
    case serviceNotFound(service: String, method: String)

    /// The remote returned an error status.
    case remoteError(code: Int32, message: String)

    /// Deadline exceeded for the request.
    case deadlineExceeded
}
