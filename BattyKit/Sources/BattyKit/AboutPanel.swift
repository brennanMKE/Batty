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

        let creditsBody = String(localized: "about.credits.body",
            defaultValue: "\(appName) — a macOS terminal multiplexer\nBuilt on libghostty and SlidingTabs.\n\n\(copyright)",
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
