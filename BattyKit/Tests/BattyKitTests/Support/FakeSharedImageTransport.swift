// FakeSharedImageTransport.swift

import Foundation
import Testing
@testable import BattyKit

/// Scripted per digest, recording every call. Nothing reaches iCloud Drive. A
/// read can be held on a gate the test opens, so slowness is a signal and never
/// a wait.
nonisolated final class FakeSharedImageTransport: SharedImageTransport, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case availability, list
        case state(String), requestDownload(String), read(String), write(String)
        case uploadProblem(String), isUploaded(String), delete(String)
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _availability = SharedImageAvailability.available
    private var _files: [String: Data] = [:]
    private var _evicted = Set<String>()
    private var _readError: Error?
    private var _writeError: Error?
    private var _downloadError: Error?
    private var _uploadProblem: SharedImageUploadProblem?
    private var _isUploaded = true
    private var _heldReads: [CheckedContinuation<Void, Never>] = []
    private var _holdReads = false
    private var _readWaiters: [UUID: ResumeOnce<Bool>] = [:]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: [Call] { locked { _calls } }
    func resetCalls() { locked { _calls = [] } }
    func count(_ call: Call) -> Int { locked { _calls.filter { $0 == call }.count } }
    var writes: [Call] { locked { _calls.filter { if case .write = $0 { return true } else { return false } } } }
    var deletes: [Call] { locked { _calls.filter { if case .delete = $0 { return true } else { return false } } } }

    func setAvailability(_ value: SharedImageAvailability) { locked { _availability = value } }
    func put(_ data: Data, digest: String, evicted: Bool = false) {
        locked {
            _files[digest] = data
            if evicted { _evicted.insert(digest) } else { _evicted.remove(digest) }
        }
    }
    func removeFile(digest: String) { locked { _files[digest] = nil } }
    func hasFile(digest: String) -> Bool { locked { _files[digest] != nil } }
    func setReadError(_ error: Error?) { locked { _readError = error } }
    func setWriteError(_ error: Error?) { locked { _writeError = error } }
    func setDownloadError(_ error: Error?) { locked { _downloadError = error } }
    func setUploadProblem(_ value: SharedImageUploadProblem?) { locked { _uploadProblem = value } }
    func setIsUploaded(_ value: Bool) { locked { _isUploaded = value } }

    func holdReads() { locked { _holdReads = true } }

    func releaseReads() {
        let held = locked {
            _holdReads = false
            defer { _heldReads = [] }
            return _heldReads
        }
        for continuation in held { continuation.resume() }
    }

    /// True once a read is suspended on the gate. False only if none came
    /// within `bound`, which is a failure guard and never the success path.
    func waitForHeldRead(bound: TimeInterval = TestBounds.hangGuard) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let id = UUID()
            let timeout = DispatchWorkItem { [weak self] in
                self?.locked { self?._readWaiters[id] = nil }
                once.resume(false)
            }
            once.setOnResumed { timeout.cancel() }
            let ready = locked {
                if !_heldReads.isEmpty { return true }
                _readWaiters[id] = once
                return false
            }
            if ready {
                once.resume(true)
            } else {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeout)
            }
        }
    }

    func availability() async -> SharedImageAvailability {
        locked {
            _calls.append(.availability)
            return _availability
        }
    }

    func state(digest: String) async throws -> SharedImageFileState {
        locked {
            _calls.append(.state(digest))
            if _files[digest] == nil { return .absent }
            return _evicted.contains(digest) ? .notDownloaded : .local
        }
    }

    func requestDownload(digest: String) async throws {
        let error: Error? = locked {
            _calls.append(.requestDownload(digest))
            return _downloadError
        }
        if let error { throw error }
    }

    func read(digest: String) async throws -> Data {
        let shouldHold = locked {
            _calls.append(.read(digest))
            return _holdReads
        }
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waiters = locked {
                    _heldReads.append(continuation)
                    defer { _readWaiters = [:] }
                    return _readWaiters
                }
                for waiter in waiters.values { waiter.resume(true) }
            }
        }
        let result: Result<Data, Error> = locked {
            if let _readError { return .failure(_readError) }
            guard let data = _files[digest] else { return .failure(Failure()) }
            return .success(data)
        }
        return try result.get()
    }

    func write(from source: URL, digest: String) async throws {
        let error: Error? = locked {
            _calls.append(.write(digest))
            return _writeError
        }
        if let error { throw error }
        let data = try Data(contentsOf: source)
        locked { _files[digest] = data }
    }

    func uploadProblem(digest: String) async -> SharedImageUploadProblem? {
        locked {
            _calls.append(.uploadProblem(digest))
            return _uploadProblem
        }
    }

    func isUploaded(digest: String) async -> Bool {
        locked {
            _calls.append(.isUploaded(digest))
            return _isUploaded
        }
    }

    func listDigests() async throws -> [String] {
        locked {
            _calls.append(.list)
            return Array(_files.keys)
        }
    }

    func delete(digest: String) async throws {
        locked {
            _calls.append(.delete(digest))
            _files[digest] = nil
        }
    }
}

/// An `AppStateStore` over temporary folders with the fake transport, a fake
/// backend and a clock only the test advances.
@MainActor
final class SharedImageWorld {
    let fixture: ProjectBackgroundFixture
    let fake = FakeSharedImageTransport()
    let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
    let appStore: AppStateStore

    static let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }

    init() throws {
        let fixture = try ProjectBackgroundFixture()
        self.fixture = fixture
        appStore = fixture.appStore()
        let fake = fake
        let backend = backend
        appStore.sharedImageTransportFactory = { _ in fake }
        appStore.projectSyncBackendFactory = { backend }
        appStore.sharedImageClock = clock
        appStore.sharedImageNotificationCenter = fixture.notificationCenter
    }

    var store: ProjectStore { appStore.projectStore }
    var images: SharedProjectImages { appStore.sharedProjectImages! }

    func pass(userInitiated: Bool = true) async {
        await images.reconcile(userInitiated: userInitiated).value
    }

    func project(name: String = "Harbor Project", path: String?, shared: Bool = true, sharedImage: ProjectSharedImage? = nil) -> Project {
        var project = fixture.project(name: name, background: projectBackgroundValue(path: path))
        project.isShared = shared
        project.sharedImage = sharedImage
        return project
    }

    /// As if another Mac published this image: reaches the store through a
    /// merge, which isn't a user action.
    func receive(digest: String, name: String = "Harbor", id: UUID = UUID()) -> UUID {
        var record = Project(id: id, name: "From Other Mac", rootPath: fixture.root.path, isShared: true, background: projectBackgroundValue(path: nil))
            .syncRecord(home: NSHomeDirectory())
        record.modifiedAt = Date(timeIntervalSinceNow: 1_000)
        record.background = ProjectSyncBackground(projectBackgroundValue(path: nil), image: .named(digest: digest, name: name))
        var entries = backend.snapshot()
        entries[id] = .record(record)
        backend.receive(entries)
        store.mergeRemote()
        return id
    }

    func imageBytes(width: Int = 48) throws -> (data: Data, digest: String) {
        let data = try BackgroundTestImage.encoded(width: width)
        return (data, BackgroundTestImage.digest(of: data))
    }

    func hasNoImageKeys() -> Bool {
        backend.snapshot().values.allSatisfy { entry in
            guard case .record(let record) = entry else { return true }
            return (record.background?.image ?? .unspecified) == .unspecified
        }
    }
}
