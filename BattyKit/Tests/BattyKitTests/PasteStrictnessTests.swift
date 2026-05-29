// PasteStrictnessTests.swift

import Foundation
import Testing
@testable import BattyKit

struct PasteStrictnessTests {

    @Test func neverNeverConfirms() {
        #expect(PasteStrictness.never.shouldConfirm("rm -rf /\nsudo dd") == false)
    }

    @Test func alwaysConfirmsAnyMultiline() {
        #expect(PasteStrictness.alwaysOnMultiline.shouldConfirm("echo hi\necho bye") == true)
        #expect(PasteStrictness.alwaysOnMultiline.shouldConfirm("echo hi") == false)
    }

    @Test func metacharsConfirmsOnDangerousNewlinedPayloads() {
        #expect(PasteStrictness.onShellMetacharacters.shouldConfirm("echo hi\nrm something") == true)
        #expect(PasteStrictness.onShellMetacharacters.shouldConfirm("ls\nls -la") == false)
        #expect(PasteStrictness.onShellMetacharacters.shouldConfirm("a && b\necho c") == true)
        #expect(PasteStrictness.onShellMetacharacters.shouldConfirm("rm something") == false)
    }
}
