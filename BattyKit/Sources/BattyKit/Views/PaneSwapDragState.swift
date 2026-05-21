// PaneSwapDragState.swift

import AppKit
import Observation
import OSLog

nonisolated private let dragStateLogger = Logger(subsystem: Logging.subsystem, category: "PaneView")

enum EndDragTrigger: String {
    case mouseUp
    case fallbackTimer
    case dropDefer
    case startDragReplaced
}

@MainActor
@Observable
final class PaneSwapDragState {
    static let shared = PaneSwapDragState()
    private(set) var isDragging = false
    private(set) var sourcePaneID: UUID? = nil
    private var monitor: Any? = nil
    private var fallbackTimer: Timer? = nil

    func startDrag(from paneID: UUID) {
        let hadPrior = isDragging
        endDrag(trigger: .startDragReplaced)
        isDragging = true
        sourcePaneID = paneID
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async { self?.endDrag(trigger: .mouseUp) }
        }
        let monitorInstalled = monitor != nil
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                dragStateLogger.notice("pane-swap: fallback timer fired (30s) — cleaning up leaked drag state")
                self?.endDrag(trigger: .fallbackTimer)
            }
        }
        dragStateLogger.info("pane-swap: startDrag source=\(paneID, privacy: .public) priorActive=\(hadPrior ? "Y" : "N", privacy: .public) monitor=\(monitorInstalled ? "Y" : "N", privacy: .public)")
    }

    func endDrag(trigger: EndDragTrigger) {
        let prior = sourcePaneID?.uuidString ?? "nil"
        let wasActive = isDragging
        isDragging = false
        sourcePaneID = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        dragStateLogger.info("pane-swap: endDrag source=\(prior, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) wasActive=\(wasActive ? "Y" : "N", privacy: .public)")
    }
}
