// ProjectStartupTrustSheet.swift

import SwiftUI

struct ProjectStartupTrustSheet: View {
    let request: ProjectStartupTrustRequest
    let onChoose: (ProjectStartupChoice) -> Void
    let onCancel: () -> Void

    @State private var rememberApproval = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run \(request.rows.count) startup \(request.rows.count == 1 ? "command" : "commands") for \u{201C}\(request.projectName)\u{201D}?")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(request.rows.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                            Text("$ \(row.command)")
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("project-startup-trust.command.\(index + 1)")
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Toggle("Don\u{2019}t ask again until the commands change", isOn: $rememberApproval)
                .accessibilityIdentifier("project-startup-trust.remember")
            Text("Startup commands run like typed input. Batty asks the first time, and again if a command is edited.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Return is left unbound: the sheet can appear while the user is
            // typing in a terminal, and a stray Return must not run commands.
            DialogButtonRow(
                confirm: DialogButton("Run Commands", identifier: "project-startup-trust.run") {
                    onChoose(.run(rememberApproval: rememberApproval))
                },
                cancel: .cancel(identifier: "project-startup-trust.cancel", action: onCancel),
                alternative: DialogButton(
                    "Open Without Running",
                    identifier: "project-startup-trust.open-without-running"
                ) { onChoose(.openWithoutRunning) },
                confirmIsDefault: false
            )
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-startup-trust")
    }
}
