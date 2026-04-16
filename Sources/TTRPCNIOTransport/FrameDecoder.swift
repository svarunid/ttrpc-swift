import NIOCore
import TTRPCCore

/// Decodes ttrpc frames from a byte stream.
///
/// The ttrpc wire protocol uses a fixed 10-byte header followed by a variable-length
/// payload. This decoder handles partial reads (buffering incomplete frames) and
/// validates the protocol constraints:
/// - The reserved byte (first byte of the length field) must be zero
/// - The payload length must not exceed 4 MB
public struct TTRPCFrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = TTRPCFrame

    public init() {}

    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Need at least 10 bytes for the header
        guard buffer.readableBytes >= MessageHeader.encodedSize else {
            return .needMoreData
        }

        // Peek at the length field without advancing the reader index
        let savedReaderIndex = buffer.readerIndex
        guard let rawLength = buffer.getInteger(at: savedReaderIndex, endianness: .big, as: UInt32.self) else {
            return .needMoreData
        }

        // The first byte of the length field is reserved and must be zero
        let reservedByte = UInt8(rawLength >> 24)
        guard reservedByte == 0 else {
            throw TTRPCError.protocolError("reserved byte in length field must be 0, got \(reservedByte)")
        }

        // The effective length is the lower 3 bytes
        let dataLength = rawLength & 0x00FF_FFFF

        // Validate max message size
        guard dataLength <= MessageHeader.maxDataLength else {
            // Per the Go implementation: discard the oversized message and report error
            let totalSize = MessageHeader.encodedSize + Int(dataLength)
            if buffer.readableBytes >= totalSize {
                buffer.moveReaderIndex(forwardBy: totalSize)
            }
            throw TTRPCError.oversizedMessage(
                actualLength: Int(dataLength),
                maximumLength: Int(MessageHeader.maxDataLength)
            )
        }

        // Check we have the complete frame (header + payload)
        let totalFrameSize = MessageHeader.encodedSize + Int(dataLength)
        guard buffer.readableBytes >= totalFrameSize else {
            return .needMoreData
        }

        // Now consume the header bytes
        buffer.moveReaderIndex(forwardBy: 4) // skip length (already read)
        guard let streamID = buffer.readInteger(endianness: .big, as: UInt32.self),
              let typeByte = buffer.readInteger(as: UInt8.self),
              let flagsByte = buffer.readInteger(as: UInt8.self)
        else {
            // Should not happen since we verified readableBytes above
            buffer.moveReaderIndex(to: savedReaderIndex)
            return .needMoreData
        }

        guard let messageType = MessageType(rawValue: typeByte) else {
            throw TTRPCError.protocolError("unknown message type: \(typeByte)")
        }

        // Read the payload
        let payload: ByteBuffer
        if dataLength > 0 {
            guard let slice = buffer.readSlice(length: Int(dataLength)) else {
                buffer.moveReaderIndex(to: savedReaderIndex)
                return .needMoreData
            }
            payload = slice
        } else {
            payload = ByteBuffer()
        }

        let header = MessageHeader(
            length: dataLength,
            streamID: streamID,
            messageType: messageType,
            flags: MessageFlags(rawValue: flagsByte)
        )

        context.fireChannelRead(wrapInboundOut(TTRPCFrame(header: header, payload: payload)))
        return .continue
    }

    public mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}
