// ProjectStartupTrustSheet.swift

import SwiftUI

struct ProjectStartupTrustSheet: View {
    let request: ProjectStartupTrustRequest
    let onChoose: (ProjectStartupChoice) -> Void

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
            HStack {
                Spacer()
                Button("Open Without Running") { onChoose(.openWithoutRunning) }
                    .accessibilityIdentifier("project-startup-trust.open-without-running")
                Button("Run Commands") { onChoose(.run(rememberApproval: rememberApproval)) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("project-startup-trust.run")
            }
            Text("Startup commands run like typed input. Batty asks the first time, and again if a command is edited.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-startup-trust")
    }
}
