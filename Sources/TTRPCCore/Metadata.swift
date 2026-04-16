/// Metadata carried alongside ttrpc requests as key-value pairs.
///
/// Keys are treated case-insensitively. Each key can have multiple values.
/// Metadata is serialized as repeated `KeyValue` pairs in the protocol
/// `Request` message and propagated via `@TaskLocal` in Swift Concurrency.
public struct TTRPCMetadata: Sendable, Hashable {
    private var storage: [String: [String]]

    public init() {
        self.storage = [:]
    }

    public init(_ pairs: [(String, String)]) {
        self.storage = [:]
        for (key, value) in pairs {
            append(key, value: value)
        }
    }

    /// Get all values for a key (case-insensitive).
    public func get(_ key: String) -> [String]? {
        storage[key.lowercased()]
    }

    /// Get the first value for a key (case-insensitive).
    public func first(_ key: String) -> String? {
        storage[key.lowercased()]?.first
    }

    /// Set the values for a key, replacing any existing values.
    public mutating func set(_ key: String, values: [String]) {
        if values.isEmpty {
            storage.removeValue(forKey: key.lowercased())
        } else {
            storage[key.lowercased()] = values
        }
    }

    /// Append a value to the given key.
    public mutating func append(_ key: String, value: String) {
        storage[key.lowercased(), default: []].append(value)
    }

    /// All key-value pairs, with keys lowercased.
    public var pairs: [(key: String, value: String)] {
        storage.flatMap { key, values in
            values.map { (key: key, value: $0) }
        }
    }

    /// Whether the metadata is empty.
    public var isEmpty: Bool {
        storage.isEmpty
    }

    @TaskLocal public static var current = TTRPCMetadata()
}
