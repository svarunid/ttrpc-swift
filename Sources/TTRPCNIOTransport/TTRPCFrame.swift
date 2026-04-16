import NIOCore
import TTRPCCore

/// A fully decoded ttrpc frame consisting of a header and payload.
///
/// This is the unit of data flowing through the NIO channel pipeline
/// after decoding and before encoding.
public struct TTRPCFrame: Sendable, Hashable {
    /// The 10-byte message header.
    public var header: MessageHeader

    /// The payload bytes following the header.
    public var payload: ByteBuffer

    public init(header: MessageHeader, payload: ByteBuffer) {
        self.header = header
        self.payload = payload
    }

    /// Create a frame for sending with automatic length calculation.
    public init(streamID: UInt32, messageType: MessageType, flags: MessageFlags, payload: ByteBuffer) {
        self.header = MessageHeader(
            length: UInt32(payload.readableBytes),
            streamID: streamID,
            messageType: messageType,
            flags: flags
        )
        self.payload = payload
    }
}
