// TerminalDelegateProxy.swift

import AppKit
import Foundation
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalDelegateProxy")

final class TerminalDelegateProxy: NSObject,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceHoverLinkDelegate
{
    private let state: TerminalViewState
    private var didPushHoverCursor: Bool = false

    private(set) var hoveredURL: String?

    /// Fires on every working-directory change libghostty reports, after the
    /// new path has been written to `state`. The host wires this to drive
    /// session auto-naming directly, rather than relying on a SwiftUI
    /// `.onChange` over `state.workingDirectory` — that property is a Combine
    /// `@Published` on an `ObservableObject`, which the `@Observable` model
    /// layer does not track, so the view-driven path fired only opportunistically
    /// and left names stuck on the initial directory (#0226-adjacent; see #0227).
    var onWorkingDirectoryChange: ((String) -> Void)?

    init(state: TerminalViewState) {
        self.state = state
    }

    func terminalDidChangeTitle(_ title: String) {
        state.terminalDidChangeTitle(title)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        state.terminalDidResize(size)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        state.terminalDidChangeFocus(focused)
    }

    func terminalDidClose(processAlive: Bool) {
        state.terminalDidClose(processAlive: processAlive)
    }

    func terminalDidRingBell() {
        state.terminalDidRingBell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        state.terminalDidChangeWorkingDirectory(path)
        onWorkingDirectoryChange?(path)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        state.terminalDidAttachSurface(surface)
    }

    func terminalDidDetachSurface() {
        state.terminalDidDetachSurface()
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        HyperlinkOpener.open(url)
    }

    func terminalDidUpdateHoverLink(_ url: String?) {
        hoveredURL = url
        if url != nil {
            if !didPushHoverCursor {
                NSCursor.pointingHand.push()
                didPushHoverCursor = true
            }
        } else if didPushHoverCursor {
            NSCursor.pop()
            didPushHoverCursor = false
        }
    }
}
