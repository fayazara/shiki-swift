import Foundation

/// Promise.all-style collection: preserve order on success, report the first
/// failure without cancelling independent shared loader tasks.
func orderedLoadResults<Value: Sendable>(_ tasks: [Task<Value, any Error>]) async throws -> [Value] {
    guard !tasks.isEmpty else { return [] }
    return try await withCheckedThrowingContinuation { continuation in
        let collector = OrderedLoadCollector<Value>(count: tasks.count, continuation: continuation)
        for (index, task) in tasks.enumerated() {
            Task {
                do { await collector.finish(index: index, result: .success(try await task.value)) }
                catch { await collector.finish(index: index, result: .failure(error)) }
            }
        }
    }
}

private actor OrderedLoadCollector<Value: Sendable> {
    private var values: [Value?]
    private var remaining: Int
    private var continuation: CheckedContinuation<[Value], any Error>?
    init(count: Int, continuation: CheckedContinuation<[Value], any Error>) {
        values = Array(repeating: nil, count: count); remaining = count; self.continuation = continuation
    }
    func finish(index: Int, result: Result<Value, any Error>) {
        guard let continuation else { return }
        switch result {
        case .success(let value):
            values[index] = value; remaining -= 1
            if remaining == 0 {
                self.continuation = nil
                continuation.resume(returning: values.map { $0! })
                values.removeAll()
            }
        case .failure(let error):
            self.continuation = nil; values.removeAll()
            continuation.resume(throwing: error)
        }
    }
}
