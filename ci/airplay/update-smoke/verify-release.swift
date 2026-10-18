// SPDX-License-Identifier: GPL-3.0-or-later
// Public-key verification only; no Keychain, private key, network or app launch.
// CryptoKit Curve25519.Signing is Ed25519 and is available on macOS 10.15+.
// Signed-feed byte format follows Sparkle 2.9.6:
// https://github.com/sparkle-project/Sparkle/blob/2.9.6/common_cli/Signing.swift
// https://github.com/sparkle-project/Sparkle/blob/2.9.6/Sparkle/SPUExtractSignedFeed.m
import Foundation
import CryptoKit
import Darwin

private enum VerificationFailure: Error {
    case invalidInput
    case invalidSignature
}

private func readRegularFile(_ path: String, maximumBytes: UInt64) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard let type = attributes[.type] as? FileAttributeType,
          type == .typeRegular,
          let size = attributes[.size] as? NSNumber,
          size.uint64Value > 0,
          size.uint64Value <= maximumBytes else {
        throw VerificationFailure.invalidInput
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    guard UInt64(data.count) == size.uint64Value else {
        throw VerificationFailure.invalidInput
    }
    return data
}

private func canonicalBase64(_ value: String, count: Int) throws -> Data {
    guard let data = Data(base64Encoded: value),
          data.count == count,
          data.base64EncodedString() == value else {
        throw VerificationFailure.invalidInput
    }
    return data
}

private func signedFeedContent(_ feed: Data) throws -> (Data, Data) {
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = feed.range(of: prefix, options: .backwards),
          range.lowerBound > feed.startIndex else {
        throw VerificationFailure.invalidInput
    }
    let blockData = feed.subdata(in: range.lowerBound..<feed.endIndex)
    guard blockData.count <= 1024,
          let block = String(data: blockData, encoding: .utf8) else {
        throw VerificationFailure.invalidInput
    }
    // Our pinned generate_appcast emits this exact final block. Requiring its
    // canonical ending also rejects unsigned bytes appended after the block.
    let lines = block.components(separatedBy: "\n")
    let signatureLabel = "edSignature: "
    let lengthLabel = "length: "
    guard lines.count == 5,
          lines[0] == "<!-- sparkle-signatures:",
          lines[1].hasPrefix(signatureLabel),
          lines[2].hasPrefix(lengthLabel),
          lines[3] == "-->",
          lines[4].isEmpty else {
        throw VerificationFailure.invalidInput
    }
    let encodedSignature = String(lines[1].dropFirst(signatureLabel.count))
    let encodedLength = String(lines[2].dropFirst(lengthLabel.count))
    let content = feed.subdata(in: feed.startIndex..<range.lowerBound)
    guard let length = UInt64(encodedLength),
          String(length) == encodedLength,
          length == UInt64(content.count) else {
        throw VerificationFailure.invalidInput
    }
    return (content, try canonicalBase64(encodedSignature, count: 64))
}

if CommandLine.arguments.count != 4 {
    fputs("Usage: verify-release MANIFEST_JSON ARCHIVE_ZIP APPCAST_XML\n", stderr)
    exit(64)
}

do {
    let manifestData = try readRegularFile(CommandLine.arguments[1], maximumBytes: 64 * 1024)
    guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
          let encodedKey = manifest["public_key"] as? String,
          let encodedArchiveSignature = manifest["archive_signature"] as? String else {
        throw VerificationFailure.invalidInput
    }
    let publicKeyData = try canonicalBase64(encodedKey, count: 32)
    let archiveSignature = try canonicalBase64(encodedArchiveSignature, count: 64)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let archive = try readRegularFile(CommandLine.arguments[2], maximumBytes: 2 * 1024 * 1024 * 1024)
    guard publicKey.isValidSignature(archiveSignature, for: archive) else {
        throw VerificationFailure.invalidSignature
    }
    let feed = try readRegularFile(CommandLine.arguments[3], maximumBytes: 2 * 1024 * 1024)
    let (content, feedSignature) = try signedFeedContent(feed)
    guard publicKey.isValidSignature(feedSignature, for: content) else {
        throw VerificationFailure.invalidSignature
    }
    print("PASS: ZIP and appcast Ed25519 signatures verified.")
    exit(0)
} catch {
    fputs("ERROR: Release signature verification failed.\n", stderr)
    exit(1)
}
