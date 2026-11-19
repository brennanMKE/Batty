// StaticServerFixture.swift

import Foundation

/// A temp directory laid out for the static server tests. `remove()` deletes
/// it and its sibling outside directory.
nonisolated struct StaticServerFixture {
    let base: URL
    let root: URL
    let outside: URL

    init() throws {
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("static-server-\(UUID().uuidString)")
        root = base.appendingPathComponent("site")
        outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("<html><body><h1>index</h1></body></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("<p>page</p>".utf8).write(to: root.appendingPathComponent("sub/page.html"))
        try Data("doc".utf8).write(to: root.appendingPathComponent("docs/a.txt"))
        try Data("SECRET=1".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("[core]".utf8).write(to: root.appendingPathComponent(".git/config"))
        try Data("outside secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("inside-link.html").path, withDestinationPath: "sub/page.html")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("outside-link.txt").path, withDestinationPath: outside.appendingPathComponent("secret.txt").path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("outside-dir").path, withDestinationPath: outside.path)
        mkfifo(root.appendingPathComponent("pipe").path, 0o600)
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("site-link").path, withDestinationPath: root.path)
    }

    var symlinkedRoot: URL { base.appendingPathComponent("site-link") }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
