/// A strongly-typed ttrpc stream identifier.
///
/// Per the protocol specification:
/// - Odd stream IDs are client-initiated
/// - Even stream IDs are server-initiated
/// - Stream IDs must increase monotonically within a connection
public struct StreamID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Whether this stream was initiated by the client (odd ID).
    public var isClientInitiated: Bool {
        rawValue & 1 == 1
    }

    /// Whether this stream was initiated by the server (even ID).
    public var isServerInitiated: Bool {
        rawValue & 1 == 0 && rawValue != 0
    }

    public var description: String {
        "StreamID(\(rawValue))"
    }
}

extension StreamID: Comparable {
    public static func < (lhs: StreamID, rhs: StreamID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
