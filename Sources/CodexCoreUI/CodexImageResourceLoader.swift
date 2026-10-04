import Foundation

/// Chunked downloads share a connection pool and enforce the encoded-byte
/// budget before image decoding. Cache size alone cannot bound response bodies.
final class CodexImageResourceLoader: @unchecked Sendable {
    static let shared = CodexImageResourceLoader()

    enum Failure: Error, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case byteLimitExceeded
    }

    private let delegate: Delegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForResource = 20
        let delegate = Delegate()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw Failure.byteLimitExceeded }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20
        let download = Download(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(session.dataTask(with: request), delegate: delegate, continuation: continuation)
            }
        } onCancel: {
            download.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var downloads: [Int: Download] = [:]

        func register(_ download: Download, task: URLSessionTask) {
            lock.withLock { downloads[task.taskIdentifier] = download }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let download = lock.withLock { downloads[dataTask.taskIdentifier] }
            completionHandler(download?.accept(response) == true ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let download = lock.withLock { downloads[dataTask.taskIdentifier] }
            if download?.append(data) == false { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let download = lock.withLock { downloads.removeValue(forKey: task.taskIdentifier) }
            download?.finish(error: error)
        }
    }

    private final class Download: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var data = Data()
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<Data, Error>?
        private var failure: Error?
        private var cancelled = false

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func start(_ task: URLSessionDataTask, delegate: Delegate,
                   continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                task.cancel()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.task = task
            self.continuation = continuation
            // Registration and resume share the cancellation lock so a cancel
            // before launch cannot race past continuation ownership.
            delegate.register(self, task: task)
            task.resume()
            lock.unlock()
        }

        func cancel() {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
        }

        func accept(_ response: URLResponse) -> Bool {
            lock.withLock {
                guard let response = response as? HTTPURLResponse else {
                    failure = Failure.invalidResponse
                    return false
                }
                guard 200..<300 ~= response.statusCode else {
                    failure = Failure.httpStatus(response.statusCode)
                    return false
                }
                guard response.expectedContentLength <= Int64(maximumBytes) else {
                    failure = Failure.byteLimitExceeded
                    return false
                }
                return !cancelled
            }
        }

        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                guard !cancelled, failure == nil else { return false }
                guard chunk.count <= maximumBytes - data.count else {
                    failure = Failure.byteLimitExceeded
                    return false
                }
                data.append(chunk)
                return true
            }
        }

        func finish(error: Error?) {
            lock.lock()
            guard let continuation else { lock.unlock(); return }
            self.continuation = nil
            task = nil
            let error = failure ?? (cancelled ? CancellationError() : error)
            let result = data
            data = Data()
            lock.unlock()
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: result) }
        }
    }
}
