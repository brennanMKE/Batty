// BackgroundImagesScrollMonitor.swift

import AppKit
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BackgroundImagesScrollMonitor")

/// The last few things that happened to the Background Images window and its
/// models, newest last. A run of the same kind is kept as one entry with a
/// count, so a burst of thumbnail loads doesn't push everything else out.
nonisolated struct BackgroundImagesEventRing: Equatable {
    struct Entry: Equatable {
        var kind: String
        var at: Date
        var count: Int
    }

    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int = 12) {
        self.capacity = capacity
    }

    mutating func record(_ kind: String, at date: Date) {
        if let last = entries.indices.last, entries[last].kind == kind {
            entries[last].at = date
            entries[last].count += 1
            return
        }
        entries.append(Entry(kind: kind, at: date, count: 1))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Oldest first, each as seconds before `now`: `-1.250s window became key`.
    func formatted(relativeTo now: Date) -> String {
        guard !entries.isEmpty else { return "none" }
        return entries.map { entry in
            let ago = String(format: "-%.3fs", now.timeIntervalSince(entry.at))
            return entry.count > 1 ? "\(ago) \(entry.kind) x\(entry.count)" : "\(ago) \(entry.kind)"
        }.joined(separator: "; ")
    }
}

/// Plain storage, never observed: written from action and model paths that
/// already run, and read only when a jump is logged.
@MainActor
final class BackgroundImagesDiagnostics {
    static let shared = BackgroundImagesDiagnostics()

    private(set) var ring = BackgroundImagesEventRing()
    /// The manage window's tab; the picker sheet doesn't write it.
    var tab = "My Images"

    func record(_ kind: String) {
        ring.record(kind, at: Date())
    }
}

/// Logs a clip-view origin change of more than `threshold` points in the
/// Background Images window that no scroll gesture explains, with the recent
/// events, so a jump on a user's Mac names what preceded it. Watches every
/// clip view in its window, since switching tabs replaces the scroll view.
@MainActor
final class BackgroundImagesScrollMonitor {
    static let threshold: CGFloat = 4
    /// Momentum keeps scrolling for a while after the last wheel event.
    private static let wheelQuiet: TimeInterval = 1

    private weak var window: NSWindow?
    private var origins: [ObjectIdentifier: CGFloat] = [:]
    private var liveScrolls = 0
    private var lastWheel: Date?
    private var observers: [NSObjectProtocol] = []
    private var wheelMonitor: Any?

    init(window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            let clip = note.object as? NSClipView
            MainActor.assumeIsolated { self?.boundsChanged(clip) }
        })
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
            let scroll = note.object as? NSScrollView
            MainActor.assumeIsolated { self?.liveScroll(scroll, started: true) }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
            let scroll = note.object as? NSScrollView
            MainActor.assumeIsolated { self?.liveScroll(scroll, started: false) }
        })
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window { self.lastWheel = Date() }
            }
            return event
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    private func liveScroll(_ scroll: NSScrollView?, started: Bool) {
        guard let scroll, let window, scroll.window === window else { return }
        liveScrolls = max(0, liveScrolls + (started ? 1 : -1))
    }

    private func boundsChanged(_ clip: NSClipView?) {
        guard let clip, let window, clip.window === window else { return }
        if window.inLiveResize { return }
        let id = ObjectIdentifier(clip)
        let origin = clip.bounds.origin.y
        let old = origins.updateValue(origin, forKey: id)
        guard let old, abs(origin - old) > Self.threshold else { return }
        if liveScrolls > 0 { return }
        if let lastWheel, Date().timeIntervalSince(lastWheel) < Self.wheelQuiet { return }
        let diagnostics = BackgroundImagesDiagnostics.shared
        let document = clip.documentView?.frame.height ?? 0
        let event = NSApp.currentEvent.map { String(describing: $0.type) } ?? "none"
        logger.notice("""
            Unexpected scroll in \(diagnostics.tab, privacy: .public): origin \(Double(old), privacy: .public) -> \(Double(origin), privacy: .public), \
            document height \(Double(document), privacy: .public), current event \(event, privacy: .public); \
            recent: \(diagnostics.ring.formatted(relativeTo: Date()), privacy: .public)
            """)
    }
}
