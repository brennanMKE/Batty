// LayoutConvergenceProbe.swift

import AppKit
import GhosttyTerminal
import ObjectiveC
import SwiftUI
import Testing
@testable import BattyKit

/// Test-only window for #0601's layout convergence probe. It counts calls
/// to AppKit's private `-[NSWindow _postWindowNeedsUpdateConstraints]` (the
/// method that raises in #0601's crash reports) and its layout twin
/// `_postWindowNeedsLayout`. Each call is a view asking the window for
/// another pass.
///
/// AppKit enforces its "more passes than there are views in the window"
/// cap in this harness: an unbounded loop raises `NSGenericException` from
/// the display cycle's `layoutIfNeeded()` (seen by hand with
/// `ConstraintLoopControl` and no breaker). For Batty's own trees that cap
/// is the detector, so a loop there ends the test process. The controls set
/// `postBreakerLimit` below their window's view count instead: past it the
/// window stops forwarding requests, which ends the loop before the cap and
/// leaves a settle that did not converge. Request counts are not pass
/// counts (a converging Session switch makes more requests than the window
/// has views), so the breaker is for controls only.
@MainActor
final class ProbeWindow: NSWindow {
    var postBreakerLimit: Int?

    private(set) var updateConstraintsCalls = 0
    private(set) var postNeedsUpdateConstraintsCalls = 0
    private(set) var postNeedsLayoutCalls = 0
    private(set) var brokeLoop = false

    /// One `makeFirstResponder(_:)` call on this window, including the ones
    /// AppKit makes itself when it hides the first responder.
    struct ResponderChange: CustomStringConvertible {
        var argument: String
        var argumentIsTerminal: Bool
        var previousIsTerminal: Bool
        var inLayout: Bool

        var description: String {
            "makeFirstResponder(\(argument)) previousIsTerminal=\(previousIsTerminal) inLayout=\(inLayout)"
        }
    }

    private(set) var responderChanges: [ResponderChange] = []
    /// Greater than zero while `layoutIfNeeded()` or the root hosting
    /// view's `layout()` is on the stack.
    var layoutDepth = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        responderChanges.append(ResponderChange(
            argument: responder.map { NSStringFromClass(type(of: $0)) } ?? "nil",
            argumentIsTerminal: responder is AppTerminalView,
            previousIsTerminal: firstResponder is AppTerminalView,
            inLayout: layoutDepth > 0
        ))
        return super.makeFirstResponder(responder)
    }

    override func layoutIfNeeded() {
        layoutDepth += 1
        defer { layoutDepth -= 1 }
        super.layoutIfNeeded()
    }

    func resetResponderChanges() {
        responderChanges = []
    }

    override func updateConstraintsIfNeeded() {
        updateConstraintsCalls += 1
        super.updateConstraintsIfNeeded()
    }

    @objc(_postWindowNeedsUpdateConstraints)
    func probePostWindowNeedsUpdateConstraints() {
        postNeedsUpdateConstraintsCalls += 1
        if let limit = postBreakerLimit, postNeedsUpdateConstraintsCalls > limit {
            brokeLoop = true
            return
        }
        forwardToNSWindow("_postWindowNeedsUpdateConstraints")
    }

    @objc(_postWindowNeedsLayout)
    func probePostWindowNeedsLayout() {
        postNeedsLayoutCalls += 1
        if let limit = postBreakerLimit, postNeedsLayoutCalls > limit {
            brokeLoop = true
            return
        }
        forwardToNSWindow("_postWindowNeedsLayout")
    }

    private func forwardToNSWindow(_ name: String) {
        let selector = NSSelectorFromString(name)
        guard let implementation = class_getMethodImplementation(NSWindow.self, selector) else { return }
        typealias Post = @convention(c) (NSWindow, Selector) -> Void
        unsafeBitCast(implementation, to: Post.self)(self, selector)
    }

    func resetCounts() {
        updateConstraintsCalls = 0
        postNeedsUpdateConstraintsCalls = 0
        postNeedsLayoutCalls = 0
        brokeLoop = false
    }
}

/// Root hosting view of the probe; counts its own update-constraints passes.
@MainActor
final class ProbeHostingView: NSHostingView<AnyView> {
    private(set) var passes = 0

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateConstraints() {
        passes += 1
        super.updateConstraints()
    }

    override func layout() {
        let probeWindow = window as? ProbeWindow
        probeWindow?.layoutDepth += 1
        defer { probeWindow?.layoutDepth -= 1 }
        super.layout()
    }

    func resetCounts() {
        passes = 0
    }
}

/// How one `settle()` ended.
enum SettleOutcome: String {
    /// Clean within `LayoutConvergenceProbe.calibratedRoundBound` rounds.
    case settled
    /// Clean, but after more rounds than calibration needed. Diagnostic
    /// only, never a failure.
    case settledLate
    /// Still dirty at the hang guard, or the controls' breaker tripped.
    case didNotConverge
}

struct SettleResult: CustomStringConvertible {
    /// Rounds run until no view in the window was dirty; `maxRounds + 1`
    /// when it never got there. Diagnostic only: how many rounds a clean
    /// settle needs depends on how fast the host turns the main queue.
    var rounds: Int
    var rootPasses: Int
    var windowUpdateConstraintsCalls: Int
    var postNeedsUpdateConstraintsCalls: Int
    var postNeedsLayoutCalls: Int
    var brokeLoop: Bool
    /// Class names of the views still dirty after the last round.
    var dirtyViews: [String]

    var outcome: SettleOutcome {
        if brokeLoop || rounds > LayoutConvergenceProbe.maxRounds { return .didNotConverge }
        if rounds > LayoutConvergenceProbe.calibratedRoundBound { return .settledLate }
        return .settled
    }

    var converged: Bool {
        outcome != .didNotConverge
    }

    var description: String {
        "outcome=\(outcome) rounds=\(rounds) rootPasses=\(rootPasses) windowUpdateConstraints=\(windowUpdateConstraintsCalls) posts=\(postNeedsUpdateConstraintsCalls) layoutPosts=\(postNeedsLayoutCalls) brokeLoop=\(brokeLoop) dirty=\(dirtyViews.prefix(6).map { $0.prefix(80) })"
    }
}

@MainActor
final class LayoutConvergenceProbe {
    /// Hang guard on one settle. A window still dirty after this many
    /// layout-plus-turn rounds is treated as a loop (`didNotConverge`).
    static let maxRounds = 12
    /// Every calibration settle took one round. A settle that ends clean
    /// after more rounds is `settledLate`: deferred main-queue work that a
    /// busy host delivers in later turns. It is diagnostic only, never a
    /// failure.
    static let calibratedRoundBound = 3

    let window: ProbeWindow
    let root: ProbeHostingView

    init<Content: View>(
        _ content: Content,
        size: CGSize,
        styleMask: NSWindow.StyleMask = [.borderless]
    ) {
        root = ProbeHostingView(rootView: AnyView(content))
        root.frame = CGRect(origin: .zero, size: size)
        window = ProbeWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
    }

    func resize(to size: CGSize) {
        window.setContentSize(size)
    }

    func allViews() -> [NSView] {
        var result: [NSView] = []
        func walk(_ view: NSView) {
            result.append(view)
            view.subviews.forEach(walk)
        }
        if let frameView = window.contentView?.superview {
            walk(frameView)
        } else if let contentView = window.contentView {
            walk(contentView)
        }
        return result
    }

    func dirtyViews() -> [NSView] {
        allViews().filter { $0.needsUpdateConstraints || $0.needsLayout }
    }

    func scrollViews() -> [NSScrollView] {
        allViews().compactMap { $0 as? NSScrollView }
    }

    func forceScrollerStyle(_ style: NSScroller.Style) {
        for scrollView in scrollViews() where scrollView.scrollerStyle != style {
            scrollView.scrollerStyle = style
        }
    }

    /// One real main-queue turn, the same turn-bounded hop as
    /// `PaneViewRenderTests.pump` and `awaitTerminalStatePublish`.
    func mainTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Runs layout and one main-queue turn per round until no view in the
    /// window is dirty. `maxRounds` is the hang guard.
    func settle() async -> SettleResult {
        root.resetCounts()
        window.resetCounts()
        for round in 1...Self.maxRounds {
            window.layoutIfNeeded()
            await mainTurn()
            if dirtyViews().isEmpty {
                return result(rounds: round)
            }
        }
        return result(rounds: Self.maxRounds + 1)
    }

    /// Runs main-queue turns, with layout, until `condition` holds.
    /// `maxTurns` is a hang guard.
    func pump(
        until condition: () -> Bool,
        maxTurns: Int = 400,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<maxTurns {
            window.layoutIfNeeded()
            if condition() { return }
            await mainTurn()
        }
        if !condition() {
            Issue.record("Timed out after \(maxTurns) main-queue turns", sourceLocation: sourceLocation)
        }
    }

    private func result(rounds: Int) -> SettleResult {
        SettleResult(
            rounds: rounds,
            rootPasses: root.passes,
            windowUpdateConstraintsCalls: window.updateConstraintsCalls,
            postNeedsUpdateConstraintsCalls: window.postNeedsUpdateConstraintsCalls,
            postNeedsLayoutCalls: window.postNeedsLayoutCalls,
            brokeLoop: window.brokeLoop,
            dirtyViews: dirtyViews().map { NSStringFromClass(type(of: $0)) }
        )
    }
}

// MARK: - Request budgets

extension LayoutConvergenceProbe {
    /// The request-volume verdict every probe ceiling test shares: true when
    /// `samples` is non-empty and a strict majority of them are at or under
    /// `ceiling`. On a loaded host one settle can pick up a burst of
    /// unrelated main-queue work and spike. Where a ceiling test has
    /// fail-before evidence (#0604, #0606, #0607), the pre-fix code was over
    /// on every sample, so a majority still fails it.
    static func mostlyWithin(_ samples: [Int], ceiling: Int) -> Bool {
        let over = samples.filter { $0 > ceiling }
        return !samples.isEmpty && over.count * 2 < samples.count
    }

    /// "k of n over C (max M): [samples]", for a ceiling test's failure message.
    static func budgetReport(_ samples: [Int], ceiling: Int) -> String {
        let over = samples.filter { $0 > ceiling }.count
        return "\(over) of \(samples.count) over \(ceiling) (max \(samples.max() ?? 0)): \(samples)"
    }
}

// MARK: - Controls

/// A deliberate layout-origin write whose measured width decides the width
/// it sets. SwiftUI damps this one itself (it settles in one round with a
/// handful of requests), so it is a calibration point, not the negative
/// control.
struct GeometryFeedbackLoopView: View {
    @State private var wide = false

    var body: some View {
        Color.red
            .frame(width: wide ? 200 : 400, height: 50)
            .onGeometryChange(for: Bool.self) { $0.size.width > 300 } action: { wide = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlainScrollViewControl: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(0..<40, id: \.self) { Text("row \($0)") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The negative control: an AppKit participant that re-dirties the window on
/// every pass, up to `budget` times. `layout()` marks it as needing update
/// constraints and `updateConstraints()` marks it as needing layout. It
/// carries 100 empty subviews so a window holding it has more views than a
/// short budget has passes.
final class ConstraintLoopNSView: NSView {
    private var remaining: Int

    init(budget: Int) {
        remaining = budget
        super.init(frame: .zero)
        for _ in 0..<100 {
            addSubview(NSView(frame: .zero))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateConstraints() {
        super.updateConstraints()
        if remaining > 0 { needsLayout = true }
    }

    override func layout() {
        super.layout()
        if remaining > 0 {
            remaining -= 1
            needsUpdateConstraints = true
        }
    }
}

struct ConstraintLoopControl: NSViewRepresentable {
    let budget: Int

    func makeNSView(context: Context) -> ConstraintLoopNSView {
        ConstraintLoopNSView(budget: budget)
    }

    func updateNSView(_ nsView: ConstraintLoopNSView, context: Context) {}
}
