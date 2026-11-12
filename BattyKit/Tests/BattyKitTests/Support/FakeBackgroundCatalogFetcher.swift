// FakeBackgroundCatalogFetcher.swift

import Foundation
@testable import BattyKit

/// Scripted per URL, recording every request. Nothing reaches the network. A
/// URL can be held until the test releases it, so a slow fetch is an event the
/// test controls and never a wait.
nonisolated final class FakeBackgroundCatalogFetcher: BackgroundCatalogFetching, @unchecked Sendable {
    enum Reply: Sendable {
        case ok(Data, etag: String? = nil, lastModified: String? = nil)
        case notModified
        case failure(HostedFetchError)
    }

    private let lock = NSLock()
    private var _replies: [URL: Reply] = [:]
    private var _requests: [HostedFetchRequest] = []
    private var _held: Set<URL> = []
    private var _parked: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var _requestWaiters: [(count: Int, once: ResumeOnce<Bool>)] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var requests: [HostedFetchRequest] { locked { _requests } }
    var requestedURLs: [URL] { requests.map(\.url) }
    func count(_ url: URL) -> Int { requestedURLs.filter { $0 == url }.count }

    func set(_ reply: Reply, for url: URL) { locked { _replies[url] = reply } }
    func hold(_ url: URL) { locked { _ = _held.insert(url) } }

    func release(_ url: URL) {
        let parked = locked {
            _held.remove(url)
            return _parked.removeValue(forKey: url) ?? []
        }
        for continuation in parked { continuation.resume() }
    }

    /// True once `count` requests have arrived in total. False only if they
    /// didn't within `bound`, which is a failure guard.
    func waitForRequests(_ count: Int, bound: TimeInterval = TestBounds.hangGuard) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timeout = DispatchWorkItem { once.resume(false) }
            once.setOnResumed { timeout.cancel() }
            let ready = locked {
                if _requests.count >= count { return true }
                _requestWaiters.append((count, once))
                return false
            }
            if ready {
                once.resume(true)
            } else {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeout)
            }
        }
    }

    func fetch(
        _ request: HostedFetchRequest,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws(HostedFetchError) -> HostedFetchResponse {
        let (ready, shouldHold): ([ResumeOnce<Bool>], Bool) = locked {
            _requests.append(request)
            let total = _requests.count
            let ready = _requestWaiters.filter { $0.count <= total }.map(\.once)
            _requestWaiters.removeAll { $0.count <= total }
            return (ready, _held.contains(request.url))
        }
        for once in ready { once.resume(true) }
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = locked {
                    guard _held.contains(request.url) else { return true }
                    _parked[request.url, default: []].append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if Task.isCancelled { throw .cancelled }
        let reply = locked { _replies[request.url] } ?? .failure(.notFound)
        switch reply {
        case .failure(let error):
            throw error
        case .notModified:
            return HostedFetchResponse(status: 304, body: nil, etag: nil, lastModified: nil, expectedLength: nil)
        case .ok(let data, let etag, let lastModified):
            guard Int64(data.count) <= request.byteLimit else { throw .tooLarge }
            progress?(Int64(data.count))
            if case .file(let url) = request.destination {
                do { try data.write(to: url) } catch { throw .unreachable }
                return HostedFetchResponse(status: 200, body: nil, etag: etag, lastModified: lastModified, expectedLength: Int64(data.count))
            }
            return HostedFetchResponse(status: 200, body: data, etag: etag, lastModified: lastModified, expectedLength: Int64(data.count))
        }
    }
}
