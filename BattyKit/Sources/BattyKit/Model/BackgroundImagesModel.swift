// BackgroundImagesModel.swift

import Foundation
import Observation

extension Notification.Name {
    static let battyBackgroundImagesDidChange = Notification.Name("co.sstools.Batty.backgroundImagesDidChange")
}

/// What the Background Images window and picker show. Every write starts from
/// a button action or follows an `await` that real file work needs, never from
/// `body`, and writes only on change because every observed write notifies.
@MainActor
@Observable
final class BackgroundImagesModel {
    struct RemovalPlan: Equatable {
        let entry: BackgroundImageEntry
        let uses: [BackgroundImageUse]
        /// Why nothing can be removed now. When set, `uses` isn't worth showing.
        let refusal: String?
        /// A Shared Project uses this image and its copy stays in iCloud Drive.
        var keepsOnOtherMacs = false
    }

    private(set) var entries: [BackgroundImageEntry] = []
    private(set) var uses: [String: [BackgroundImageUse]] = [:]
    private(set) var message: String?
    private(set) var isScanning = false

    @ObservationIgnored let library: BackgroundImageLibrary
    @ObservationIgnored let thumbnailer: BackgroundImageThumbnailer
    @ObservationIgnored private let findUses: @MainActor () -> [String: [BackgroundImageUse]]
    @ObservationIgnored private let refusal: @MainActor (String) -> String?
    @ObservationIgnored private let clearUses: @MainActor (String) throws -> Void
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let sharedImages: @MainActor () -> SharedProjectImages?

    init(
        library: BackgroundImageLibrary,
        thumbnailer: BackgroundImageThumbnailer,
        uses: @escaping @MainActor () -> [String: [BackgroundImageUse]],
        refusal: @escaping @MainActor (String) -> String?,
        clearUses: @escaping @MainActor (String) throws -> Void,
        notificationCenter: NotificationCenter = .default,
        sharedImages: @escaping @MainActor () -> SharedProjectImages? = { nil }
    ) {
        self.sharedImages = sharedImages
        self.library = library
        self.thumbnailer = thumbnailer
        self.findUses = uses
        self.refusal = refusal
        self.clearUses = clearUses
        self.notificationCenter = notificationCenter
    }

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.sizeInBytes } }

    func refresh() async {
        setScanning(true)
        let scanned = await library.scan()
        if scanned != entries { entries = scanned }
        refreshUses()
        setScanning(false)
    }

    /// Imports into the library. Nil, with `message` saying so, if it can't be read.
    func add(from url: URL) async -> BackgroundImageEntry? {
        setMessage(nil)
        do {
            let entry = try await library.add(from: url)
            await refresh()
            return entry
        } catch {
            setMessage(String(localized: "That image could not be read."))
            return nil
        }
    }

    func reportFileError() {
        setMessage(String(localized: "That file could not be opened."))
    }

    func prepareRemoval(_ entry: BackgroundImageEntry) -> RemovalPlan {
        let uses = findUses()[entry.digest] ?? []
        let usedByShared = uses.contains {
            if case .project(_, _, true) = $0 { return true }
            return false
        }
        return RemovalPlan(
            entry: entry, uses: uses, refusal: refusal(entry.digest),
            keepsOnOtherMacs: usedByShared && sharedImages() != nil)
    }

    /// A digest with no Shared Project behind it has no status at all.
    func sharedStatus(forDigest digest: String) -> SharedImageStatus? {
        sharedImages()?.sharedStatus[digest]
    }

    /// Uses are cleared first, and a failure there deletes nothing: a path left
    /// naming a deleted file is the silent break this exists to avoid.
    func remove(_ entry: BackgroundImageEntry) async {
        let plan = prepareRemoval(entry)
        if let reason = plan.refusal {
            setMessage(reason)
            return
        }
        do {
            try clearUses(entry.digest)
        } catch {
            setMessage(String(localized: "\(entry.name) was not removed: \(error.localizedDescription)", comment: "Background Images: the image's uses could not be cleared; the arguments are its name and the error"))
            return
        }
        let failed = await library.remove(digest: entry.digest)
        setMessage(Self.removalMessage(entry: entry, uses: plan.uses, failed: failed))
        await refresh()
        notificationCenter.post(name: .battyBackgroundImagesDidChange, object: nil)
    }

    private static func removalMessage(entry: BackgroundImageEntry, uses: [BackgroundImageUse], failed: [URL]) -> String {
        if !failed.isEmpty {
            let folders = failed.map(\.path).joined(separator: ", ")
            return String(localized: "\(entry.name) could not be deleted from \(folders).", comment: "Background Images: some folders could not be deleted; the arguments are the image's name and the folders")
        }
        guard let summary = BackgroundImageUse.summary(of: uses) else {
            return String(localized: "Removed \(entry.name).", comment: "Background Images: an unused image was removed")
        }
        return uses.count == 1
            ? String(localized: "Removed \(entry.name). \(summary) now has no image.", comment: "Background Images: an image with one use was removed; the second argument names the use")
            : String(localized: "Removed \(entry.name). \(summary) now have no image.", comment: "Background Images: an image with several uses was removed; the second argument names them")
    }

    /// From memory only, with no scan, so it is cheap enough to run on an event.
    func refreshUses() {
        let found = findUses()
        if found != uses { uses = found }
    }

    private func setScanning(_ value: Bool) {
        if isScanning != value { isScanning = value }
    }

    private func setMessage(_ value: String?) {
        if message != value { message = value }
    }
}
