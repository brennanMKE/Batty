// BackgroundCatalogsSettingsSection.swift

import SwiftUI

/// Settings → Appearance → Background Catalogs. Every model write starts from
/// a click or `.task`; `body` only reads.
struct BackgroundCatalogsSettingsSection: View {
    let hosted: HostedBackgroundsModel

    @AppStorage(SettingsPreference.backgroundCatalogsAutoCheckKey)
    private var autoCheck = SettingsPreference.defaultBackgroundCatalogsAutoCheck
    @State private var draft = ""
    @State private var addError: String?

    var body: some View {
        Section("Background Catalogs") {
            Toggle("Check background catalogs automatically", isOn: $autoCheck)
                .accessibilityIdentifier("background-catalogs.auto-check")
            Text("Batty checks each catalog at launch and once a day, unless automatic checks are off.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(hosted.catalogRows) { state in
                row(state)
            }
            addRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-catalogs.section")
        .task { await hosted.loadCatalogRows() }
    }

    private func row(_ state: HostedCatalogState) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: state.isBuiltIn ? String(localized: "Batty (built in)") : state.host)
                Text(verbatim: state.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                status(state)
                    .font(.caption)
                    .accessibilityIdentifier("background-catalogs.status")
            }
            Spacer()
            Button("Check Now") {
                Task { await hosted.refresh(state.url) }
            }
            .disabled(state.isChecking)
            .accessibilityIdentifier("background-catalogs.check-now")
            if !state.isBuiltIn {
                Button("Remove") {
                    Task { await hosted.removeCatalog(state.url) }
                }
                .accessibilityIdentifier("background-catalogs.remove")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-catalogs.row.\(state.url.absoluteString)")
    }

    @ViewBuilder
    private func status(_ state: HostedCatalogState) -> some View {
        let now = Date()
        if state.isChecking {
            Text("Checking…").foregroundStyle(.secondary)
        } else if let problem = state.problem {
            let message = BackgroundSetsView.message(for: problem)
            if let since = state.unreachableSince(now: now) {
                Text("Unreachable since \(since.formatted(date: .abbreviated, time: .omitted)). \(message)")
                    .foregroundStyle(.red)
            } else {
                Text(verbatim: message).foregroundStyle(.red)
            }
        } else if let checked = state.lastChecked {
            Text("Up to date · checked \(checked.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
                .foregroundStyle(.secondary)
        } else if state.isBuiltIn, !hosted.hasBrowsed {
            Text("Checked when you open Background Sets").foregroundStyle(.secondary)
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("https://…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("background-catalogs.url-field")
                Button("Add") {
                    let text = draft
                    Task {
                        switch await hosted.addCatalog(text) {
                        case .success:
                            draft = ""
                            addError = nil
                        case .failure(let refusal):
                            addError = refusal.message
                        }
                    }
                }
                .disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || hosted.isAddingCatalog
                        || hosted.userCatalogURLs.count >= BackgroundCatalogURLs.maxUserCatalogs
                )
                .accessibilityIdentifier("background-catalogs.add")
            }
            if let addError {
                Text(verbatim: addError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("background-catalogs.add-error")
            }
        }
    }
}
