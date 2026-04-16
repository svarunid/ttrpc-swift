import Foundation

/// Wait for a Unix domain socket to appear, polling every 5ms.
/// Much faster than a fixed 100ms sleep.
func waitForSocket(_ path: String, timeout: Duration = .seconds(2)) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if FileManager.default.fileExists(atPath: path) {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestError.socketTimeout(path)
}

enum TestError: Error {
    case socketTimeout(String)
}
