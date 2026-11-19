// WebPreviewPaneView.swift

import AppKit
import SwiftUI

/// A Web Preview Pane (#0649). Reads `WebPreviewPaneContent`; the buttons
/// and the web view's click callback are the only writes.
struct WebPreviewPaneView: View {
    let content: WebPreviewPaneContent
    let paneID: UUID
    @Environment(\.appStateStore) private var appStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            page
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("web-preview.\(paneID.uuidString)")
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { content.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!content.canGoBack)
                .help("Back")
                .accessibilityIdentifier("web-preview-back")
            Button { content.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!content.canGoForward)
                .help("Forward")
                .accessibilityIdentifier("web-preview-forward")
            Button { content.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
                .accessibilityIdentifier("web-preview-reload")
            Text(content.url.absoluteString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("web-preview-url")
            Button("Open in Browser") { content.openInBrowser() }
                .accessibilityIdentifier("web-preview-open-browser")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var page: some View {
        if let error = content.lastError {
            VStack(spacing: 10) {
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("web-preview-error")
                Button("Reload") { content.reload() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if content.isActive, let view = content.engineView {
            let store = appStore
            let id = paneID
            WebPreviewHost(view: view, onMouseDown: { store?.focusPane(id: id) })
                .id(ObjectIdentifier(view))
                .accessibilityIdentifier("web-preview-page")
        } else {
            Color.clear
        }
    }
}

/// Hosts the model-owned web view. `dismantleNSView` does nothing: the
/// content owns the view and removes it in `tearDown`.
private struct WebPreviewHost: NSViewRepresentable {
    let view: NSView
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        (view as? BattyPreviewWebView)?.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? BattyPreviewWebView)?.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {}
}
