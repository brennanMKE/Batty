// ProjectNameResolver.swift

import Foundation

public enum ProjectNameResolver {
    public static let shared = Resolver(rules: ProjectNameRules.bundled)

    public final class Resolver: @unchecked Sendable {
        private let rules: ProjectNameRules
        private let rulesByID: [String: ProjectNameRules.Rule]

        public init(rules: ProjectNameRules) {
            self.rules = rules
            self.rulesByID = Dictionary(uniqueKeysWithValues: rules.rules.map { ($0.id, $0) })
        }

        /// Walks the rules in priority order, returning the first
        /// non-empty extraction result. Returns `nil` when no rule
        /// matches the directory's contents.
        public func resolve(at path: String) -> String? {
            guard !path.isEmpty else { return nil }
            let dir = URL(fileURLWithPath: path)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                return nil
            }
            let entrySet = Set(entries)
            let ordered = orderedRules
            for rule in ordered {
                guard let matchedFile = firstDetectMatch(rule: rule, entries: entries, entrySet: entrySet) else {
                    continue
                }
                if let name = extract(rule: rule, dir: dir, matchedFile: matchedFile), !name.isEmpty {
                    return name
                }
            }
            return nil
        }

        // MARK: - Internals

        private var orderedRules: [ProjectNameRules.Rule] {
            var seen = Set<String>()
            var ordered: [ProjectNameRules.Rule] = []
            for id in rules.priority {
                if let rule = rulesByID[id], !seen.contains(id) {
                    ordered.append(rule)
                    seen.insert(id)
                }
            }
            for rule in rules.rules where !seen.contains(rule.id) {
                ordered.append(rule)
            }
            return ordered
        }

        private func firstDetectMatch(
            rule: ProjectNameRules.Rule,
            entries: [String],
            entrySet: Set<String>
        ) -> String? {
            for pattern in rule.detect {
                if pattern.contains("*") {
                    if let match = entries.first(where: { matches(glob: pattern, name: $0) }) {
                        return match
                    }
                } else if entrySet.contains(pattern) {
                    return pattern
                }
            }
            return nil
        }

        private func matches(glob: String, name: String) -> Bool {
            // Single trailing or leading wildcard cases like *.xcodeproj or foo.*
            // suffice for the bundled ruleset. Avoid pulling in a glob library.
            let parts = glob.split(separator: "*", maxSplits: Int.max, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return name == glob }
            let prefix = parts[0]
            let suffix = parts[1]
            return name.hasPrefix(prefix) && name.hasSuffix(suffix) && name.count >= prefix.count + suffix.count
        }

        private func extract(
            rule: ProjectNameRules.Rule,
            dir: URL,
            matchedFile: String
        ) -> String? {
            switch rule.extract.kind {
            case "json":
                return extractJSON(rule: rule, dir: dir, matchedFile: matchedFile)
            case "regex", "toml-regex":
                return extractRegex(rule: rule, dir: dir, matchedFile: matchedFile)
            case "directory-basename-of-match":
                return extractBasename(rule: rule, matchedFile: matchedFile)
            default:
                return nil
            }
        }

        private func extractJSON(
            rule: ProjectNameRules.Rule,
            dir: URL,
            matchedFile: String
        ) -> String? {
            let fileName = rule.extract.file ?? matchedFile
            let url = dir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return nil }
            guard let path = rule.extract.path, !path.isEmpty else { return nil }
            return value(at: path, in: any)
        }

        private func value(at path: String, in object: Any) -> String? {
            var current: Any? = object
            for component in path.split(separator: ".").map(String.init) {
                guard let dict = current as? [String: Any] else { return nil }
                current = dict[component]
            }
            return current as? String
        }

        private func extractRegex(
            rule: ProjectNameRules.Rule,
            dir: URL,
            matchedFile: String
        ) -> String? {
            let fileName = rule.extract.file ?? matchedFile
            let resolvedFile: String
            if fileName.contains("*") {
                resolvedFile = matchedFile
            } else {
                resolvedFile = fileName
            }
            let url = dir.appendingPathComponent(resolvedFile)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            guard let pattern = rule.extract.pattern, !pattern.isEmpty else { return nil }
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            guard let match = regex.firstMatch(in: contents, range: range),
                  match.numberOfRanges >= 2,
                  let capture = Range(match.range(at: 1), in: contents)
            else { return nil }
            let raw = String(contents[capture])
            return applyTransform(rule.extract.transform, to: raw)
        }

        private func extractBasename(
            rule: ProjectNameRules.Rule,
            matchedFile: String
        ) -> String? {
            if rule.extract.stripExtension == true {
                return (matchedFile as NSString).deletingPathExtension
            }
            return matchedFile
        }

        private func applyTransform(_ transform: String?, to raw: String) -> String? {
            guard let transform else { return raw }
            switch transform {
            case "last-path-segment":
                if let last = raw.split(separator: "/").last {
                    return String(last)
                }
                return raw
            default:
                return raw
            }
        }
    }
}
