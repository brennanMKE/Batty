// Render.swift

import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Colors from website/css/style.css :root.
enum Brand {
    static let bg = NSColor(srgbRed: 0x0d / 255, green: 0x0b / 255, blue: 0x14 / 255, alpha: 1)
    static let card = NSColor(srgbRed: 0x16 / 255, green: 0x13 / 255, blue: 0x20 / 255, alpha: 0.9)
    static let fg = NSColor(srgbRed: 0xf4 / 255, green: 0xf1 / 255, blue: 0xff / 255, alpha: 1)
    static let muted = NSColor(srgbRed: 0x9b / 255, green: 0x94 / 255, blue: 0xb8 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 0xb1 / 255, green: 0x8c / 255, blue: 0xff / 255, alpha: 1)
    static let accentStrong = NSColor(srgbRed: 0xd4 / 255, green: 0xbc / 255, blue: 0xff / 255, alpha: 1)
}

struct Sprite {
    var image: CGImage
    var width: CGFloat
    var height: CGFloat
}

enum Canvas {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo
        )!
    }

    /// Runs AppKit drawing against a bitmap, bottom-left origin.
    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}

func systemFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func attributed(_ text: String, font: NSFont, color: NSColor, lineSpacing: CGFloat = 0) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    style.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
}

func measure(_ string: NSAttributedString, maxWidth: CGFloat) -> CGSize {
    let rect = string.boundingRect(with: CGSize(width: maxWidth, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return CGSize(width: ceil(rect.width), height: ceil(rect.height))
}

/// Every size below is for a 1920-wide frame and scales with `scale`.
struct Renderer {
    var scale: CGFloat

    private func px(_ value: CGFloat) -> CGFloat { value * scale }

    func callout(_ callout: Callout) -> Sprite {
        let pad = CGSize(width: px(30), height: px(22))
        let mainFont = systemFont(px(58), .heavy)
        let detailFont = systemFont(px(32), .regular)
        let keyFont = NSFont.monospacedSystemFont(ofSize: px(40), weight: .bold)
        let keyPad = px(16), keyGap = px(10), keyHeight = px(66)
        let maxWidth = px(1180)

        let keys = callout.keys ?? []
        let keySizes = keys.map { measure(attributed($0, font: keyFont, color: Brand.accentStrong), maxWidth: 1000) }
        let chipWidths = keySizes.map { max(keyHeight, $0.width + keyPad * 2) }
        let chipsWidth = chipWidths.reduce(0, +) + keyGap * CGFloat(max(0, keys.count - 1))
        let chipsBlock = keys.isEmpty ? 0 : chipsWidth + px(22)

        let mainString = attributed(callout.text, font: mainFont, color: Brand.fg)
        let mainSize = measure(mainString, maxWidth: maxWidth - chipsBlock)
        let detailString = callout.detail.map { attributed($0, font: detailFont, color: Brand.muted, lineSpacing: px(4)) }
        let detailSize = detailString.map { measure($0, maxWidth: maxWidth) } ?? .zero

        let textWidth = max(mainSize.width + chipsBlock, detailSize.width)
        let rowHeight = max(mainSize.height, keys.isEmpty ? 0 : keyHeight)
        let width = ceil(pad.width * 2 + textWidth + px(8))
        let height = ceil(pad.height * 2 + rowHeight + (detailString == nil ? 0 : px(10) + detailSize.height))

        let image = Canvas.draw(width: Int(width), height: Int(height)) { ctx in
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: px(1.5), dy: px(1.5)), xRadius: px(18), yRadius: px(18))
            Brand.card.setFill()
            path.fill()
            ctx.saveGState()
            path.addClip()
            Brand.accent.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: px(8), height: height)).fill()
            ctx.restoreGState()
            Brand.accent.withAlphaComponent(0.5).setStroke()
            path.lineWidth = px(2)
            path.stroke()

            var x = pad.width + px(8)
            let rowTop = height - pad.height
            let rowBottom = rowTop - rowHeight
            for (index, key) in keys.enumerated() {
                let chip = CGRect(x: x, y: rowBottom + (rowHeight - keyHeight) / 2, width: chipWidths[index], height: keyHeight)
                let chipPath = NSBezierPath(roundedRect: chip, xRadius: px(12), yRadius: px(12))
                Brand.accent.withAlphaComponent(0.2).setFill()
                chipPath.fill()
                Brand.accent.setStroke()
                chipPath.lineWidth = px(2)
                chipPath.stroke()
                let size = keySizes[index]
                attributed(key, font: keyFont, color: Brand.accentStrong)
                    .draw(at: CGPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2))
                x += chipWidths[index] + keyGap
            }
            if !keys.isEmpty { x += px(12) }
            mainString.draw(with: CGRect(x: x, y: rowBottom + (rowHeight - mainSize.height) / 2, width: maxWidth - chipsBlock + px(4), height: mainSize.height + px(4)), options: [.usesLineFragmentOrigin, .usesFontLeading])
            if let detailString {
                detailString.draw(with: CGRect(x: pad.width + px(8), y: pad.height, width: maxWidth + px(4), height: detailSize.height + px(4)), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
        return Sprite(image: image, width: width, height: height)
    }

    func badge(_ text: String) -> Sprite {
        let font = systemFont(px(30), .bold)
        let string = attributed(text, font: font, color: Brand.bg)
        let size = measure(string, maxWidth: 1000)
        let width = ceil(size.width + px(40)), height = ceil(size.height + px(18))
        let image = Canvas.draw(width: Int(width), height: Int(height)) { _ in
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), xRadius: height / 2, yRadius: height / 2)
            Brand.accentStrong.setFill()
            path.fill()
            string.draw(at: CGPoint(x: px(20), y: (height - size.height) / 2))
        }
        return Sprite(image: image, width: width, height: height)
    }

    func card(title: String, subtitle: String?, size: CGSize) -> CGImage {
        Canvas.draw(width: Int(size.width), height: Int(size.height)) { ctx in
            Brand.bg.setFill()
            NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            let wordmark = attributed("BATTY", font: systemFont(px(30), .heavy), color: Brand.accent)
            wordmark.draw(at: CGPoint(x: px(90), y: size.height - px(110)))

            let titleString = attributed(title, font: systemFont(px(150), .heavy), color: Brand.accentStrong)
            let titleSize = measure(titleString, maxWidth: size.width - px(300))
            let subString = subtitle.map { attributed($0, font: systemFont(px(54), .semibold), color: Brand.muted) }
            let subSize = subString.map { measure($0, maxWidth: size.width - px(300)) } ?? .zero
            let block = titleSize.height + (subString == nil ? 0 : px(34) + subSize.height)
            let top = size.height / 2 + block / 2
            let x = (size.width - max(titleSize.width, subSize.width)) / 2
            titleString.draw(with: CGRect(x: x, y: top - titleSize.height, width: titleSize.width + px(6), height: titleSize.height + px(6)), options: [.usesLineFragmentOrigin, .usesFontLeading])
            Brand.accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: top - titleSize.height - px(20), width: px(140), height: px(6)), xRadius: px(3), yRadius: px(3)).fill()
            if let subString {
                subString.draw(with: CGRect(x: x, y: top - titleSize.height - px(34) - subSize.height, width: subSize.width + px(6), height: subSize.height + px(6)), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            _ = ctx
        }
    }
}
