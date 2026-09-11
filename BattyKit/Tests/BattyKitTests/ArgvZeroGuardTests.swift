// ArgvZeroGuardTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ArgvZeroGuardTests {

    private let realExecutableName = "Batty"
    private let realExecutablePath = "/Applications/Batty.app/Contents/MacOS/Batty"

    @Test func exemptsTheGenuineLaunchServicesPath() {
        // A normal launch's argv[0] is the bundle's real, resolved executable
        // path — its basename ("Batty") is itself case-insensitively equal to
        // "batty", so this exemption (name matches the bundle's declared
        // executable name exactly) is what keeps the guard from refusing
        // every ordinary launch.
        #expect(!ArgvZeroGuard.isSpuriousCLIInvocation(
            argv0: realExecutablePath,
            executableName: realExecutableName
        ))
    }

    @Test func refusesTheBareLowercaseNameAShellWouldPass() {
        // Typing `batty` at a shell prompt passes argv[0] as exactly what
        // was typed — "batty" — not the resolved path, regardless of what
        // file case-insensitive PATH lookup actually found.
        #expect(ArgvZeroGuard.isSpuriousCLIInvocation(
            argv0: "batty",
            executableName: realExecutableName
        ))
    }

    @Test func refusesTheExactLowercaseFullPathEvenThoughItWouldEchoBackIdenticallyFromExecutablePath() {
        // This is the production scenario review round 1 (B1) found broken:
        // a stale `/usr/local/bin/batty` symlink, or a script hard-coding
        // `Contents/MacOS/batty`, execs this literal lowercase full path.
        // `Bundle.main.executablePath` performs no symlink resolution and no
        // case canonicalization, so it would echo this exact string back —
        // an `argv0 == canonicalExecutablePath` exemption (the earlier,
        // wrong design) would wrongly treat that as a genuine launch. The
        // bundle's declared executable name is `Batty` regardless of which
        // path or case was used to reach the binary, so comparing against it
        // instead still catches this.
        #expect(ArgvZeroGuard.isSpuriousCLIInvocation(
            argv0: "/Applications/Batty.app/Contents/MacOS/batty",
            executableName: realExecutableName
        ))
    }

    @Test func refusesWrongCasingsOfTheName() {
        for name in ["BATTY", "BaTTy"] {
            #expect(ArgvZeroGuard.isSpuriousCLIInvocation(
                argv0: name,
                executableName: realExecutableName
            ), "expected \(name) to be refused")
        }
    }

    @Test func exemptsTheBareExecutableNameTypedWithTheCorrectCase() {
        // Typing the app's real name ("Batty") at a shell, however unusual,
        // is not the `batty`/`Batty` collision this guard exists to catch —
        // it's an explicit, correctly-cased invocation of the real binary.
        #expect(!ArgvZeroGuard.isSpuriousCLIInvocation(
            argv0: "Batty",
            executableName: realExecutableName
        ))
    }

    @Test func ignoresUnrelatedNames() {
        #expect(!ArgvZeroGuard.isSpuriousCLIInvocation(
            argv0: "/usr/bin/zsh",
            executableName: realExecutableName
        ))
    }

    @Test func handlesNilAndEmptyArgv0() {
        #expect(!ArgvZeroGuard.isSpuriousCLIInvocation(argv0: nil, executableName: realExecutableName))
        #expect(!ArgvZeroGuard.isSpuriousCLIInvocation(argv0: "", executableName: realExecutableName))
    }

    @Test func refusesWhenExecutableNameIsUnavailable() {
        // If `CFBundleExecutable` ever comes back nil, fail closed (refuse)
        // rather than silently exempting every invocation.
        #expect(ArgvZeroGuard.isSpuriousCLIInvocation(argv0: "batty", executableName: nil))
    }

    @Test func refusalMessagePointsAtBothRealCLILocations() {
        // Structural, not a substring smoke test: the message's whole job is
        // telling the user where the real CLI actually lives, so it must
        // name both places `docs/batty-cli-install.md` describes — the
        // bundled binary and the opt-in symlink — not just claim to.
        #expect(ArgvZeroGuard.refusalMessage.contains("Contents/Resources/bin/batty"))
        #expect(ArgvZeroGuard.refusalMessage.contains("/usr/local/bin/batty"))
        #expect(!ArgvZeroGuard.refusalMessage.isEmpty)
    }

    @Test func enforceWritesAndTerminatesWhenTheInvocationIsSpurious() {
        var written: [String] = []
        var terminatedWith: [Int32] = []
        ArgvZeroGuard.enforce(
            argv0: "batty",
            executableName: realExecutableName,
            write: { written.append($0) },
            terminate: { terminatedWith.append($0) }
        )
        #expect(written == [ArgvZeroGuard.refusalMessage + "\n"])
        #expect(terminatedWith == [EXIT_FAILURE])
    }

    @Test func enforceDoesNothingForAGenuineLaunch() {
        var written: [String] = []
        var terminatedWith: [Int32] = []
        ArgvZeroGuard.enforce(
            argv0: realExecutablePath,
            executableName: realExecutableName,
            write: { written.append($0) },
            terminate: { terminatedWith.append($0) }
        )
        #expect(written.isEmpty)
        #expect(terminatedWith.isEmpty)
    }
}
