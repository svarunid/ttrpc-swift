import NIOCore
import TTRPCCore

/// Encodes ttrpc frames into bytes for transmission.
///
/// Writes the 10-byte header (length, streamID, type, flags) followed by the payload.
/// Validates that the payload does not exceed the 4 MB maximum.
public struct TTRPCFrameEncoder: MessageToByteEncoder {
    public typealias OutboundIn = TTRPCFrame

    public init() {}

    public func encode(data frame: TTRPCFrame, out buffer: inout ByteBuffer) throws {
        let payloadLength = frame.payload.readableBytes

        guard payloadLength <= MessageHeader.maxDataLength else {
            throw TTRPCError.oversizedMessage(
                actualLength: payloadLength,
                maximumLength: Int(MessageHeader.maxDataLength)
            )
        }

        // Write the 10-byte header
        buffer.writeInteger(UInt32(payloadLength), endianness: .big, as: UInt32.self)
        buffer.writeInteger(frame.header.streamID, endianness: .big, as: UInt32.self)
        buffer.writeInteger(frame.header.messageType.rawValue, as: UInt8.self)
        buffer.writeInteger(frame.header.flags.rawValue, as: UInt8.self)

        // Write the payload
        var payload = frame.payload
        buffer.writeBuffer(&payload)
    }
}
