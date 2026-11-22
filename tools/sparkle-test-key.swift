// sparkle-test-key.swift
//
// Throwaway Ed25519 keys for tools/run-sparkle-update-vm.sh (#0715), made
// without the Keychain: Sparkle's key generator always stores what it makes
// in the Keychain, so this writes the key to a file instead, in the format
// `sign_update --ed-key-file` reads (base64 of the 32-byte seed, the same as
// Sparkle's own key export writes for a Sparkle 2 key).
//
//   xcrun swift tools/sparkle-test-key.swift generate <dir>
//       writes <dir>/ed25519.key (mode 0600) and <dir>/ed25519.pub, prints
//       the base64 public key
//   xcrun swift tools/sparkle-test-key.swift verify --public <b64> --signature <b64> <file>
//       exits 0 when the signature over <file> is valid
//   xcrun swift tools/sparkle-test-key.swift selftest

import CryptoKit
import Foundation

func die(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func generate(dir: URL) throws -> String {
    let key = Curve25519.Signing.PrivateKey()
    let keyURL = dir.appendingPathComponent("ed25519.key")
    let pubURL = dir.appendingPathComponent("ed25519.pub")
    let seed = key.rawRepresentation.base64EncodedString()
    FileManager.default.createFile(atPath: keyURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    try Data(seed.utf8).write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    try Data((pub + "\n").utf8).write(to: pubURL)
    return pub
}

func verify(publicKey: String, signature: String, file: URL) -> Bool {
    guard let pubData = Data(base64Encoded: publicKey),
          let sigData = Data(base64Encoded: signature),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
          let data = try? Data(contentsOf: file)
    else { return false }
    return key.isValidSignature(sigData, for: data)
}

func selftest() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sparkle-test-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pub = try generate(dir: dir)
    let keyURL = dir.appendingPathComponent("ed25519.key")
    let seedText = try String(contentsOf: keyURL, encoding: .utf8)
    guard seedText.count == 44, let seed = Data(base64Encoded: seedText), seed.count == 32 else {
        die("FAIL key_file_is_44_base64_chars_of_a_32_byte_seed", 1)
    }
    let mode = (try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? NSNumber)?.intValue
    guard mode == 0o600 else { die("FAIL key_file_mode_0600 (got \(String(mode ?? -1, radix: 8)))", 1) }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    guard key.publicKey.rawRepresentation.base64EncodedString() == pub else { die("FAIL public_key_matches_seed", 1) }
    let file = dir.appendingPathComponent("payload.bin")
    try Data("sparkle payload".utf8).write(to: file)
    let sig = try key.signature(for: Data(contentsOf: file)).base64EncodedString()
    guard verify(publicKey: pub, signature: sig, file: file) else { die("FAIL valid_signature_verifies", 1) }
    try Data("sparkle payload!".utf8).write(to: file)
    guard !verify(publicKey: pub, signature: sig, file: file) else { die("FAIL tampered_file_fails", 1) }
    print("sparkle-test-key selftest: 5 checks passed")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { die("usage: sparkle-test-key.swift generate <dir> | verify --public <b64> --signature <b64> <file> | selftest") }
args.removeFirst()
switch command {
case "generate":
    guard args.count == 1 else { die("usage: generate <dir>") }
    do { print(try generate(dir: URL(fileURLWithPath: args[0]))) } catch { die("generate: \(error)", 1) }
case "verify":
    var pub: String?, sig: String?, file: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--public" where i + 1 < args.count: pub = args[i + 1]; i += 2
        case "--signature" where i + 1 < args.count: sig = args[i + 1]; i += 2
        default: file = args[i]; i += 1
        }
    }
    guard let pub, let sig, let file else { die("usage: verify --public <b64> --signature <b64> <file>") }
    if verify(publicKey: pub, signature: sig, file: URL(fileURLWithPath: file)) {
        print("signature OK")
    } else {
        die("signature INVALID", 1)
    }
case "selftest":
    do { try selftest() } catch { die("selftest: \(error)", 1) }
default:
    die("unknown command \(command)")
}
