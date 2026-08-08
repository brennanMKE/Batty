// AboutPanel.swift

import AppKit
import Foundation

@MainActor
public enum AboutPanel {
    public static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let appName = info["CFBundleName"] as? String ?? "Batty"
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let copyright = info["NSHumanReadableCopyright"] as? String
            ?? String(localized: "© Batty contributors")

        // Plain text, not a clickable link — see THIRD-PARTY-LICENSES.md's
        // "Why not a clickable link from the About panel" for why
        // (NSWorkspace/.md-handler and batty:// scheme-routing pitfalls).
        let creditsBody = String(localized: "about.credits.body",
            defaultValue: "\(appName) — a macOS terminal multiplexer\nBuilt on libghostty and SlidingTabs.\nTerminal themes include entries from iTerm2-Color-Schemes, via libghostty.\n\nFull third-party license texts: Help menu → Batty Help → \"Third-Party Licenses\".\n\n\(copyright)",
            comment: "Multi-line credits string for the About panel.")
        let credits = NSAttributedString(
            string: creditsBody,
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName,
            .applicationVersion: version.isEmpty ? "1.0" : version,
            .version: build.isEmpty ? "1" : build,
            .credits: credits,
        ]
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
