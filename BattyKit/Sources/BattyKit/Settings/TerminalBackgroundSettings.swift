// TerminalBackgroundSettings.swift

import Foundation

public enum BackgroundImageFit: String, CaseIterable, Sendable {
    case contain
    case cover
    case stretch
    case none
}

public enum BackgroundImagePosition: String, CaseIterable, Sendable {
    case topLeft = "top-left"
    case topCenter = "top-center"
    case topRight = "top-right"
    case centerLeft = "center-left"
    case center
    case centerRight = "center-right"
    case bottomLeft = "bottom-left"
    case bottomCenter = "bottom-center"
    case bottomRight = "bottom-right"
}

/// Normalizes in `init` because libghostty's diagnostics fail the whole
/// generated config on one bad value, taking font size, every `keybind` and
/// every `env` with it, and a control character in a path would inject a
/// config line.
public struct TerminalBackgroundSettings: Equatable, Sendable {
    public let imagePath: String?
    public let fit: BackgroundImageFit
    public let position: BackgroundImagePosition
    public let imageOpacity: Double
    public let terminalOpacity: Double

    public static let off = TerminalBackgroundSettings(imagePath: nil)

    public init(
        imagePath: String?,
        fit: BackgroundImageFit = .contain,
        position: BackgroundImagePosition = .center,
        imageOpacity: Double = 1,
        terminalOpacity: Double = 1
    ) {
        self.imagePath = imagePath.flatMap(Self.normalizedPath)
        self.fit = fit
        self.position = position
        // No upper clamp: libghostty gives image opacity above 1 a meaning
        // when `background-opacity` is below 1. Zero is a legal value.
        self.imageOpacity = imageOpacity.isFinite ? max(imageOpacity, 0) : 1
        self.terminalOpacity = terminalOpacity.isFinite ? min(max(terminalOpacity, 0), 1) : 1
    }

    /// A relative path would resolve against the temp directory holding the
    /// generated config, which is never what the user meant.
    private static func normalizedPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"),
              !expanded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return expanded
    }

    /// The image opacity a Pane's first image gets, as a tint, so a picture
    /// doesn't make the Pane unreadable on arrival.
    static let firstImageOpacity = 0.35

    /// The resolution chain. A non-nil override is complete, and `nil` follows
    /// the broader level.
    static func effective(pane: Self?, appWide: Self) -> Self {
        pane ?? appWide
    }

    func withImagePath(_ imagePath: String?) -> Self {
        Self(imagePath: imagePath, fit: fit, position: position, imageOpacity: imageOpacity, terminalOpacity: terminalOpacity)
    }

    func withFit(_ fit: BackgroundImageFit) -> Self {
        Self(imagePath: imagePath, fit: fit, position: position, imageOpacity: imageOpacity, terminalOpacity: terminalOpacity)
    }

    func withPosition(_ position: BackgroundImagePosition) -> Self {
        Self(imagePath: imagePath, fit: fit, position: position, imageOpacity: imageOpacity, terminalOpacity: terminalOpacity)
    }

    func withImageOpacity(_ imageOpacity: Double) -> Self {
        Self(imagePath: imagePath, fit: fit, position: position, imageOpacity: imageOpacity, terminalOpacity: terminalOpacity)
    }

    func withTerminalOpacity(_ terminalOpacity: Double) -> Self {
        Self(imagePath: imagePath, fit: fit, position: position, imageOpacity: imageOpacity, terminalOpacity: terminalOpacity)
    }

    /// Replacing an image keeps its opacity. Only a first image gets the tint.
    func pickingImage(path: String) -> Self {
        let picked = withImagePath(path)
        return imagePath == nil ? picked.withImageOpacity(Self.firstImageOpacity) : picked
    }
}
