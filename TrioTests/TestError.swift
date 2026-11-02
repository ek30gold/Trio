import Foundation
import Swinject
@testable import Trio

// Custom error type for test failures
struct TestError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Builds a full `TrioApp` for suites that resolve real services. Construction is serialized:
/// `TrioApp.init` sets up shared stores (app and device logs, pump status) that are not safe to
/// initialize concurrently, and suites running in parallel corrupted the heap in CI when several
/// built one at the same moment. Each caller still gets its own app.
enum TestApp {
    private static let lock = NSLock()

    static func makeResolver() -> Resolver {
        lock.lock()
        defer { lock.unlock() }
        return TrioApp().resolver
    }
}
