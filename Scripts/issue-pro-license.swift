#!/usr/bin/env swift
import CryptoKit
import Darwin
import Foundation

struct Claims: Encodable {
    let id = UUID()
    let product = "wfolder"
    let edition = "pro"
    let licensee: String
}

struct License: Encodable {
    let payload: Data
    let signature: Data
}

let args = CommandLine.arguments
func usage() -> Never {
    fputs("Usage: swift Scripts/issue-pro-license.swift generate PRIVATE_KEY_PATH\n"
        + "       swift Scripts/issue-pro-license.swift issue PRIVATE_KEY_PATH LICENSEE OUTPUT_JSON\n", stderr)
    exit(2)
}

do {
    guard args.count >= 3 else { usage() }
    let keyURL = URL(fileURLWithPath: args[2])
    switch (args[1], args.count) {
    case ("generate", 3):
        let key = Curve25519.Signing.PrivateKey()
        let fd = keyURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) } ?? -1
        }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: key.rawRepresentation)
        try file.close()
        print(key.publicKey.rawRepresentation.base64EncodedString())
    case ("issue", 5):
        guard !args[3].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, args[3].count <= 160 else { usage() }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
        let encoder = JSONEncoder()
        let payload = try encoder.encode(Claims(licensee: args[3]))
        let license = try License(payload: payload, signature: key.signature(for: payload))
        try encoder.encode(license).write(to: URL(fileURLWithPath: args[4]), options: .withoutOverwriting)
    default: usage()
    }
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
