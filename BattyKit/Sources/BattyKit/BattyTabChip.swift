// BattyTabChip.swift

import SwiftUI

/// Tab chip used inside `SlidingTabBar`. Mirrors `DefaultTabChip`'s
/// look (unseen dot, active highlight, hover-or-active close button)
/// but **does not** use `.fixedSize(horizontal: true)` on the title
/// text, so the chip respects an outer `.frame(maxWidth:)` constraint.
/// Middle-truncation kicks in inside the chip when the parent's
/// allocated width is narrower than the natural text width.
public struct BattyTabChip: View {

    private let title: String
    private let isActive: Bool
    private let hasUnseen: Bool
    private let onClose: (() -> Void)?

    @State private var isHovered: Bool = false

    private var showsUnseenDot: Bool { hasUnseen && !isActive }

    public init(
        title: String,
        isActive: Bool,
        hasUnseen: Bool = false,
        onClose: (() -> Void)? = nil
    ) {
        self.title = title
        self.isActive = isActive
        self.hasUnseen = hasUnseen
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if showsUnseenDot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                } else {
                    Color.clear.frame(width: 6, height: 6)
                }
            }

            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onClose {
                ZStack {
                    if isHovered || isActive {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 14, height: 14)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
