import Testing
import NIOCore
@testable import TTRPCCore

@Suite("MessageHeader Tests")
struct MessageHeaderTests {

    @Test("Encode and decode round-trip")
    func encodeDecodeRoundTrip() {
        let original = MessageHeader(
            length: 256,
            streamID: 1,
            messageType: .request,
            flags: []
        )

        var buffer = ByteBuffer()
        original.encode(into: &buffer)

        #expect(buffer.readableBytes == MessageHeader.encodedSize)

        var decoded = MessageHeader.decode(from: &buffer)
        #expect(decoded != nil)
        #expect(decoded! == original)
    }

    @Test("Encode and decode with all message types")
    func allMessageTypes() {
        for messageType in [MessageType.request, .response, .data] {
            let header = MessageHeader(
                length: 100,
                streamID: 3,
                messageType: messageType,
                flags: .remoteClosed
            )

            var buffer = ByteBuffer()
            header.encode(into: &buffer)

            let decoded = MessageHeader.decode(from: &buffer)
            #expect(decoded?.messageType == messageType)
        }
    }

    @Test("Encode and decode with flags")
    func flagEncoding() {
        let flags: MessageFlags = [.remoteClosed, .noData]
        let header = MessageHeader(
            length: 0,
            streamID: 5,
            messageType: .data,
            flags: flags
        )

        var buffer = ByteBuffer()
        header.encode(into: &buffer)

        let decoded = MessageHeader.decode(from: &buffer)
        #expect(decoded?.flags == flags)
        #expect(decoded?.flags.contains(.remoteClosed) == true)
        #expect(decoded?.flags.contains(.noData) == true)
        #expect(decoded?.flags.contains(.remoteOpen) == false)
    }

    @Test("Decode returns nil with insufficient bytes")
    func insufficientBytes() {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00, 0x00, 0x00]) // Only 3 bytes

        let decoded = MessageHeader.decode(from: &buffer)
        #expect(decoded == nil)
    }

    @Test("Big-endian wire format")
    func bigEndianFormat() {
        let header = MessageHeader(
            length: 0x0000_0100, // 256 in big-endian
            streamID: 0x0000_0003, // 3 in big-endian
            messageType: .request,
            flags: []
        )

        var buffer = ByteBuffer()
        header.encode(into: &buffer)

        // Verify raw bytes are big-endian
        let bytes = buffer.readBytes(length: 10)!
        // Length: 0x00 0x00 0x01 0x00
        #expect(bytes[0] == 0x00)
        #expect(bytes[1] == 0x00)
        #expect(bytes[2] == 0x01)
        #expect(bytes[3] == 0x00)
        // StreamID: 0x00 0x00 0x00 0x03
        #expect(bytes[4] == 0x00)
        #expect(bytes[5] == 0x00)
        #expect(bytes[6] == 0x00)
        #expect(bytes[7] == 0x03)
        // Type: request = 0x01
        #expect(bytes[8] == 0x01)
        // Flags: 0x00
        #expect(bytes[9] == 0x00)
    }

    @Test("Maximum data length constant")
    func maxDataLength() {
        #expect(MessageHeader.maxDataLength == 4 * 1024 * 1024) // 4 MB
    }
}

@Suite("MessageType Tests")
struct MessageTypeTests {
    @Test("Raw values match protocol spec")
    func rawValues() {
        #expect(MessageType.request.rawValue == 0x01)
        #expect(MessageType.response.rawValue == 0x02)
        #expect(MessageType.data.rawValue == 0x03)
    }
}

@Suite("MessageFlags Tests")
struct MessageFlagsTests {
    @Test("Raw values match protocol spec")
    func rawValues() {
        #expect(MessageFlags.remoteClosed.rawValue == 0x01)
        #expect(MessageFlags.remoteOpen.rawValue == 0x02)
        #expect(MessageFlags.noData.rawValue == 0x04)
    }

    @Test("OptionSet operations")
    func optionSetOps() {
        let combined: MessageFlags = [.remoteClosed, .noData]
        #expect(combined.rawValue == 0x05)
        #expect(combined.contains(.remoteClosed))
        #expect(combined.contains(.noData))
        #expect(!combined.contains(.remoteOpen))
    }
}
