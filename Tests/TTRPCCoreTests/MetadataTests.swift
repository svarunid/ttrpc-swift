import Testing
@testable import TTRPCCore

@Suite("TTRPCMetadata Tests")
struct MetadataTests {

    @Test("Empty metadata")
    func empty() {
        let md = TTRPCMetadata()
        #expect(md.isEmpty)
        #expect(md.get("key") == nil)
        #expect(md.first("key") == nil)
    }

    @Test("Set and get values")
    func setAndGet() {
        var md = TTRPCMetadata()
        md.set("key", values: ["value1", "value2"])
        #expect(md.get("key") == ["value1", "value2"])
        #expect(md.first("key") == "value1")
        #expect(!md.isEmpty)
    }

    @Test("Case-insensitive keys")
    func caseInsensitive() {
        var md = TTRPCMetadata()
        md.set("Content-Type", values: ["application/protobuf"])
        #expect(md.get("content-type") == ["application/protobuf"])
        #expect(md.get("CONTENT-TYPE") == ["application/protobuf"])
    }

    @Test("Append values")
    func append() {
        var md = TTRPCMetadata()
        md.append("key", value: "v1")
        md.append("key", value: "v2")
        #expect(md.get("key") == ["v1", "v2"])
    }

    @Test("Set with empty values removes key")
    func removeKey() {
        var md = TTRPCMetadata()
        md.set("key", values: ["value"])
        md.set("key", values: [])
        #expect(md.get("key") == nil)
        #expect(md.isEmpty)
    }

    @Test("Init from pairs")
    func initFromPairs() {
        let md = TTRPCMetadata([
            ("key1", "v1"),
            ("key1", "v2"),
            ("key2", "v3"),
        ])
        #expect(md.get("key1") == ["v1", "v2"])
        #expect(md.get("key2") == ["v3"])
    }

    @Test("Pairs iteration")
    func pairsIteration() {
        var md = TTRPCMetadata()
        md.append("a", value: "1")
        md.append("b", value: "2")

        let pairs = md.pairs
        #expect(pairs.count == 2)
        #expect(pairs.contains(where: { $0.key == "a" && $0.value == "1" }))
        #expect(pairs.contains(where: { $0.key == "b" && $0.value == "2" }))
    }
}
