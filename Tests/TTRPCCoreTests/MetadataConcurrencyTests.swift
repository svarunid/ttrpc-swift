import Testing
import Foundation
@testable import TTRPCCore

// MARK: - Concurrent Metadata Tests (mirrors Go: TestMetadataCloneConcurrent)

@Suite("Metadata Concurrency Tests")
struct MetadataConcurrencyTests {

    @Test("Concurrent metadata access is safe")
    func concurrentAccess() async throws {
        // Create base metadata (let -- value type, each task gets its own copy)
        let base = TTRPCMetadata([("key1", "value1"), ("key2", "value2")])

        // 20 concurrent tasks reading and modifying copies (value-type semantics)
        let iterations = 20
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<iterations {
                let snapshot = base // capture a copy per iteration
                group.addTask {
                    var copy = snapshot
                    copy.append("key1", value: "extra-\(i)")
                    copy.set("new-\(i)", values: ["val-\(i)"])

                    let vals = copy.get("key1")
                    return vals?.contains("extra-\(i)") == true
                }
            }

            var allPassed = true
            for await result in group {
                if !result { allPassed = false }
            }
            #expect(allPassed)
        }

        // Original should be untouched (value semantics)
        #expect(base.get("key1") == ["value1"])
        #expect(base.get("key2") == ["value2"])
    }

    @Test("Metadata value semantics are correct")
    func valueSemantics() {
        var original = TTRPCMetadata()
        original.set("key", values: ["v1"])

        // Copy and modify
        var copy = original
        copy.append("key", value: "v2")

        // Original unchanged
        #expect(original.get("key") == ["v1"])
        #expect(copy.get("key") == ["v1", "v2"])
    }
}
