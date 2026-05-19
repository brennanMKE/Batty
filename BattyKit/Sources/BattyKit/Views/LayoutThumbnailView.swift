// LayoutThumbnailView.swift

import SwiftUI

struct LayoutThumbnailView: View {
    let layout: PaneLayout
    let isSelected: Bool
    let themeChrome: ThemeChrome?

    private var paneFill: Color {
        themeChrome?.windowBackground ?? Color(nsColor: .windowBackgroundColor)
    }

    private var accentColor: Color {
        themeChrome?.accent ?? .accentColor
    }

    private var borderColor: Color {
        (themeChrome?.chromeForeground ?? .primary).opacity(0.3)
    }

    private var dividerColor: Color {
        themeChrome?.divider ?? Color(nsColor: .separatorColor)
    }

    var body: some View {
        Canvas { context, size in
            let panes = layout.layoutPanes

            for pane in panes {
                let rect = CGRect(
                    x: pane.frame.minX * size.width,
                    y: pane.frame.minY * size.height,
                    width: pane.frame.width * size.width,
                    height: pane.frame.height * size.height
                )

                // Pane fill
                context.fill(Path(rect), with: .color(paneFill))

                // Primary pane accent tint
                if pane.isPrimary {
                    context.fill(Path(rect), with: .color(accentColor.opacity(0.10)))
                }

                // Interior divider lines on non-primary panes (leading/top edges only,
                // skip outer canvas edges to avoid double borders)
                if !pane.isPrimary {
                    let lineWidth: CGFloat = 0.5

                    // Leading vertical divider (skip if at canvas left edge)
                    if pane.frame.minX > 0.001 {
                        var line = Path()
                        line.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        line.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                        context.stroke(line, with: .color(dividerColor), lineWidth: lineWidth)
                    }

                    // Top horizontal divider (skip if at canvas top edge)
                    if pane.frame.minY > 0.001 {
                        var line = Path()
                        line.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        line.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                        context.stroke(line, with: .color(dividerColor), lineWidth: lineWidth)
                    }
                }
            }
        }
        .frame(width: 120, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? accentColor : Color.clear, lineWidth: 1.5)
        )
    }
}
