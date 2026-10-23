#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/cacalc-verification.XXXXXX")
trap 'rm -rf "$verification_dir"' EXIT HUP INT TERM
cat > "$verification_dir/Check.swift" <<'SWIFT'
import Foundation
import CryptoKit
@main struct Check {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("parakeet-synthetic")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = Data("synthetic model bytes".utf8)
        let file = folder.appendingPathComponent("weights.bin")
        try content.write(to: file)
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let manifest = VoiceManifest(version: 1, models: [.init(id: "parakeet", repository: "synthetic", revision: "synthetic",
            files: [.init(path: "weights.bin", bytes: Int64(content.count), sha256: hash)])])
        let first = try await VoiceAssets(root: root, manifest: manifest).isReady(models: ["parakeet"])
        precondition(first)
        let receipt = folder.appendingPathComponent(".verified-files-v1.json")
        let stamp = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: receipt.path)
        let second = try await VoiceAssets(root: root, manifest: manifest).isReady(models: ["parakeet"])
        precondition(second)
        let receiptDate = try FileManager.default.attributesOfItem(atPath: receipt.path)[.modificationDate] as! Date
        precondition(receiptDate == stamp, "Unchanged files use receipt without hashing/rewrite")
        try Data("invalid receipt".utf8).write(to: receipt)
        let recovered = try await VoiceAssets(root: root, manifest: manifest).isReady(models: ["parakeet"])
        precondition(recovered, "Corrupt receipt falls back to full verification")
        var changed = content; changed[0] ^= 1
        try changed.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: file.path)
        let corrupt = try await VoiceAssets(root: root, manifest: manifest).isReady(models: ["parakeet"])
        precondition(!corrupt, "Same-size modified model is rehashed and rejected")
        try content.write(to: file)
        let restored = try await VoiceAssets(root: root, manifest: manifest).isReady(models: ["parakeet"])
        precondition(restored)
        try FileManager.default.removeItem(at: file)
        let missing = try await VoiceAssets(root: root, manifest: manifest).isReady(models: ["parakeet"])
        precondition(!missing, "Receipt cannot hide missing weights")
        print("PASS: cold hash, warm receipt, corrupt receipt, same-size corruption, restoration, missing file")
    }
}
SWIFT
python3 - "$verification_dir/FoodError.swift" <<'PYERROR'
from pathlib import Path
import sys
source = Path('ios/Cacalc/Domain.swift').read_text()
Path(sys.argv[1]).write_text(source[:source.index('enum Numbers')])
PYERROR
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$verification_dir/modules" "$verification_dir/FoodError.swift" ios/Cacalc/ProcessMemory.swift ios/Cacalc/VoiceAssets.swift "$verification_dir/Check.swift" -o "$verification_dir/check"
"$verification_dir/check"
