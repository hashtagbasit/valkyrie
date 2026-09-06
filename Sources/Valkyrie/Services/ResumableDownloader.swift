import Foundation

/// Streams a large file to disk with progress and resume.
///
/// Firmware archives run to tens of gigabytes, so the bytes are appended to a file
/// handle as they arrive rather than buffered in memory, and an interrupted transfer
/// resumes with a Range header from whatever is already on disk.
final class ResumableDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private let onProgress: (Int64, Int64, Double) -> Void
    private var failure: Error?
    private var expectedStart: Int64 = 0

    init(onProgress: @escaping (Int64, Int64, Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func download(request: URLRequest, to destination: URL, existing: Int64, total: Int64) async throws {
        self.total = total
        self.received = existing
        self.expectedStart = existing
        self.failure = nil

        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        try handle.seekToEnd()
        self.handle = handle

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        windowStart = Date()
        windowBytes = 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    /// Validates the response before a single byte reaches the file.
    ///
    /// Two things must not happen: an error body (Samsung answers an expired session
    /// with a short JSON payload) being appended as if it were firmware, and a server
    /// that ignores the Range header sending the whole file to be spliced onto bytes
    /// already on disk. Both corrupt the archive silently.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }

        // A resumed request must come back as 206. A 200 means the Range was ignored,
        // so whatever is already on disk has to go.
        if expectedStart > 0 && http.statusCode == 200 {
            try? handle?.truncate(atOffset: 0)
            try? handle?.seek(toOffset: 0)
            received = 0
            expectedStart = 0
            onProgress(0, total, 0)
            completionHandler(.allow)
            return
        }

        guard (200...299).contains(http.statusCode) else {
            failure = FusError.server(status: "\(http.statusCode)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handle?.write(data)
        received += Int64(data.count)
        windowBytes += Int64(data.count)

        // Report at most a few times a second; the UI can't use more than that.
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 0.4 {
            let rate = Double(windowBytes) / elapsed
            onProgress(received, total, rate)
            windowStart = Date()
            windowBytes = 0
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        onProgress(received, total, 0)

        let continuation = self.continuation
        self.continuation = nil
        session.finishTasksAndInvalidate()

        // A rejected response surfaces here as a cancellation, so the recorded
        // failure takes precedence over the generic cancel error.
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error, (error as NSError).code == NSURLErrorCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            continuation?.resume(throwing: FusError.transport(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }
}
