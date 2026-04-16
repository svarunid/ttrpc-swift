import Foundation
import SwiftProtobuf

/// Codec for marshaling/unmarshaling protobuf messages used by the ttrpc protocol.
public struct TTRPCProtobufCodec: Sendable {
    public init() {}

    /// Serialize a protobuf message to bytes.
    public func marshal<M: SwiftProtobuf.Message>(_ message: M) throws -> Data {
        try message.serializedData()
    }

    /// Deserialize a protobuf message from bytes.
    public func unmarshal<M: SwiftProtobuf.Message>(_ data: Data, as type: M.Type = M.self) throws -> M {
        try M(serializedBytes: data)
    }
}
