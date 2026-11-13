// ObservationEqualWriteSemanticsTests.swift

import Foundation
import Observation
import Testing

private nonisolated final class WriteNotifiedFlag: @unchecked Sendable {
    var fired = false
}

private final class ReferencePayload {}

private struct NonEquatablePayload {
    var value = 0
}

@Observable
private final class EqualWriteSubject {
    var equatable = 1
    var reference = ReferencePayload()
    var optionalReference: ReferencePayload?
    var nonEquatable = NonEquatablePayload()
}

/// Pins the `@Observable` equal-write behaviour that
/// `docs/swiftui-observation-rules.md` ("Observation semantics and dependency
/// granularity") states, so a toolchain change that alters it fails here.
@MainActor
struct ObservationEqualWriteSemanticsTests {

    private func notifies<Value>(
        _ subject: EqualWriteSubject,
        read: @escaping (EqualWriteSubject) -> Value,
        write: (EqualWriteSubject) -> Void
    ) -> Bool {
        let flag = WriteNotifiedFlag()
        withObservationTracking { _ = read(subject) } onChange: { flag.fired = true }
        write(subject)
        return flag.fired
    }

    @Test func equalWriteToEquatablePropertyDoesNotNotify() {
        let subject = EqualWriteSubject()
        #expect(!notifies(subject, read: { $0.equatable }, write: { $0.equatable = 1 }))
        #expect(notifies(subject, read: { $0.equatable }, write: { $0.equatable = 2 }))
    }

    @Test func reassigningSameInstanceToClassReferenceDoesNotNotify() {
        let subject = EqualWriteSubject()
        let same = subject.reference
        #expect(!notifies(subject, read: { $0.reference }, write: { $0.reference = same }))
        #expect(notifies(subject, read: { $0.reference }, write: { $0.reference = ReferencePayload() }))
    }

    @Test func nonEquatableStructNotifiesOnEveryWrite() {
        let subject = EqualWriteSubject()
        let same = subject.nonEquatable
        #expect(notifies(subject, read: { $0.nonEquatable }, write: { $0.nonEquatable = same }))
    }

    @Test func nilToNilOnOptionalClassReferenceNotifies() {
        let subject = EqualWriteSubject()
        #expect(notifies(subject, read: { $0.optionalReference }, write: { $0.optionalReference = nil }))
    }
}
