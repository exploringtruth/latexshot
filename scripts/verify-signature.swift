#!/usr/bin/env swift
import Foundation
import CryptoKit

// Arguments contain public material only. Never accepts a private key.
guard CommandLine.arguments.count == 4,
      let keyBytes = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Usage: verify-signature.swift ARCHIVE PUBLIC_KEY SIGNATURE\n", stderr)
    exit(1)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("Archive signature does not match the embedded public key\n", stderr)
        exit(1)
    }
    print("Ed25519 archive signature verified")
} catch {
    fputs("Signature verification failed: \(error)\n", stderr)
    exit(1)
}
