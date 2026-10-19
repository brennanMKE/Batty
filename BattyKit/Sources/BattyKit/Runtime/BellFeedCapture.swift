// BellFeedCapture.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BellFeedCapture")

/// Record shapes for the opt-in Bell Feed capture log (`docs/bell-feed-capture.md`).
/// Optionals encode as explicit JSON `null` so every key is always present.
public nonisolated enum BellCaptureSchema {
    public static let version = 1
    public static let maxMessageCharacters = 16 * 1024
}

public nonisolated struct BellCaptureProcess: Codable, Sendable, Equatable {
    public var pid: Int32
    public var name: String?
    public var executablePath: String?

    public init(pid: Int32, name: String?, executablePath: String?) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
    }

    private enum CodingKeys: String, CodingKey { case pid, name, executablePath }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        try c.encode(name, forKey: .name)
        try c.encode(executablePath, forKey: .executablePath)
    }
}

public nonisolated struct BellCaptureCollapse: Codable, Sendable, Equatable {
    public var collapsed: Bool
    public var repeatCount: Int
    public var firstOccurrenceAt: Date

    public init(collapsed: Bool, repeatCount: Int, firstOccurrenceAt: Date) {
        self.collapsed = collapsed
        self.repeatCount = repeatCount
        self.firstOccurrenceAt = firstOccurrenceAt
    }
}

public nonisolated struct BellCaptureNotification: Codable, Sendable, Equatable {
    public var outcome: String
    public var reason: String?

    public init(outcome: String, reason: String?) {
        self.outcome = outcome
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case outcome, reason }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(reason, forKey: .reason)
    }
}

public nonisolated enum BellCaptureSummarization: String, Codable, Sendable, Equatable {
    case scheduled
    case skippedNoSummarizer
    case skippedDisabled
    case notApplicableCollapsed
}

public nonisolated struct BellCaptureEvent: Codable, Sendable, Equatable {
    public var schema: Int = BellCaptureSchema.version
    public var type: String = "event"
    public var recordID: UUID
    public var entryID: UUID
    public var capturedAt: Date
    public var appVersion: String?
    public var appBuild: String?

    public var windowID: UUID
    public var sessionID: UUID
    public var paneID: UUID
    public var tabID: UUID

    public var trigger: String
    public var message: String?
    public var messageTruncated: Bool
    public var tabTitle: String
    public var tabLabel: String
    public var sessionTitle: String
    public var foregroundProcess: BellCaptureProcess?
    public var workingDirectory: String?
    public var screen: [String]?
    public var screenUnavailableReason: String?

    public var seenAtCreation: Bool
    public var battyActive: Bool
    public var sessionMuted: Bool
    public var systemNotificationsEnabled: Bool
    public var notifierPresent: Bool
    public var collapse: BellCaptureCollapse
    public var notification: BellCaptureNotification
    public var notificationTitle: String?
    public var notificationBody: String?
    public var feedRowPath: String
    public var feedRowText: String?
    public var summarization: BellCaptureSummarization

    public init(
        recordID: UUID = UUID(),
        entryID: UUID,
        capturedAt: Date,
        appVersion: String?,
        appBuild: String?,
        windowID: UUID,
        sessionID: UUID,
        paneID: UUID,
        tabID: UUID,
        trigger: String,
        message: String?,
        messageTruncated: Bool,
        tabTitle: String,
        tabLabel: String,
        sessionTitle: String,
        foregroundProcess: BellCaptureProcess?,
        workingDirectory: String?,
        screen: [String]?,
        screenUnavailableReason: String?,
        seenAtCreation: Bool,
        battyActive: Bool,
        sessionMuted: Bool,
        systemNotificationsEnabled: Bool,
        notifierPresent: Bool,
        collapse: BellCaptureCollapse,
        notification: BellCaptureNotification,
        notificationTitle: String?,
        notificationBody: String?,
        feedRowPath: String,
        feedRowText: String?,
        summarization: BellCaptureSummarization
    ) {
        self.recordID = recordID
        self.entryID = entryID
        self.capturedAt = capturedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.windowID = windowID
        self.sessionID = sessionID
        self.paneID = paneID
        self.tabID = tabID
        self.trigger = trigger
        self.message = message
        self.messageTruncated = messageTruncated
        self.tabTitle = tabTitle
        self.tabLabel = tabLabel
        self.sessionTitle = sessionTitle
        self.foregroundProcess = foregroundProcess
        self.workingDirectory = workingDirectory
        self.screen = screen
        self.screenUnavailableReason = screenUnavailableReason
        self.seenAtCreation = seenAtCreation
        self.battyActive = battyActive
        self.sessionMuted = sessionMuted
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.notifierPresent = notifierPresent
        self.collapse = collapse
        self.notification = notification
        self.notificationTitle = notificationTitle
        self.notificationBody = notificationBody
        self.feedRowPath = feedRowPath
        self.feedRowText = feedRowText
        self.summarization = summarization
    }

    private enum CodingKeys: String, CodingKey {
        case schema, type, recordID, entryID, capturedAt, appVersion, appBuild
        case windowID, sessionID, paneID, tabID
        case trigger, message, messageTruncated, tabTitle, tabLabel, sessionTitle
        case foregroundProcess, workingDirectory, screen, screenUnavailableReason
        case seenAtCreation, battyActive, sessionMuted, systemNotificationsEnabled, notifierPresent
        case collapse, notification, notificationTitle, notificationBody
        case feedRowPath, feedRowText, summarization
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(type, forKey: .type)
        try c.encode(recordID, forKey: .recordID)
        try c.encode(entryID, forKey: .entryID)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(appBuild, forKey: .appBuild)
        try c.encode(windowID, forKey: .windowID)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(paneID, forKey: .paneID)
        try c.encode(tabID, forKey: .tabID)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(message, forKey: .message)
        try c.encode(messageTruncated, forKey: .messageTruncated)
        try c.encode(tabTitle, forKey: .tabTitle)
        try c.encode(tabLabel, forKey: .tabLabel)
        try c.encode(sessionTitle, forKey: .sessionTitle)
        try c.encode(foregroundProcess, forKey: .foregroundProcess)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encode(screen, forKey: .screen)
        try c.encode(screenUnavailableReason, forKey: .screenUnavailableReason)
        try c.encode(seenAtCreation, forKey: .seenAtCreation)
        try c.encode(battyActive, forKey: .battyActive)
        try c.encode(sessionMuted, forKey: .sessionMuted)
        try c.encode(systemNotificationsEnabled, forKey: .systemNotificationsEnabled)
        try c.encode(notifierPresent, forKey: .notifierPresent)
        try c.encode(collapse, forKey: .collapse)
        try c.encode(notification, forKey: .notification)
        try c.encode(notificationTitle, forKey: .notificationTitle)
        try c.encode(notificationBody, forKey: .notificationBody)
        try c.encode(feedRowPath, forKey: .feedRowPath)
        try c.encode(feedRowText, forKey: .feedRowText)
        try c.encode(summarization, forKey: .summarization)
    }
}

public nonisolated enum BellCaptureSummaryStatus: String, Codable, Sendable, Equatable {
    case ok
    case none
    case rejectedBySanitize
    case modelUnavailable
    case error
    case cancelled
    /// Reserved: no summarizer imposes a timeout today.
    case timedOut
}

public nonisolated struct BellCaptureSummary: Codable, Sendable, Equatable {
    public var schema: Int = BellCaptureSchema.version
    public var type: String = "summary"
    public var recordID: UUID
    public var entryID: UUID
    public var capturedAt: Date
    public var instructions: String?
    public var prompt: String?
    public var rawReply: String?
    public var status: BellCaptureSummaryStatus
    public var errorDescription: String?
    public var elapsedSeconds: Double
    public var sanitizedSummary: String?
    public var feedRowText: String?

    public init(
        recordID: UUID = UUID(),
        entryID: UUID,
        capturedAt: Date,
        instructions: String?,
        prompt: String?,
        rawReply: String?,
        status: BellCaptureSummaryStatus,
        errorDescription: String?,
        elapsedSeconds: Double,
        sanitizedSummary: String?,
        feedRowText: String?
    ) {
        self.recordID = recordID
        self.entryID = entryID
        self.capturedAt = capturedAt
        self.instructions = instructions
        self.prompt = prompt
        self.rawReply = rawReply
        self.status = status
        self.errorDescription = errorDescription
        self.elapsedSeconds = elapsedSeconds
        self.sanitizedSummary = sanitizedSummary
        self.feedRowText = feedRowText
    }

    private enum CodingKeys: String, CodingKey {
        case schema, type, recordID, entryID, capturedAt, instructions, prompt, rawReply
        case status, errorDescription, elapsedSeconds, sanitizedSummary, feedRowText
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(type, forKey: .type)
        try c.encode(recordID, forKey: .recordID)
        try c.encode(entryID, forKey: .entryID)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(rawReply, forKey: .rawReply)
        try c.encode(status, forKey: .status)
        try c.encode(errorDescription, forKey: .errorDescription)
        try c.encode(elapsedSeconds, forKey: .elapsedSeconds)
        try c.encode(sanitizedSummary, forKey: .sanitizedSummary)
        try c.encode(feedRowText, forKey: .feedRowText)
    }
}

/// Serial, off-main JSON Lines writer for the capture log. Callers on the
/// main actor only hand over a `Sendable` record: encoding, rotation and all
/// file I/O happen on a private serial queue, so records are appended in
/// enqueue order and never interleave. Failures are logged, never thrown.
public nonisolated final class BellCaptureWriter: @unchecked Sendable {
    public static let fileName = "bell-feed-capture.jsonl"
    public static let rotatedFileName = "bell-feed-capture.1.jsonl"
    public static let defaultMaxRecords = 1000
    public static let defaultMaxBytes = 10 * 1024 * 1024

    public let directory: URL
    private let maxRecords: Int
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "co.sstools.Batty.BellCaptureWriter")

    private let generationLock = NSLock()
    private var generationValue = 0

    /// Bumped synchronously by `clear()`. A record enqueued with the
    /// generation read before a `clear()` is dropped on the queue, so a
    /// `summary` whose `event` was cleared can never land in the fresh file.
    public var generation: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generationValue
    }

    // Confined to `queue`. nil until the current file has been measured.
    private var recordCount: Int?
    private var byteCount = 0

    public init(directory: URL, maxRecords: Int = BellCaptureWriter.defaultMaxRecords, maxBytes: Int = BellCaptureWriter.defaultMaxBytes) {
        self.directory = directory
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
    }

    @MainActor public static func defaultDirectory(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent(SessionNameCache.resolvedDirectoryName(bundleIdentifier: bundleIdentifier), isDirectory: true)
    }

    public var currentFileURL: URL { directory.appendingPathComponent(Self.fileName) }
    public var rotatedFileURL: URL { directory.appendingPathComponent(Self.rotatedFileName) }

    public func enqueue<R: Encodable & Sendable>(_ record: R, generation expected: Int? = nil) {
        queue.async { [self] in
            if let expected, expected != generation { return }
            append(record)
        }
    }

    /// Completes once everything enqueued before this call has been handled.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    public func clear() {
        generationLock.lock()
        generationValue += 1
        generationLock.unlock()
        queue.async { [self] in
            let fm = FileManager.default
            for url in [currentFileURL, rotatedFileURL] where fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    logger.error("clear failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            recordCount = 0
            byteCount = 0
        }
    }

    public func currentFileExists() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                continuation.resume(returning: FileManager.default.fileExists(atPath: currentFileURL.path))
            }
        }
    }

    private func append<R: Encodable>(_ record: R) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var line: Data
        do {
            line = try encoder.encode(record)
        } catch {
            logger.error("encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        line.append(0x0A)

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if recordCount == nil { measureCurrentFile(fm) }
            if let count = recordCount, count > 0, count >= maxRecords || byteCount + line.count > maxBytes {
                try rotate(fm)
            }
            if !fm.fileExists(atPath: currentFileURL.path) {
                guard fm.createFile(atPath: currentFileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                recordCount = 0
                byteCount = 0
            }
            let handle = try FileHandle(forWritingTo: currentFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            recordCount = (recordCount ?? 0) + 1
            byteCount += line.count
        } catch {
            logger.error("append failed: \(error.localizedDescription, privacy: .public)")
            recordCount = nil
        }
    }

    private func measureCurrentFile(_ fm: FileManager) {
        guard let data = fm.contents(atPath: currentFileURL.path) else {
            recordCount = 0
            byteCount = 0
            return
        }
        recordCount = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        byteCount = data.count
    }

    private func rotate(_ fm: FileManager) throws {
        if fm.fileExists(atPath: rotatedFileURL.path) {
            try fm.removeItem(at: rotatedFileURL)
        }
        try fm.moveItem(at: currentFileURL, to: rotatedFileURL)
        recordCount = 0
        byteCount = 0
    }
}
