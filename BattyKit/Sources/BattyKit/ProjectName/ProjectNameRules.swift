// ProjectNameRules.swift

import Foundation

public struct ProjectNameRules: Codable, Sendable {
    public let rules: [Rule]
    public let priority: [String]

    public struct Rule: Codable, Sendable {
        public let id: String
        public let label: String
        public let detect: [String]
        public let extract: Extract
        public let fallback: String?
    }

    public struct Extract: Codable, Sendable {
        public let kind: String
        public let file: String?
        public let path: String?
        public let pattern: String?
        public let transform: String?
        public let stripExtension: Bool?
    }

    public static let bundled: ProjectNameRules = {
        let candidates: [Bundle] = [.module, .main]
        for bundle in candidates {
            if let url = bundle.url(forResource: "project-name-rules", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(ProjectNameRules.self, from: data) {
                return decoded
            }
        }
        return ProjectNameRules(rules: [], priority: [])
    }()
}
