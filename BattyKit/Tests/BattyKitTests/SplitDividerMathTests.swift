// SplitDividerMathTests.swift

import CoreGraphics
import Testing
@testable import BattyKit

/// Arithmetic-contract coverage for `SplitDividerMath.ratio`, the pure
/// function `DraggableSplitView` calls (#0338) with locations already
/// expressed in a stable `.named` space (see that type's doc comment in
/// `SplitContainerView.swift` for why the space must be stable — that's a
/// precondition these tests assume, not something they exercise).
///
/// These tests lock down: the ratio moves monotonically with a monotone
/// input location sequence, in both directions and both split
/// orientations; cross-axis pointer movement is a no-op; a zero-length
/// container returns the start ratio unchanged; and the exact fraction
/// computed from a translation. They do **not** guard the #0338
/// coordinate-space regression itself — `startRatio + translation /
/// containerLength` is identical arithmetic whether `translation` comes
/// from a stable space or the divider's old moving `.local` space (`value.
/// translation` is defined as `location - startLocation` in whatever space
/// the gesture reports), so the pre-fix code passes these same inputs
/// unchanged: an increasing sequence of hand-authored stable-space points
/// necessarily maps to an increasing sequence of ratios under either
/// formula. The actual jitter/snap-back is a within-gesture SwiftUI
/// runtime behavior (the coordinate space moving live as `onRatioChange`
/// re-places the divider) that only a real drag gesture — i.e. a UI-level
/// test, not a unit test — can observe.
struct SplitDividerMathTests {

    // MARK: - Horizontal (side-by-side panes, vertical divider, drag along x)

    @Test func horizontalDragRightIncreasesRatioMonotonically() {
        let start = CGPoint(x: 100, y: 50)
        let pointerPositions: [CGPoint] = [
            CGPoint(x: 100, y: 50),
            CGPoint(x: 110, y: 50),
            CGPoint(x: 125, y: 50),
            CGPoint(x: 140, y: 50),
            CGPoint(x: 160, y: 50),
        ]

        let ratios = pointerPositions.map { location in
            SplitDividerMath.ratio(
                direction: .horizontal,
                startRatio: 0.5,
                startLocation: start,
                currentLocation: location,
                containerLength: 400
            )
        }

        for (previous, next) in zip(ratios, ratios.dropFirst()) {
            #expect(next >= previous, "ratio must not move backward while dragging right: \(ratios)")
        }
        #expect(ratios.last! > ratios.first!)
    }

    @Test func horizontalDragLeftDecreasesRatioMonotonically() {
        let start = CGPoint(x: 200, y: 50)
        let pointerPositions: [CGPoint] = [
            CGPoint(x: 200, y: 50),
            CGPoint(x: 185, y: 50),
            CGPoint(x: 160, y: 50),
            CGPoint(x: 130, y: 50),
            CGPoint(x: 90, y: 50),
        ]

        let ratios = pointerPositions.map { location in
            SplitDividerMath.ratio(
                direction: .horizontal,
                startRatio: 0.5,
                startLocation: start,
                currentLocation: location,
                containerLength: 400
            )
        }

        for (previous, next) in zip(ratios, ratios.dropFirst()) {
            #expect(next <= previous, "ratio must not move backward while dragging left: \(ratios)")
        }
        #expect(ratios.last! < ratios.first!)
    }

    // MARK: - Vertical (stacked panes, horizontal divider, drag along y)

    @Test func verticalDragDownIncreasesRatioMonotonically() {
        let start = CGPoint(x: 50, y: 100)
        let pointerPositions: [CGPoint] = [
            CGPoint(x: 50, y: 100),
            CGPoint(x: 50, y: 115),
            CGPoint(x: 50, y: 140),
            CGPoint(x: 50, y: 170),
            CGPoint(x: 50, y: 210),
        ]

        let ratios = pointerPositions.map { location in
            SplitDividerMath.ratio(
                direction: .vertical,
                startRatio: 0.5,
                startLocation: start,
                currentLocation: location,
                containerLength: 300
            )
        }

        for (previous, next) in zip(ratios, ratios.dropFirst()) {
            #expect(next >= previous, "ratio must not move backward while dragging down: \(ratios)")
        }
        #expect(ratios.last! > ratios.first!)
    }

    @Test func verticalDragUpDecreasesRatioMonotonically() {
        let start = CGPoint(x: 50, y: 220)
        let pointerPositions: [CGPoint] = [
            CGPoint(x: 50, y: 220),
            CGPoint(x: 50, y: 200),
            CGPoint(x: 50, y: 170),
            CGPoint(x: 50, y: 130),
            CGPoint(x: 50, y: 80),
        ]

        let ratios = pointerPositions.map { location in
            SplitDividerMath.ratio(
                direction: .vertical,
                startRatio: 0.5,
                startLocation: start,
                currentLocation: location,
                containerLength: 300
            )
        }

        for (previous, next) in zip(ratios, ratios.dropFirst()) {
            #expect(next <= previous, "ratio must not move backward while dragging up: \(ratios)")
        }
        #expect(ratios.last! < ratios.first!)
    }

    // MARK: - Cross-axis movement must not affect the ratio

    @Test func horizontalDragIgnoresVerticalPointerMovement() {
        let start = CGPoint(x: 100, y: 50)
        // Pointer wanders vertically but never moves along the drag axis.
        let ratio = SplitDividerMath.ratio(
            direction: .horizontal,
            startRatio: 0.5,
            startLocation: start,
            currentLocation: CGPoint(x: 100, y: 300),
            containerLength: 400
        )
        #expect(ratio == 0.5)
    }

    // MARK: - Degenerate container length

    @Test func zeroContainerLengthReturnsStartRatioUnchanged() {
        let ratio = SplitDividerMath.ratio(
            direction: .horizontal,
            startRatio: 0.42,
            startLocation: CGPoint(x: 0, y: 0),
            currentLocation: CGPoint(x: 50, y: 0),
            containerLength: 0
        )
        #expect(ratio == 0.42)
    }

    // MARK: - Exact math

    @Test func ratioIsStartRatioPlusFractionOfContainerLength() {
        let ratio = SplitDividerMath.ratio(
            direction: .horizontal,
            startRatio: 0.5,
            startLocation: CGPoint(x: 100, y: 0),
            currentLocation: CGPoint(x: 140, y: 0),
            containerLength: 400
        )
        #expect(abs(ratio - 0.6) < 1e-9)
    }
}
