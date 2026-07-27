import Foundation

/// Thread-safe wrapper around CheckedContinuation that guarantees resume is called at most once.
/// Used by both ADB and MTP device implementations for bridging callback-based APIs to async/await.
nonisolated final class ContinuationBox<T, E: Error>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, E>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, E>) {
        self.continuation = continuation
    }

    /// Resume with a value. Only the first call takes effect; subsequent calls are silently ignored.
    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    /// Resume with an error. Only the first call takes effect; subsequent calls are silently ignored.
    func resume(throwing error: E) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
