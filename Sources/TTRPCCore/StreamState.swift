/// Tracks the two-sided closure state of a ttrpc stream.
///
/// Per the protocol specification, a stream has two closure flags:
/// - `localClosed`: this side has finished sending
/// - `remoteClosed`: the other side has finished sending
///
/// A stream is fully closed when both flags are set. The protocol
/// expects the client to reach `localClosed` before `remoteClosed`,
/// and the server to reach `remoteClosed` before `localClosed`.
public struct StreamState: Sendable, Hashable {
    /// Whether the local side has closed its send direction.
    public private(set) var localClosed: Bool

    /// Whether the remote side has closed its send direction.
    public private(set) var remoteClosed: Bool

    public init(localClosed: Bool = false, remoteClosed: Bool = false) {
        self.localClosed = localClosed
        self.remoteClosed = remoteClosed
    }

    /// Whether both sides have closed, meaning the stream is fully done.
    public var isFullyClosed: Bool {
        localClosed && remoteClosed
    }

    /// Mark the local side as closed.
    @discardableResult
    public mutating func closeLocal() -> Bool {
        guard !localClosed else { return false }
        localClosed = true
        return true
    }

    /// Mark the remote side as closed.
    @discardableResult
    public mutating func closeRemote() -> Bool {
        guard !remoteClosed else { return false }
        remoteClosed = true
        return true
    }
}
