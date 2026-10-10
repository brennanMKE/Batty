// StatusBadge.swift

import SwiftUI

/// A compact, single-line status tag: tinted translucent fill, tinted text,
/// 6-point corner radius. `lineLimit(1)` plus `fixedSize` keep it from ever
/// wrapping into a tall shape; callers that may be narrower than the badge
/// choose between layouts (`ViewThatFits`) rather than squeezing it.
struct StatusBadge: View {
    let text: String
    var systemImage: String?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)))
    }
}
