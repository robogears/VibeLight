import Foundation

/// Reads a response body with a hard memory cap enforced **as bytes arrive**.
///
/// `URLSession.data(for:)` only resolves once the entire body is already in
/// memory, so a `data.count > cap` check written after it bounds nothing — the
/// damage (holding the bytes) has happened by the time it runs. Worse, a reply
/// sent with `Transfer-Encoding: chunked` declares no length at all, so
/// `expectedContentLength` is -1 and a check on that can never fire either. A
/// host that keeps sending therefore grows the process until it dies: jetsam on
/// iOS, swap pressure on macOS. Request timeouts do not save you — they are
/// *inactivity* timers, reset by every arriving byte.
///
/// The only fix is a delegate that can cancel the transfer mid-flight, which is
/// what this is. Subclass it to add TLS behaviour (client identity, pinning);
/// the cap is inherited. One instance may serve many tasks — all state is
/// per-task.
///
/// `HostAPIClient.MTLSDelegate` implements this same contract inline for the
/// polling/box-art path. It is covered end-to-end by `BoundedResponseTests` and
/// was deliberately left alone rather than re-plumbed through this class:
/// rewriting a proven hot path to remove duplication is a poor trade.
class CappedResponseReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// Thrown when a peer sends (or declares) more than the caller allowed.
    /// A distinct type so callers can map it to their own error vocabulary
    /// instead of it collapsing into a generic "offline".
    struct TooLarge: LocalizedError {
        let bytes: Int
        var errorDescription: String? { "response too large (\(bytes) bytes)" }
    }

    private struct Pending {
        let cap: Int
        var buffer = Data()
        var response: URLResponse?
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
    }

    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]

    /// Runs `request` and returns its body, refusing to hold more than `cap`
    /// bytes. `session` MUST have been built with this object as its delegate,
    /// or none of the callbacks below fire and nothing is capped.
    final func read(_ session: URLSession, _ request: URLRequest,
                    cap: Int) async throws -> (Data, URLResponse) {
        let holder = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                pending[ObjectIdentifier(task)] = Pending(cap: cap, continuation: continuation)
                lock.unlock()
                // resume() BEFORE handing the task to the box. A task cancelled
                // while still suspended is not guaranteed to deliver
                // didCompleteWithError, and that callback is the only thing that
                // resumes the continuation — so cancelling an un-started task
                // could hang this await forever. Registering the continuation
                // first means no callback can arrive before it exists.
                task.resume()
                holder.store(task)
            }
        } onCancel: {
            // Swift-level cancellation must tear the transfer down, not merely
            // stop awaiting it — otherwise it keeps running and keeps filling
            // the buffer we just stopped caring about.
            holder.cancel()
        }
    }

    /// Resumes a task's continuation exactly once and forgets it. Whichever
    /// path gets here first wins; the loser finds no entry and does nothing,
    /// which is what makes the cancel-then-finish sequence below safe.
    private func finish(_ task: URLSessionTask, _ result: Result<(Data, URLResponse), any Error>) {
        lock.lock()
        let entry = pending.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        entry?.continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let id = ObjectIdentifier(dataTask)
        lock.lock()
        let cap = pending[id]?.cap
        pending[id]?.response = response
        // New headers mean a new body: a redirect that carried one would
        // otherwise leave its bytes prepended to the real response.
        pending[id]?.buffer.removeAll(keepingCapacity: true)
        lock.unlock()

        // An honestly-declared oversize dies before a single body byte is read.
        if let cap, response.expectedContentLength > Int64(cap) {
            completionHandler(.cancel)
            finish(dataTask, .failure(TooLarge(bytes: Int(clamping: response.expectedContentLength))))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = ObjectIdentifier(dataTask)
        lock.lock()
        guard let cap = pending[id]?.cap else { lock.unlock(); return }
        // Append through the subscript's modify accessor so the accumulated
        // body is not copied out and back on every chunk.
        pending[id]?.buffer.append(data)
        let total = pending[id]?.buffer.count ?? 0
        lock.unlock()

        // A peer that lied about — or omitted — its length is caught here, one
        // chunk past the cap, rather than after the whole body is resident.
        if total > cap {
            dataTask.cancel()
            finish(dataTask, .failure(TooLarge(bytes: total)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let entry = pending[ObjectIdentifier(task)]
        lock.unlock()
        guard let entry else { return }   // already finished (cap breach)
        if let error {
            finish(task, .failure(error))
        } else if let response = entry.response {
            finish(task, .success((entry.buffer, response)))
        } else {
            finish(task, .failure(URLError(.badServerResponse)))
        }
    }
}

/// Bridges Swift task cancellation to a `URLSessionTask` that may not exist yet
/// at the moment cancellation arrives.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func store(_ task: URLSessionTask) {
        lock.lock()
        let alreadyCancelled = cancelled
        self.task = task
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
