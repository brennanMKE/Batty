// SharedProjectImages.swift

import AppKit
import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SharedProjectImages")

nonisolated enum SharedImageStatus: Sendable, Equatable {
    case inICloudDrive
    case waitingToUpload
}

/// Copies Shared Projects' images through the transport. Its work list comes
/// only from Shared Projects whose `sharedImage` names an image, which is the
/// whole scope rule: a library, Pane, Session, app-wide or local-Project image
/// never reaches it, and a pass with no such Project makes no transport call.
///
/// A failure never costs the Project: file work starts after the local commit,
/// and a failure only sets `message`. Writes to observed state follow an
/// `await`, never `body` or layout, and happen only on change.
@MainActor
@Observable
final class SharedProjectImages {
    static let folderWasReachedKey = "SharedProjectImages.folderWasReached"
    nonisolated static let initialRetryDelay = 30
    nonisolated static let maximumRetryDelay = 15 * 60
    private static let uploadPatience: TimeInterval = 60 * 60

    private(set) var message: String?
    /// For digests of Shared Projects only.
    private(set) var sharedStatus: [String: SharedImageStatus] = [:]

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let transport: any SharedImageTransport
    @ObservationIgnored private let clock: any SchedulingClock
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let ledgerURL: URL?
    /// Puts an arrived image on open Sessions and an open Project Editor.
    @ObservationIgnored var onArrival: (@MainActor (_ project: Project, _ path: String) -> Void)?
    /// A Tab's custom image arrived; `AppStateStore` applies it.
    @ObservationIgnored var onTabArrival: (@MainActor (_ projectID: UUID, _ image: ProjectTabImage, _ path: String) -> Void)?
    /// Where a digest only Tabs name is stored, and what it must not evict.
    @ObservationIgnored var tabImageCache: @MainActor () -> DownloadedImageCache? = { nil }
    @ObservationIgnored var pinnedTabDigests: @MainActor () -> Set<String> = { [] }
    @ObservationIgnored var onTabEviction: (@MainActor ([String]) -> Void)?
    /// Tab digests the user asked for by opening a Project or showing it in the
    /// editor. A pass downloads no other Tab digest.
    @ObservationIgnored private(set) var requestedTabDigests = Set<String>()

    @ObservationIgnored private var lastPass: Task<Void, Never>?
    @ObservationIgnored private(set) var retryTask: Task<Void, Never>?
    @ObservationIgnored private var requestedDownloads = Set<String>()
    @ObservationIgnored private var failedDownloads = Set<String>()
    @ObservationIgnored private var uploadWaitStarted: [String: Date] = [:]
    @ObservationIgnored private var hasSwept = false
    @ObservationIgnored private nonisolated(unsafe) var activeObserver: NSObjectProtocol?

    init(
        store: ProjectStore,
        directory: URL,
        transport: any SharedImageTransport,
        clock: any SchedulingClock = SystemClock(),
        defaults: UserDefaults,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.directory = directory
        self.transport = transport
        self.clock = clock
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.ledgerURL = store.url?.deletingLastPathComponent().appendingPathComponent(SharedImageSweep.ledgerFileName)
        store.onSharedImagesChanged = { [weak self] userInitiated in
            self?.reconcile(userInitiated: userInitiated)
        }
        activeObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.reconcile(userInitiated: false) }
        }
    }

    deinit {
        if let activeObserver { notificationCenter.removeObserver(activeObserver) }
    }

    private var folderWasReached: Bool { defaults.bool(forKey: Self.folderWasReachedKey) }

    /// Passes run one at a time, in order. The first access to the folder may
    /// prompt, so a pass that isn't from a user action does nothing until one
    /// has reached it. Await the returned task in a test.
    @discardableResult
    func reconcile(userInitiated: Bool) -> Task<Void, Never> {
        let previous = lastPass
        let pass = Task { [weak self] in
            await previous?.value
            await self?.runPass(userInitiated: userInitiated)
        }
        lastPass = pass
        return pass
    }

    private struct WorkItem {
        enum Kind { case project, tab }

        let id: UUID
        let digest: String
        let name: String
        let path: String?
        var kind: Kind = .project

        var pathMatches: Bool {
            path.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) == digest
        }
    }

    private var workList: [WorkItem] {
        store.projects.flatMap { project -> [WorkItem] in
            guard project.isShared else { return [] }
            var items: [WorkItem] = []
            if case .named(let digest, let name)? = project.sharedImage {
                items.append(WorkItem(id: project.id, digest: digest, name: name, path: project.background?.imagePath))
            }
            var seen = Set<String>()
            let tabs = project.layout.panes.flatMap(\.tabs)
            for tab in tabs {
                guard case .custom(let digest, let name)? = tab.image, seen.insert(digest).inserted else { continue }
                let path = tabs.first { $0.image?.digest == digest && $0.background?.imagePath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) == digest }?.background?.imagePath
                    ?? tab.background?.imagePath
                items.append(WorkItem(id: project.id, digest: digest, name: name, path: path, kind: .tab))
            }
            return items
        }
    }

    /// Opening the Project or showing it in the editor is the user action that
    /// may reach the folder.
    @discardableResult
    func requestTabImage(digest: String, name: String, projectID: UUID) -> Task<Void, Never> {
        requestedTabDigests.insert(digest)
        return reconcile(userInitiated: true)
    }

    /// A Project-level item, or a Tab item someone asked for.
    private func wantsDownload(_ item: WorkItem) -> Bool {
        !item.pathMatches && (item.kind == .project || requestedTabDigests.contains(item.digest))
    }

    private func runPass(userInitiated: Bool) async {
        let initial = workList
        setStatus(sharedStatus.filter { key, _ in initial.contains { $0.digest == key } })
        // A digest no Project waits for any more asks again if it's named again.
        let waitingNow = Set(initial.filter { !$0.pathMatches }.map(\.digest))
        requestedDownloads.formIntersection(waitingNow)
        failedDownloads.formIntersection(waitingNow)
        requestedTabDigests.formIntersection(waitingNow)
        guard !initial.isEmpty else {
            setMessage(nil)
            updateRetry(waiting: false)
            return
        }

        // A copy this Mac already holds needs no transport, so it runs ahead of
        // the user-action gate.
        for digest in Set(initial.filter(wantsDownload).map(\.digest)).sorted() {
            let directory = directory
            let held = await Task.detached { TerminalBackgroundImageImporter.existingCopy(digest: digest, in: directory) }.value
            if let held { applyArrival(digest: digest, path: held) }
        }

        let work = workList
        let waitingForDownload = Set(work.filter(wantsDownload).map(\.digest)).sorted()
        var uploads: [String: String] = [:]
        for item in work where item.pathMatches {
            if let path = item.path, uploads[item.digest] == nil { uploads[item.digest] = path }
        }
        setStatus(sharedStatus.filter { key, _ in uploads[key] != nil })
        guard !waitingForDownload.isEmpty || !uploads.isEmpty else {
            setMessage(nil)
            updateRetry(waiting: false)
            return
        }

        guard userInitiated || folderWasReached else { return }

        switch await transport.availability() {
        case .off:
            finish(message: String(localized: "Turn on iCloud Drive to send this Project's image to your other Macs. The rest of the Project still syncs.", comment: "Shared Project images: iCloud Drive is off"), waiting: true)
            return
        case .notAllowed:
            finish(message: Self.notAllowedMessage, waiting: true)
            return
        case .available:
            if !folderWasReached { defaults.set(true, forKey: Self.folderWasReachedKey) }
        }

        var outcome = PassOutcome()
        for (digest, path) in uploads.sorted(by: { $0.key < $1.key }) {
            await upload(digest: digest, path: path, outcome: &outcome)
        }
        for digest in waitingForDownload {
            await download(digest: digest, outcome: &outcome)
        }
        finish(message: outcome.message, waiting: outcome.waiting)
    }

    private struct PassOutcome {
        var message: String?
        var waiting = false
    }

    private static var notAllowedMessage: String {
        String(localized: "Allow Batty to use iCloud Drive in System Settings > Privacy & Security > Files and Folders. The rest of the Project still syncs.", comment: "Shared Project images: macOS denied access to iCloud Drive")
    }

    private func finish(message: String?, waiting: Bool) {
        setMessage(message)
        updateRetry(waiting: waiting)
    }

    // MARK: - Upload

    private func upload(digest: String, path: String, outcome: inout PassOutcome) async {
        do {
            switch try await transport.state(digest: digest) {
            case .notDownloaded:
                // Can't be read without a download, and its name is its digest.
                setStatus(digest, .inICloudDrive)
                uploadWaitStarted[digest] = nil
                return
            case .local:
                let bytes = try await transport.read(digest: digest)
                let matches = await Task.detached { TerminalBackgroundImageImporter.hexDigest(of: bytes) == digest }.value
                if !matches { try await writeLocalCopy(path: path, digest: digest) }
            case .absent:
                try await writeLocalCopy(path: path, digest: digest)
            }
        } catch SharedImageTransportError.notAllowed {
            setStatus(digest, .waitingToUpload)
            outcome.message = Self.notAllowedMessage
            outcome.waiting = true
            return
        } catch LocalCopyUnusable.instance {
            logger.error("not uploading a shared background image: the local copy failed its check")
            setStatus(digest, nil)
            return
        } catch {
            logger.error("shared background image upload failed: \(error.localizedDescription, privacy: .public)")
            setStatus(digest, .waitingToUpload)
            outcome.waiting = true
            noteUploadWait(digest: digest, outcome: &outcome)
            return
        }
        if let problem = await transport.uploadProblem(digest: digest) {
            setStatus(digest, .waitingToUpload)
            outcome.waiting = true
            if problem == .iCloudFull {
                outcome.message = String(localized: "iCloud is full, so this Project's image can't reach your other Macs. The rest of the Project still syncs.", comment: "Shared Project images: the iCloud account is out of space")
            } else {
                noteUploadWait(digest: digest, outcome: &outcome)
            }
            return
        }
        if await transport.isUploaded(digest: digest) {
            setStatus(digest, .inICloudDrive)
            uploadWaitStarted[digest] = nil
        } else {
            setStatus(digest, .waitingToUpload)
            outcome.waiting = true
            noteUploadWait(digest: digest, outcome: &outcome)
        }
    }

    private enum LocalCopyUnusable: Error { case instance }

    private func writeLocalCopy(path: String, digest: String) async throws {
        let directory = directory
        let usable = await Task.detached {
            TerminalBackgroundImageImporter.inspect(path: path, directory: directory) == .usable
                && TerminalBackgroundImageImporter.isWithinPixelLimit(path: path)
        }.value
        guard usable else { throw LocalCopyUnusable.instance }
        try await transport.write(from: URL(fileURLWithPath: path), digest: digest)
    }

    private func noteUploadWait(digest: String, outcome: inout PassOutcome) {
        let started = uploadWaitStarted[digest] ?? clock.now
        uploadWaitStarted[digest] = started
        if clock.now.timeIntervalSince(started) >= Self.uploadPatience {
            outcome.message = String(localized: "This Project's image hasn't reached iCloud after an hour. The rest of the Project still syncs.", comment: "Shared Project images: an upload has not finished after an hour")
        }
    }

    // MARK: - Download

    private func download(digest: String, outcome: inout PassOutcome) async {
        let name = workList.first { $0.digest == digest }?.name ?? "image"
        do {
            switch try await transport.state(digest: digest) {
            case .absent:
                outcome.waiting = true
            case .notDownloaded:
                outcome.waiting = true
                if requestedDownloads.insert(digest).inserted {
                    do {
                        try await transport.requestDownload(digest: digest)
                    } catch {
                        logger.notice("shared background image download request failed: \(error.localizedDescription, privacy: .public)")
                        failedDownloads.insert(digest)
                    }
                }
                if failedDownloads.contains(digest) {
                    try await readAndStore(digest: digest, name: name, outcome: &outcome)
                }
            case .local:
                try await readAndStore(digest: digest, name: name, outcome: &outcome)
            }
        } catch SharedImageTransportError.notAllowed {
            outcome.waiting = true
            outcome.message = Self.notAllowedMessage
        } catch SharedImageTransportError.tooLarge {
            outcome.waiting = true
            outcome.message = String(localized: "The copy of \(name) in iCloud Drive is too large to use.", comment: "Shared Project images: the file in iCloud Drive is over the size limit; the argument is the image's name")
        } catch {
            logger.notice("shared background image read failed: \(error.localizedDescription, privacy: .public)")
            outcome.waiting = true
        }
    }

    /// A mismatch requests a download once and stays waiting, because iCloud
    /// Drive can leave an old version in place.
    private func readAndStore(digest: String, name: String, outcome: inout PassOutcome) async throws {
        let bytes = try await transport.read(digest: digest)
        if let cache = tabImageCache(), !workList.contains(where: { $0.digest == digest && $0.kind == .project }) {
            let verified = await Task.detached { TerminalBackgroundImageImporter.hexDigest(of: bytes) == digest }.value
            guard verified, let inserted = await cache.insertVerified(bytes: bytes, digest: digest, name: name, pinned: pinnedTabDigests()) else {
                outcome.waiting = true
                outcome.message = String(localized: "The copy of \(name) in iCloud Drive doesn't match this Project, so it wasn't used.", comment: "Shared Project images: the file in iCloud Drive failed verification; the argument is the image's name")
                if requestedDownloads.insert(digest).inserted {
                    try? await transport.requestDownload(digest: digest)
                }
                return
            }
            onTabEviction?(inserted.evicted)
            applyArrival(digest: digest, path: inserted.path)
            return
        }
        let directory = directory
        let state = await Task.detached {
            TerminalBackgroundImageImporter.storeVerified(bytes: bytes, digest: digest, name: name, into: directory)
        }.value
        guard state == .usable else {
            outcome.waiting = true
            outcome.message = String(localized: "The copy of \(name) in iCloud Drive doesn't match this Project, so it wasn't used.", comment: "Shared Project images: the file in iCloud Drive failed verification; the argument is the image's name")
            if requestedDownloads.insert(digest).inserted {
                try? await transport.requestDownload(digest: digest)
            }
            return
        }
        applyArrival(digest: digest, path: TerminalBackgroundImageImporter.verifiedPath(digest: digest, name: name, in: directory))
    }

    private func applyArrival(digest: String, path: String) {
        // iCloud Drive can evict the shared copy again, and the local copy can
        // be removed, so a later wait for this digest has to ask again.
        requestedDownloads.remove(digest)
        failedDownloads.remove(digest)
        requestedTabDigests.remove(digest)
        var applied = false
        for item in workList where item.kind == .tab && item.digest == digest && !item.pathMatches {
            onTabArrival?(item.id, .custom(digest: digest, name: item.name), path)
            applied = true
        }
        for item in workList where item.kind == .project && item.digest == digest && !item.pathMatches {
            do {
                guard try store.setResolvedSharedImage(id: item.id, digest: digest, path: path),
                      let project = store.project(id: item.id)
                else { continue }
                onArrival?(project, path)
                applied = true
            } catch {
                logger.error("could not record an arrived image: \(error.localizedDescription, privacy: .public)")
            }
        }
        if applied { notificationCenter.post(name: .battyBackgroundImagesDidChange, object: nil) }
    }

    // MARK: - Retry

    /// A retry reaches the folder without a user action, so it starts only once
    /// one has reached it.
    private func updateRetry(waiting: Bool) {
        guard waiting else {
            retryTask?.cancel()
            retryTask = nil
            return
        }
        guard retryTask == nil, folderWasReached else { return }
        let clock = clock
        retryTask = Task { [weak self] in
            var delay = Self.initialRetryDelay
            while !Task.isCancelled {
                await clock.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let pass = self?.reconcile(userInitiated: false) else { return }
                await pass.value
                delay = min(delay * 2, Self.maximumRetryDelay)
            }
        }
    }

    // MARK: - Sweep

    /// At most once per launch, and only when everything that could name a
    /// digest can be trusted. Never reads a file's contents. Nil if it didn't
    /// start; await the task in a test.
    @discardableResult
    func sweepIfAllowed() -> Task<Void, Never>? {
        guard !hasSwept, folderWasReached, let ledgerURL else { return nil }
        guard let named = store.namedSharedImageDigestsIfTrusted() else {
            logger.notice("not sweeping shared background images: can't tell which are still named")
            return nil
        }
        hasSwept = true
        let transport = transport
        let now = clock.now
        return Task.detached {
            guard await transport.availability() == .available,
                  let listed = try? await transport.listDigests()
            else { return }
            let decision = SharedImageSweep.decide(
                listed: listed, named: named, ledger: SharedImageSweep.readLedger(at: ledgerURL), now: now)
            for digest in decision.delete {
                try? await transport.delete(digest: digest)
            }
            SharedImageSweep.writeLedger(decision.ledger, to: ledgerURL)
        }
    }

    // MARK: - Writes on change

    private func setMessage(_ value: String?) {
        if message != value { message = value }
    }

    private func setStatus(_ value: [String: SharedImageStatus]) {
        if sharedStatus != value { sharedStatus = value }
    }

    private func setStatus(_ digest: String, _ value: SharedImageStatus?) {
        if sharedStatus[digest] != value { sharedStatus[digest] = value }
    }
}
