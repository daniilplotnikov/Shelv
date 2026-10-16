import Foundation

nonisolated enum TaskRace {
    /// The task's value, or nil once `timeout` has passed. Unlike a task group this
    /// does not wait for the slow task after the timeout won, and the task itself
    /// keeps running so a late result can still be picked up from it.
    static func value<T: Sendable>(of task: Task<T?, Never>, timeout: Duration) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = OnceResume(continuation)
            Task { once.resume(with: await task.value) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(with: nil)
            }
        }
    }
}

/// Resumes a continuation at most once, for racing two tasks against each other.
private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
