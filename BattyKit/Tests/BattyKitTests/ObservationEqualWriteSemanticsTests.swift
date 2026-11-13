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

private struct EquatablePoint: Equatable {
    var x = 0
}

@Observable
private final class EqualWriteSubject {
    var equatable = 1
    var reference = ReferencePayload()
    var optionalReference: ReferencePayload?
    var nonEquatable = NonEquatablePayload()
    var dictionary: [Int: Int] = [1: 1]
    var array: [Int] = [1, 2]
    var points: [EquatablePoint] = [EquatablePoint()]
    var optionalPoint: EquatablePoint? = EquatablePoint()
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

    @Test func inPlaceMutationsNotifyEvenWhenNothingChanges() {
        let subject = EqualWriteSubject()
        #expect(notifies(subject, read: { $0.dictionary }, write: { $0.dictionary[1] = 1 }))
        #expect(notifies(subject, read: { $0.array }, write: { $0.array.removeAll { _ in false } }))
        #expect(notifies(subject, read: { $0.points }, write: { $0.points[0].x = 0 }))
        #expect(notifies(subject, read: { $0.optionalPoint }, write: { $0.optionalPoint?.x = 0 }))
        #expect(subject.dictionary == [1: 1])
        #expect(subject.array == [1, 2])
        #expect(subject.points == [EquatablePoint()])
        #expect(subject.optionalPoint == EquatablePoint())
    }

    @Test func equalWholeCollectionAssignmentDoesNotNotify() {
        let subject = EqualWriteSubject()
        #expect(!notifies(subject, read: { $0.dictionary }, write: { $0.dictionary = [1: 1] }))
        #expect(!notifies(subject, read: { $0.array }, write: { $0.array = [1, 2] }))
        #expect(notifies(subject, read: { $0.dictionary }, write: { $0.dictionary = [1: 2] }))
    }
}
