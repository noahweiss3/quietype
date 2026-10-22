import Foundation

extension Task where Failure == Error {
    /// The task's value, like `value`, except that cancelling the caller ends the wait with
    /// `CancellationError`. Awaiting `value` ignores the waiter's own cancellation, and cancelling
    /// the task itself would take it away from everyone else waiting on it, so the task is left running.
    func join() async throws -> Success {
        let waiter = Waiter<Success>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.wait(continuation)
                Task<Void, Never> { waiter.finish(await result) }
            }
        } onCancel: {
            waiter.cancel()
        }
    }
}

/// Hands one outcome to one continuation: whichever of the task finishing and the caller being
/// cancelled comes first. Either can arrive before the continuation exists.
private final class Waiter<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, Error>)
        case ready(Result<Value, Error>)
        case done
    }

    private let lock = NSLock()
    private var state = State.idle

    func wait(_ continuation: CheckedContinuation<Value, Error>) {
        let ready: Result<Value, Error>? = lock.withLock {
            if case let .ready(result) = state {
                state = .done
                return result
            }
            state = .waiting(continuation)
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func finish(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
            switch state {
            case .idle:
                state = .ready(result)
                return nil
            case let .waiting(continuation):
                state = .done
                return continuation
            case .ready, .done:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}
