// ShellCommandJoinerTests.swift

import BattyCLICore
import Testing

struct ShellCommandJoinerTests {
    @Test func quotesSpacesAndSingleQuotes() {
        #expect(ShellCommandJoiner.join(["echo", "a b", "it's"]) == #"echo 'a b' 'it'\''s'"#)
        #expect(ShellCommandJoiner.quote("") == "''")
    }

    @Test func leavesSafeWordsBare() {
        #expect(ShellCommandJoiner.join(["go", "run", "./cmd/site", "-addr=:8083"]) == "go run ./cmd/site -addr=:8083")
    }
}
