import CoreML
import CryptoKit
import Foundation

/// Downloads the pinned Core ML conversion to a staging directory and publishes
/// the compiled model and its matching frontend together.
enum GigaAMModelAssets {
    private static let revision = "43dc96918bc232deafa7b7d0600fb499806f7ac1"
    private static let package = "gigaam_v3_e2e.mlpackage"
    private static let compiled = "gigaam_v3_e2e.mlmodelc"
    private static let weights = "\(package)/Data/com.apple.CoreML/weights/weight.bin"
    private static let files = [
        "gigaam-melfb.f32": "e87260b36046d4384ea4e7ca82ff7e5a82b4f85381c34b16ccfa79c0803ffba2",
        "gigaam-window.f32": "834a6744851a775dbb1831e9e17f0f702599b4d52c1d97d7638b3f170824419f",
        "gigaam-vocab.txt": "a5aac1a2913150f1e5400cfca1765406c01d0792c5842e3a1deea85bc8dfbc09",
        "\(package)/Manifest.json": "cd7840db2ffe56befcbb3e324dc661846ac5706c4a8c3725be56ff67b37e2eb2",
        "\(package)/Data/com.apple.CoreML/model.mlmodel": "8e0c43329503b3b2fc41f6e594f44d7b35acdd0bd61a91bf5741557d716be957",
        weights: "706153a1e14e2b26f328f394f3eded2689865eaf2d653c021006a4f3ab3a0ec6",
    ]

    static let directory = AppPaths.dataDir.appendingPathComponent("Models/gigaam-v3-e2e-ctc/\(revision)")

    static func isInstalled(in directory: URL) -> Bool {
        ["gigaam-melfb.f32", "gigaam-window.f32", "gigaam-vocab.txt", "\(compiled)/coremldata.bin"]
            .allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    @concurrent
    static func install(in directory: URL, onCompiling: @Sendable () async -> Void) async throws {
        guard !isInstalled(in: directory) else { return }
        let fm = FileManager.default
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".download-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (name, hash) in files.sorted(by: { $0.key < $1.key }) {
            try await download(name, hash: hash, into: staging)
        }

        await onCompiling()
        let source = staging.appendingPathComponent(package)
        let model = try await MLModel.compileModel(at: source)
        defer { try? fm.removeItem(at: model) }
        try fm.moveItem(at: model, to: staging.appendingPathComponent(compiled))
        try fm.removeItem(at: source)
        // A dev and a release app can share this cache. Only a completed staged
        // model becomes visible and the first successful installation wins.
        guard !isInstalled(in: directory) else { return }
        do {
            try fm.moveItem(at: staging, to: directory)
        } catch CocoaError.fileWriteFileExists {
            guard isInstalled(in: directory) else { throw CocoaError(.fileWriteFileExists) }
        }
    }

    @concurrent
    static func load(from directory: URL) async throws -> GigaAMModel {
        try GigaAMModel(compiledURL: directory.appendingPathComponent(compiled), assets: directory)
    }

    private static func download(_ name: String, hash: String, into staging: URL) async throws {
        guard let origin = URL(string: "https://huggingface.co/inhum/gigaam-v3-coreml/resolve/\(revision)") else {
            throw URLError(.badURL)
        }
        let (temporary, response) = try await URLSession.shared.download(from: origin.appendingPathComponent(name))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard try sha256(temporary) == hash else { throw GigaAMModel.ModelError.invalidAsset(name) }
        let destination = staging.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
