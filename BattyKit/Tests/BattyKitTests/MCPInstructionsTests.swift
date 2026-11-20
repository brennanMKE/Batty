// MCPInstructionsTests.swift

import BattyCLICore
import BattyXPCCore
import Foundation
import Testing
@testable import batty

struct MCPInstructionsTests {
    private func catalog(_ flags: FeatureFlags = MCPToolCatalogTests.flagOn) -> MCPToolCatalog {
        MCPToolCatalog(payload: CapabilitiesCommand.buildPayload(flags: flags))
    }

    @Test func everyHintResolvesInTheFlagOnCatalog() {
        #expect(MCPInstructions.applicableHints(catalog: catalog()) == MCPInstructions.hints)
    }

    @Test func everyBacktickedNameIsACatalogToolOrProperty() {
        let catalog = catalog()
        let text = MCPInstructions.text(environment: MCPServerTests.inBatty, catalog: catalog, cliName: "batty")
        let known = Set(catalog.tools.map(\.name)).union(catalog.tools.flatMap { $0.verb.inputSchema.properties.keys })
        let parts = text.components(separatedBy: "`")
        let tokens = stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
        let names = tokens.filter { $0 != "batty" && $0.range(of: "^[a-z][a-z_]*$", options: .regularExpression) != nil }
        #expect(!names.isEmpty)
        for name in names {
            #expect(known.contains(name), "unknown name \(name)")
        }
    }

    @Test func devServerHintNamesServerShare() {
        let text = MCPInstructions.text(environment: MCPServerTests.inBatty, catalog: catalog(), cliName: "batty")
        #expect(text.contains("`server_share`"))
        #expect(!text.contains("server_attach"))
    }

    @Test func serverHintsDropWithServersOff() {
        let flags = FeatureFlags(sharedProjectImages: true, agentIntegration: true, servers: false)
        let text = MCPInstructions.text(environment: MCPServerTests.inBatty, catalog: catalog(flags), cliName: "batty")
        #expect(!text.contains("server_"))
        #expect(text.contains("`pane_split`"))
        #expect(text.contains("`notify`"))
    }

    @Test func incompleteEnvironmentNamesTheProblemAndNoPane() {
        let env = [BattyContextEnvironmentKey.paneID.rawValue: MCPServerTests.paneID]
        let text = MCPInstructions.text(environment: env, catalog: catalog(), cliName: "batty")
        #expect(text.contains("incomplete"))
        #expect(text.contains("pass ids"))
        #expect(!text.contains("act on this Pane"))
    }

    @Test func instructionsStayUnder1500Characters() {
        let text = MCPInstructions.text(environment: MCPServerTests.inBatty, catalog: catalog(), cliName: "batty-beta")
        #expect(text.count < 1500, "\(text.count) characters")
    }
}
