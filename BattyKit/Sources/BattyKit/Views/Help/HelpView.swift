// HelpView.swift

import SwiftUI

public struct HelpView: View {
    @State private var selection: HelpSection.ID = HelpCatalog.sections.first!.id
    @State private var contentCache: [String: Result<String, Error>] = [:]

    public init() {}

    public var body: some View {
        NavigationSplitView {
            HelpSidebarView(selection: $selection)
        } detail: {
            detail
        }
        .task(id: selection) {
            await loadIfNeeded(selection)
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if let result = contentCache[selection] {
                switch result {
                case .success(let text):
                    HelpSuccessPaneView(text: text)
                case .failure(let error):
                    HelpErrorPaneView(
                        error: error,
                        sectionTitle: sectionTitle(for: selection)
                    )
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 480, ideal: 540)
    }

    private func sectionTitle(for id: HelpSection.ID) -> String {
        HelpCatalog.sections.first(where: { $0.id == id })?.title ?? id
    }

    private func loadIfNeeded(_ id: HelpSection.ID) async {
        if contentCache[id] != nil { return }
        guard let section = HelpCatalog.sections.first(where: { $0.id == id }) else { return }
        contentCache[id] = readMarkdown(for: section)
    }

    private func readMarkdown(for section: HelpSection) -> Result<String, Error> {
        guard let url = Bundle.module.url(
            forResource: section.resourceName,
            withExtension: "md",
            subdirectory: "Help"
        ) else {
            return .failure(HelpLoadError.resourceMissing(section.resourceName))
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return .success(text)
        } catch {
            return .failure(error)
        }
    }
}
