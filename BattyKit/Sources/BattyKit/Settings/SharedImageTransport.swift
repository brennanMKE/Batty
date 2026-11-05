// SharedImageTransport.swift

import Darwin
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SharedImageTransport")

nonisolated enum SharedImageAvailability: Sendable, Equatable {
    case available
    case off
    case notAllowed
}

nonisolated enum SharedImageFileState: Sendable, Equatable {
    case absent
    case notDownloaded
    case local
}

nonisolated enum SharedImageUploadProblem: Sendable, Equatable {
    case iCloudFull
    case other
}

nonisolated enum SharedImageTransportError: Error, Sendable, Equatable {
    case invalidDigest
    case tooLarge
    case notAllowed
}

/// Where a Shared Project's image travels between Macs. Every call may block on
/// the network or a permission prompt, so implementations stay off the main
/// actor. It only moves bytes: the caller checks them against the record.
nonisolated protocol SharedImageTransport: Sendable {
    func availability() async -> SharedImageAvailability
    func state(digest: String) async throws -> SharedImageFileState
    func requestDownload(digest: String) async throws
    func read(digest: String) async throws -> Data
    func write(from source: URL, digest: String) async throws
    func uploadProblem(digest: String) async -> SharedImageUploadProblem?
    func isUploaded(digest: String) async -> Bool
    func listDigests() async throws -> [String]
    func delete(digest: String) async throws
}

/// A plain folder in iCloud Drive, one per variant because Prod and Beta have
/// separate key-value stores. Nothing here sets an I/O materialization policy:
/// `setiopolicy_np` at process scope would be inherited by every shell in a Pane.
nonisolated final class ICloudDriveImageFolder: SharedImageTransport, Sendable {
    static let maxFileBytes = 100 * 1_024 * 1_024

    private let cloudDrive: URL
    private let folder: URL
    private let queue = DispatchQueue(label: "co.sstools.Batty.ICloudDriveImageFolder")

    /// Touches no files.
    init(cloudDrive: URL, variantFolderName: String) {
        self.cloudDrive = cloudDrive
        self.folder = cloudDrive
            .appendingPathComponent(variantFolderName, isDirectory: true)
            .appendingPathComponent("Project Backgrounds", isDirectory: true)
    }

    static func defaultCloudDrive() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private func url(digest: String) throws -> URL {
        guard TerminalBackgroundImageImporter.isDigest(digest) else { throw SharedImageTransportError.invalidDigest }
        return folder.appendingPathComponent(digest + ".png")
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError { return true }
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError) ?? nsError
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    private static func mapped(_ error: Error) -> Error {
        isPermissionError(error) ? SharedImageTransportError.notAllowed : error
    }

    func availability() async -> SharedImageAvailability {
        let cloudDrive = cloudDrive
        let result = try? await run { () -> SharedImageAvailability in
            var info = stat()
            if lstat(cloudDrive.path, &info) != 0 {
                return errno == EPERM || errno == EACCES ? .notAllowed : .off
            }
            guard let directory = opendir(cloudDrive.path) else {
                return errno == EPERM || errno == EACCES ? .notAllowed : .off
            }
            closedir(directory)
            let isUbiquitous = (try? cloudDrive.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem
            return isUbiquitous == true ? .available : .off
        }
        return result ?? .off
    }

    /// `lstat` reads no contents, so asking never starts a download.
    func state(digest: String) async throws -> SharedImageFileState {
        let file = try url(digest: digest)
        return try await run {
            var info = stat()
            guard lstat(file.path, &info) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return .absent }
                if errno == EPERM || errno == EACCES { throw SharedImageTransportError.notAllowed }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if info.st_flags & UInt32(SF_DATALESS) != 0 { return .notDownloaded }
            let status = (try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            return status == .notDownloaded ? .notDownloaded : .local
        }
    }

    func requestDownload(digest: String) async throws {
        let file = try url(digest: digest)
        try await run {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: file)
            } catch {
                throw Self.mapped(error)
            }
        }
    }

    func read(digest: String) async throws -> Data {
        let file = try url(digest: digest)
        return try await run {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                if let size = attributes[.size] as? Int, size > Self.maxFileBytes {
                    throw SharedImageTransportError.tooLarge
                }
                return try Data(contentsOf: file)
            } catch {
                throw Self.mapped(error)
            }
        }
    }

    /// Staged on the same volume but outside the synced folder, so another Mac
    /// never sees a partial file.
    func write(from source: URL, digest: String) async throws {
        let destination = try url(digest: digest)
        let folder = folder
        try await run {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                defer { try? fileManager.removeItem(at: staging) }
                let staged = staging.appendingPathComponent(destination.lastPathComponent)
                try fileManager.copyItem(at: source, to: staged)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try fileManager.moveItem(at: staged, to: destination)
                }
            } catch {
                throw Self.mapped(error)
            }
        }
    }

    func uploadProblem(digest: String) async -> SharedImageUploadProblem? {
        guard let file = try? url(digest: digest) else { return nil }
        return try? await run { () -> SharedImageUploadProblem? in
            let values = try file.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey])
            guard let error = values.ubiquitousItemUploadingError else { return nil }
            return (error as NSError).code == NSUbiquitousFileNotUploadedDueToQuotaError ? .iCloudFull : .other
        }
    }

    func isUploaded(digest: String) async -> Bool {
        guard let file = try? url(digest: digest) else { return false }
        return (try? await run {
            try file.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]).ubiquitousItemIsUploaded == true
        }) ?? false
    }

    /// Only `<digest>.png` names: anything else in the folder isn't Batty's.
    func listDigests() async throws -> [String] {
        let folder = folder
        return try await run {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            } catch {
                if (error as NSError).code == NSFileReadNoSuchFileError { return [] }
                throw Self.mapped(error)
            }
            return names.compactMap { name in
                guard name.hasSuffix(".png") else { return nil }
                let digest = String(name.dropLast(4))
                return TerminalBackgroundImageImporter.isDigest(digest) ? digest : nil
            }
        }
    }

    func delete(digest: String) async throws {
        let file = try url(digest: digest)
        try await run {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logger.error("could not delete a shared background image: \(error.localizedDescription, privacy: .private)")
                throw Self.mapped(error)
            }
        }
    }
}
