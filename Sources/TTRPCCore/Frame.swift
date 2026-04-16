import NIOCore

// MARK: - Message Types

/// The type of a ttrpc protocol message.
///
/// Defined in the ttrpc protocol specification:
/// - Request (0x01): Initiates a stream
/// - Response (0x02): Terminates a stream
/// - Data (0x03): Transmits data on a non-unary stream
public enum MessageType: UInt8, Sendable, Hashable {
    case request = 0x01
    case response = 0x02
    case data = 0x03
}

// MARK: - Message Flags

/// Flags carried in the ttrpc message header.
///
/// Different flags are valid for different message types:
/// - Request: `remoteClosed` (0x01) or `remoteOpen` (0x02), empty = unary
/// - Response: no flags defined
/// - Data: `remoteClosed` (0x01), `noData` (0x04)
public struct MessageFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The remote side has closed its send direction.
    public static let remoteClosed = MessageFlags(rawValue: 0x01)

    /// The remote side is still open for sending (non-unary request).
    public static let remoteOpen = MessageFlags(rawValue: 0x02)

    /// The message carries no data payload.
    public static let noData = MessageFlags(rawValue: 0x04)
}

// MARK: - Message Header

/// The fixed 10-byte header prepended to every ttrpc frame on the wire.
///
/// Wire layout (big-endian):
/// ```
/// [0..3]  data length (uint32, first byte reserved = 0)
/// [4..7]  stream ID (uint32)
/// [8]     message type (uint8)
/// [9]     flags (uint8)
/// ```
public struct MessageHeader: Sendable, Hashable {
    /// Size of the encoded header in bytes.
    public static let encodedSize = 10

    /// Maximum allowed data length (4 MB).
    public static let maxDataLength: UInt32 = 4 << 20

    /// Length of the data payload following the header.
    public var length: UInt32

    /// Identifies the stream this message belongs to.
    public var streamID: UInt32

    /// The type of this message.
    public var messageType: MessageType

    /// Type-specific flags.
    public var flags: MessageFlags

    public init(length: UInt32, streamID: UInt32, messageType: MessageType, flags: MessageFlags) {
        self.length = length
        self.streamID = streamID
        self.messageType = messageType
        self.flags = flags
    }
}

// MARK: - ByteBuffer encoding/decoding

extension MessageHeader {
    /// Decode a `MessageHeader` from the given `ByteBuffer`.
    ///
    /// Reads exactly `encodedSize` (10) bytes. Returns `nil` if there are
    /// insufficient readable bytes.
    public static func decode(from buffer: inout ByteBuffer) -> MessageHeader? {
        guard buffer.readableBytes >= encodedSize else { return nil }

        guard let length = buffer.readInteger(endianness: .big, as: UInt32.self),
              let streamID = buffer.readInteger(endianness: .big, as: UInt32.self),
              let typeByte = buffer.readInteger(as: UInt8.self),
              let flagsByte = buffer.readInteger(as: UInt8.self)
        else {
            return nil
        }

        guard let messageType = MessageType(rawValue: typeByte) else {
            return nil
        }

        return MessageHeader(
            length: length,
            streamID: streamID,
            messageType: messageType,
            flags: MessageFlags(rawValue: flagsByte)
        )
    }

    /// Encode this `MessageHeader` into the given `ByteBuffer`.
    public func encode(into buffer: inout ByteBuffer) {
        buffer.writeInteger(length, endianness: .big, as: UInt32.self)
        buffer.writeInteger(streamID, endianness: .big, as: UInt32.self)
        buffer.writeInteger(messageType.rawValue, as: UInt8.self)
        buffer.writeInteger(flags.rawValue, as: UInt8.self)
    }
}
