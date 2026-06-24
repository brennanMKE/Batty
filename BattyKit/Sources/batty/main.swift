// main.swift

import Foundation
import BattyKit

let version = "0.1.0"
let usage = """
batty — Batty terminal multiplexer CLI

Usage: batty <command>

Commands:
  version   Print the CLI version

Run 'batty help' for more information.
"""

let args = CommandLine.arguments.dropFirst()

switch args.first {
case "version":
    print(version)
case "help", "--help", "-h":
    print(usage)
default:
    if let unknown = args.first {
        fputs("batty: unknown command '\(unknown)'\n", stderr)
        fputs(usage + "\n", stderr)
        exit(1)
    }
    print(usage)
}
