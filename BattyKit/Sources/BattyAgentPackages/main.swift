// main.swift

import BattyCLICore
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = "usage: BattyAgentPackages --skill <SKILL.md> --version <X.Y.Z> --output <dir>"
var options: [String: String] = [:]
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let key = arguments.removeFirst()
    guard ["--skill", "--version", "--output"].contains(key), !arguments.isEmpty, options[key] == nil else { fail(usage, code: 2) }
    options[key] = arguments.removeFirst()
}
guard let skillPath = options["--skill"], let version = options["--version"], let outputPath = options["--output"] else { fail(usage, code: 2) }
guard version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil else { fail("bad version: \(version)", code: 2) }

let fileManager = FileManager.default
let output = URL(fileURLWithPath: outputPath, isDirectory: true)
let skill: Data
do { skill = try Data(contentsOf: URL(fileURLWithPath: skillPath)) } catch { fail("cannot read \(skillPath): \(error)", code: 1) }

// Refuse to replace a folder this tool didn't make.
if let entries = try? fileManager.contentsOfDirectory(atPath: output.path), !entries.isEmpty,
   !fileManager.fileExists(atPath: output.appendingPathComponent(".claude-plugin/marketplace.json").path) {
    fail("\(outputPath) is not empty and holds no .claude-plugin/marketplace.json; refusing to replace it", code: 1)
}

do {
    var files = try AgentPluginTree.publicFiles(version: version, skill: skill)
    files.append(AgentPluginTree.File(path: "README.md", data: Data(AgentPluginTree.publicReadme(version: version).utf8)))
    if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
    for file in files {
        let url = output.appendingPathComponent(file.path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.data.write(to: url, options: .atomic)
        print("wrote \(url.path)")
    }
} catch {
    fail("\(error)", code: 1)
}
