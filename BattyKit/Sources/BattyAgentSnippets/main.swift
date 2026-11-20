// main.swift

import BattyCLICore
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let check = arguments.contains("--check")
arguments.removeAll { $0 == "--check" }
guard arguments.count == 2, arguments[0] == "--output" else {
    fail("usage: BattyAgentSnippets --output <dir> [--check]", code: 2)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let files: [AgentMCPConfigSnippets.SiteFile]
do { files = try AgentMCPConfigSnippets.siteFiles() } catch { fail("render failed: \(error)", code: 1) }

let fileManager = FileManager.default
let existing = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
    .filter { name in
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
let expected = Set(files.map(\.name))
var drift = false

if !check {
    do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) } catch { fail("\(error)", code: 1) }
}
for file in files {
    let url = directory.appendingPathComponent(file.name)
    let data = Data(file.contents.utf8)
    let current = try? Data(contentsOf: url)
    if current == data {
        if !check { print("unchanged \(file.name)") }
        continue
    }
    if check {
        print("\(current == nil ? "missing" : "differs") \(file.name)")
        drift = true
    } else {
        do { try data.write(to: url, options: .atomic) } catch { fail("\(error)", code: 1) }
        print("wrote \(file.name)")
    }
}
for name in existing.subtracting(expected).sorted() {
    if check {
        print("extra \(name)")
        drift = true
    } else {
        do { try fileManager.removeItem(at: directory.appendingPathComponent(name)) } catch { fail("\(error)", code: 1) }
        print("removed \(name)")
    }
}
if drift { fail("run tools/build-agent-snippets.sh to regenerate", code: 1) }
