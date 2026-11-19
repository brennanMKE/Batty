// ServerStatSparkline.swift

import SwiftUI

/// A small line chart of one stats series. No Swift Charts: a `Path` over
/// the pure `points(values:in:)` normalizer.
struct ServerStatSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let points = Self.points(values: values, in: CGRect(origin: .zero, size: proxy.size))
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(Color.accentColor, lineWidth: 1.25)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Maps `values` left to right across `rect`, the smallest at the bottom
    /// and the largest at the top. A flat series sits on the midline; fewer
    /// than two samples draw nothing.
    static func points(values: [Double], in rect: CGRect) -> [CGPoint] {
        guard values.count >= 2, rect.width > 0, rect.height > 0 else { return [] }
        let low = values.min()!, high = values.max()!
        let step = rect.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let fraction = high > low ? (value - low) / (high - low) : 0.5
            return CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(fraction) * rect.height)
        }
    }
}
