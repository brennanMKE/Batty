// ProjectRecencyTests.swift

import Foundation
import Testing
@testable import BattyKit

private func project(_ name: String, _ opened: TimeInterval? = nil) -> Project {
    Project(name: name, rootPath: "/tmp/\(name)", lastOpenedAt: opened.map(Date.init(timeIntervalSince1970:)))
}

private func names(_ projects: [Project]) -> [String] { projects.map(\.name) }

struct ProjectRecencyTests {
    @Test func mostRecentFirstThenNeverOpenedInStoreOrder() {
        let a = project("A", 100), b = project("B"), c = project("C", 200)
        #expect(names(ProjectRecency.ranked([a, b, c], openProjectIDs: [])) == ["C", "A", "B"])
    }

    @Test func neverOpenedProjectsKeepStoreOrder() {
        let a = project("A"), b = project("B"), c = project("C")
        #expect(names(ProjectRecency.ranked([a, b, c], openProjectIDs: [])) == ["A", "B", "C"])
        let opened = project("B", 10)
        #expect(names(ProjectRecency.ranked([a, opened, c], openProjectIDs: [])) == ["B", "A", "C"])
    }

    @Test func equalDatesKeepStoreOrder() {
        let a = project("A", 100), b = project("B", 200), c = project("C", 100)
        #expect(names(ProjectRecency.ranked([a, b, c], openProjectIDs: [])) == ["B", "A", "C"])
        #expect(names(ProjectRecency.ranked([c, a, b], openProjectIDs: [])) == ["B", "C", "A"])
    }

    @Test func lastSinksOpenProjectsKeepingRecencyAmongThem() {
        let a = project("A", 100), b = project("B", 200), c = project("C", 300)
        #expect(names(ProjectRecency.ranked([a, b, c], openProjectIDs: [c.id], placement: .last)) == ["B", "A", "C"])
        #expect(names(ProjectRecency.ranked([a, b, c], openProjectIDs: [c.id, b.id], placement: .last)) == ["A", "C", "B"])
    }

    @Test func lastIsTheDefault() {
        let a = project("A", 100), b = project("B", 200)
        #expect(ProjectRecency.defaultPlacement == .last)
        #expect(names(ProjectRecency.ranked([a, b], openProjectIDs: [b.id])) == ["A", "B"])
    }

    @Test func inPlaceIgnoresOpenProjects() {
        let a = project("A", 100), b = project("B", 200), c = project("C", 300)
        #expect(names(ProjectRecency.ranked([a, b, c], openProjectIDs: [c.id], placement: .inPlace)) == ["C", "B", "A"])
    }

    @Test func firstRaisesOpenProjects() {
        let a = project("A", 100), b = project("B", 200), c = project("C", 300)
        #expect(names(ProjectRecency.ranked([a, b, c], openProjectIDs: [c.id], placement: .first)) == ["C", "B", "A"])
        #expect(names(ProjectRecency.ranked([a, b, c], openProjectIDs: [a.id], placement: .first)) == ["A", "C", "B"])
    }

    @Test func anOpenIdThatMatchesNothingIsIgnored() {
        let a = project("A", 100), b = project("B", 200)
        #expect(names(ProjectRecency.ranked([a, b], openProjectIDs: [UUID()])) == ["B", "A"])
    }

    @Test(arguments: [ProjectRecency.OpenPlacement.last, .inPlace, .first])
    func theResultIsAPermutation(placement: ProjectRecency.OpenPlacement) {
        let projects = [project("A", 5), project("B"), project("C", 5), project("D", 9), project("E")]
        let ranked = ProjectRecency.ranked(projects, openProjectIDs: [projects[1].id, projects[3].id], placement: placement)
        #expect(ranked.count == projects.count)
        #expect(Set(ranked.map(\.id)) == Set(projects.map(\.id)))
    }

    @Test func anEmptyListRanksToEmpty() {
        #expect(ProjectRecency.ranked([], openProjectIDs: []).isEmpty)
    }
}
