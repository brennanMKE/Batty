// URLSessionBackgroundCatalogFetcher.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "URLSessionBackgroundCatalogFetcher")

/// `@unchecked` because every mutable field is behind `lock`.
nonisolated final class URLSessionBackgroundCatalogFetcher: NSObject, BackgroundCatalogFetching, URLSessionDataDelegate, @unchecked Sendable {
    static let builtInHost = "batty.sstools.co"

    private final class Transfer {
        let request: HostedFetchRequest
        let progress: (@Sendable (Int64) -> Void)?
        let continuation: CheckedContinuation<HostedFetchResponse, Error>
        var counter: ByteLimitCounter
        var body = Data()
        var handle: FileHandle?
        var redirects = 0
        var failure: HostedFetchError?
        var response: HTTPURLResponse?

        init(request: HostedFetchRequest, progress: (@Sendable (Int64) -> Void)?, continuation: CheckedContinuation<HostedFetchResponse, Error>) {
            self.request = request
            self.progress = progress
            self.continuation = continuation
            self.counter = ByteLimitCounter(limit: request.byteLimit)
        }
    }

    private let lock = NSLock()
    private let protocolClasses: [AnyClass]
    nonisolated(unsafe) private var transfers: [Int: Transfer] = [:]
    nonisolated(unsafe) private var _session: URLSession?

    /// `protocolClasses` is a test seam for a stub `URLProtocol`; production passes none.
    init(protocolClasses: [AnyClass] = []) {
        self.protocolClasses = protocolClasses
        super.init()
    }

    /// Call with `lock` held.
    private var session: URLSession {
        if let _session { return _session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        let made = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        _session = made
        return made
    }

    func fetch(
        _ request: HostedFetchRequest,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws(HostedFetchError) -> HostedFetchResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = request.timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = request.etag { urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = request.lastModified { urlRequest.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let task = lock.withLock { session.dataTask(with: urlRequest) }
        let identifier = task.taskIdentifier
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let transfer = Transfer(request: request, progress: progress, continuation: continuation)
                    lock.withLock { transfers[identifier] = transfer }
                    if Task.isCancelled { task.cancel() }
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch let error as HostedFetchError {
            throw error
        } catch {
            throw .unreachable
        }
    }

    private func transfer(_ task: URLSessionTask) -> Transfer? {
        lock.withLock { transfers[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let transfer = transfer(task) else { return completionHandler(nil) }
        let refusal: HostedFetchError? = lock.withLock {
            transfer.redirects += 1
            let refusal = HostedFetchPolicy.allowsRedirect(to: request.url, count: transfer.redirects)
            if let refusal { transfer.failure = refusal }
            return refusal
        }
        if refusal != nil {
            completionHandler(nil)
            task.cancel()
        } else {
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(dataTask), let http = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        let disposition: URLSession.ResponseDisposition = lock.withLock {
            transfer.response = http
            if transfer.failure != nil { return .cancel }
            if let failure = HostedFetchPolicy.error(forStatus: http.statusCode) {
                transfer.failure = failure
                return .cancel
            }
            let expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            if http.statusCode == 200, !transfer.counter.accepts(expectedLength: expected) {
                transfer.failure = .tooLarge
                return .cancel
            }
            if http.statusCode == 200, case .file(let url) = transfer.request.destination {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    transfer.failure = .unreachable
                    return .cancel
                }
                transfer.handle = handle
            }
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(dataTask) else { return }
        let received: Int64? = lock.withLock {
            guard transfer.counter.add(data.count) else {
                transfer.failure = .tooLarge
                return nil
            }
            if let handle = transfer.handle {
                do { try handle.write(contentsOf: data) } catch {
                    transfer.failure = .unreachable
                    return nil
                }
            } else {
                transfer.body.append(data)
            }
            return transfer.counter.received
        }
        if let received {
            transfer.progress?(received)
        } else {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transfer: Transfer? = lock.withLock { transfers.removeValue(forKey: task.taskIdentifier) }
        guard let transfer else { return }
        try? transfer.handle?.close()
        let url = transfer.request.url
        if transfer.failure != nil || error != nil, case .file(let destination) = transfer.request.destination {
            try? FileManager.default.removeItem(at: destination)
        }
        if let failure = transfer.failure {
            log(failure, url: url)
            return transfer.continuation.resume(throwing: failure)
        }
        if let error {
            let mapped = (error as? URLError).map(HostedFetchPolicy.error(for:)) ?? .unreachable
            log(mapped, url: url)
            return transfer.continuation.resume(throwing: mapped)
        }
        guard let http = transfer.response else { return transfer.continuation.resume(throwing: HostedFetchError.unreachable) }
        let isFile: Bool = if case .file = transfer.request.destination { true } else { false }
        let expected = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        transfer.continuation.resume(returning: HostedFetchResponse(
            status: http.statusCode,
            body: http.statusCode == 200 && !isFile ? transfer.body : nil,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            expectedLength: expected
        ))
    }

    private func log(_ error: HostedFetchError, url: URL) {
        if url.host == Self.builtInHost {
            logger.error("fetch failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            logger.error("fetch failed for \(url.absoluteString, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }
}
