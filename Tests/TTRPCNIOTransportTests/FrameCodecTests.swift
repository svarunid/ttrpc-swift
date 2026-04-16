import Testing
import NIOCore
import NIOEmbedded
@testable import TTRPCCore
@testable import TTRPCNIOTransport

@Suite("TTRPCFrameDecoder Tests")
struct FrameDecoderTests {

    @Test("Decode a valid request frame")
    func decodeValidRequest() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(TTRPCFrameDecoder()))

        // Build a valid ttrpc frame: 10-byte header + payload
        let payload = "hello world"
        let payloadBytes = Array(payload.utf8)

        var buffer = ByteBuffer()
        // Length (4 bytes, big-endian)
        buffer.writeInteger(UInt32(payloadBytes.count), endianness: .big, as: UInt32.self)
        // Stream ID (4 bytes, big-endian)
        buffer.writeInteger(UInt32(1), endianness: .big, as: UInt32.self)
        // Message type
        buffer.writeInteger(UInt8(0x01), as: UInt8.self) // request
        // Flags
        buffer.writeInteger(UInt8(0x00), as: UInt8.self)
        // Payload
        buffer.writeBytes(payloadBytes)

        try channel.writeInbound(buffer)

        let frame: TTRPCFrame = try channel.readInbound()!
        #expect(frame.header.messageType == .request)
        #expect(frame.header.streamID == 1)
        #expect(frame.header.flags == [])
        #expect(frame.header.length == UInt32(payloadBytes.count))
        #expect(frame.payload.readableBytes == payloadBytes.count)

        try channel.finish()
    }

    @Test("Decode a frame with flags")
    func decodeWithFlags() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(TTRPCFrameDecoder()))

        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(0), endianness: .big, as: UInt32.self) // length = 0
        buffer.writeInteger(UInt32(3), endianness: .big, as: UInt32.self) // stream ID = 3
        buffer.writeInteger(UInt8(0x03), as: UInt8.self) // data
        buffer.writeInteger(UInt8(0x05), as: UInt8.self) // remoteClosed | noData

        try channel.writeInbound(buffer)

        let frame: TTRPCFrame = try channel.readInbound()!
        #expect(frame.header.messageType == .data)
        #expect(frame.header.streamID == 3)
        #expect(frame.header.flags.contains(.remoteClosed))
        #expect(frame.header.flags.contains(.noData))

        try channel.finish()
    }

    @Test("Partial read buffers correctly")
    func partialRead() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(TTRPCFrameDecoder()))

        let payload = Array("test".utf8)

        // Send first 6 bytes (partial header + data)
        var part1 = ByteBuffer()
        part1.writeInteger(UInt32(payload.count), endianness: .big, as: UInt32.self)
        part1.writeBytes([0x00, 0x00]) // first 2 bytes of stream ID

        try channel.writeInbound(part1)
        let noFrame: TTRPCFrame? = try channel.readInbound()
        #expect(noFrame == nil) // Not enough data yet

        // Send remaining bytes
        var part2 = ByteBuffer()
        part2.writeBytes([0x00, 0x01]) // rest of stream ID
        part2.writeInteger(UInt8(0x01), as: UInt8.self) // request
        part2.writeInteger(UInt8(0x00), as: UInt8.self) // flags
        part2.writeBytes(payload)

        try channel.writeInbound(part2)

        let frame: TTRPCFrame = try channel.readInbound()!
        #expect(frame.header.streamID == 1)
        #expect(frame.payload.readableBytes == payload.count)

        try channel.finish()
    }

    @Test("Reject oversized message")
    func rejectOversized() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(TTRPCFrameDecoder()))

        var buffer = ByteBuffer()
        // Length exceeding 4MB
        let oversizedLength: UInt32 = (4 << 20) + 1
        buffer.writeInteger(oversizedLength, endianness: .big, as: UInt32.self)
        buffer.writeInteger(UInt32(1), endianness: .big, as: UInt32.self)
        buffer.writeInteger(UInt8(0x01), as: UInt8.self)
        buffer.writeInteger(UInt8(0x00), as: UInt8.self)

        #expect(throws: TTRPCError.self) {
            try channel.writeInbound(buffer)
        }

        try? channel.finish()
    }

    @Test("Reject reserved byte non-zero")
    func rejectReservedByte() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(TTRPCFrameDecoder()))

        var buffer = ByteBuffer()
        // First byte of length is reserved and must be 0
        // Set it to 0x01 (length = 0x01000004 -- reserved byte is 0x01)
        buffer.writeBytes([0x01, 0x00, 0x00, 0x04]) // reserved byte = 1
        buffer.writeInteger(UInt32(1), endianness: .big, as: UInt32.self)
        buffer.writeInteger(UInt8(0x01), as: UInt8.self)
        buffer.writeInteger(UInt8(0x00), as: UInt8.self)

        #expect(throws: TTRPCError.self) {
            try channel.writeInbound(buffer)
        }

        try? channel.finish()
    }

    @Test("Multiple frames in one buffer")
    func multipleFrames() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(TTRPCFrameDecoder()))

        var buffer = ByteBuffer()

        // Frame 1: empty payload, stream 1
        buffer.writeInteger(UInt32(0), endianness: .big, as: UInt32.self)
        buffer.writeInteger(UInt32(1), endianness: .big, as: UInt32.self)
        buffer.writeInteger(UInt8(0x01), as: UInt8.self)
        buffer.writeInteger(UInt8(0x00), as: UInt8.self)

        // Frame 2: empty payload, stream 3
        buffer.writeInteger(UInt32(0), endianness: .big, as: UInt32.self)
        buffer.writeInteger(UInt32(3), endianness: .big, as: UInt32.self)
        buffer.writeInteger(UInt8(0x02), as: UInt8.self) // response
        buffer.writeInteger(UInt8(0x00), as: UInt8.self)

        try channel.writeInbound(buffer)

        let frame1: TTRPCFrame = try channel.readInbound()!
        #expect(frame1.header.streamID == 1)
        #expect(frame1.header.messageType == .request)

        let frame2: TTRPCFrame = try channel.readInbound()!
        #expect(frame2.header.streamID == 3)
        #expect(frame2.header.messageType == .response)

        try channel.finish()
    }
}

@Suite("TTRPCFrameEncoder Tests")
struct FrameEncoderTests {

    @Test("Encode a frame produces correct wire bytes")
    func encodeFrame() throws {
        let channel = EmbeddedChannel(handler: MessageToByteHandler(TTRPCFrameEncoder()))

        var payload = ByteBuffer()
        payload.writeString("test")

        let frame = TTRPCFrame(
            streamID: 1,
            messageType: .request,
            flags: [],
            payload: payload
        )

        try channel.writeOutbound(frame)

        var encoded: ByteBuffer = try channel.readOutbound()!

        // Verify wire format
        let length = encoded.readInteger(endianness: .big, as: UInt32.self)!
        let streamID = encoded.readInteger(endianness: .big, as: UInt32.self)!
        let typeByte = encoded.readInteger(as: UInt8.self)!
        let flagsByte = encoded.readInteger(as: UInt8.self)!

        #expect(length == 4) // "test" = 4 bytes
        #expect(streamID == 1)
        #expect(typeByte == 0x01) // request
        #expect(flagsByte == 0x00)

        let payloadStr = encoded.readString(length: 4)!
        #expect(payloadStr == "test")

        try channel.finish()
    }

    @Test("Encode-decode round-trip through pipeline")
    func encoderDecoderRoundTrip() throws {
        // Create a pipeline with both encoder and decoder
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandlers([
            ByteToMessageHandler(TTRPCFrameDecoder()),
            MessageToByteHandler(TTRPCFrameEncoder()),
        ]).wait()

        var payload = ByteBuffer()
        payload.writeString("round-trip-test")

        let originalFrame = TTRPCFrame(
            streamID: 5,
            messageType: .data,
            flags: .remoteClosed,
            payload: payload
        )

        // Encode
        try channel.writeOutbound(originalFrame)
        var encoded: ByteBuffer = try channel.readOutbound()!

        // Decode
        try channel.writeInbound(encoded)
        let decodedFrame: TTRPCFrame = try channel.readInbound()!

        #expect(decodedFrame.header.streamID == 5)
        #expect(decodedFrame.header.messageType == .data)
        #expect(decodedFrame.header.flags == .remoteClosed)
        #expect(decodedFrame.payload.readableBytes == "round-trip-test".utf8.count)

        try channel.finish()
    }
}
