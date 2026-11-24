import CoreML
import CryptoKit
import Darwin
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

    typealias Download = @Sendable (String) async throws -> URL
    typealias Compile = @Sendable (URL) async throws -> URL

    static let directory = AppPaths.dataDir.appendingPathComponent("Models/gigaam-v3-e2e-ctc/\(revision)")

    static func isInstalled(in directory: URL) -> Bool {
        [
            "gigaam-melfb.f32",
            "gigaam-window.f32",
            "gigaam-vocab.txt",
            "\(compiled)/coremldata.bin",
            "\(compiled)/model.mil",
            "\(compiled)/weights/weight.bin",
        ]
        .allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    @concurrent
    static func install(
        in directory: URL, replacing failedInode: UInt64? = nil, onCompiling: @Sendable () async -> Void,
    ) async throws {
        try await install(in: directory, files: files, download: download, compile: { url in
            try await MLModel.compileModel(at: url)
        }, replacing: failedInode, onCompiling: onCompiling)
    }

    @concurrent
    static func install(
        in directory: URL, files: [String: String], download: Download, compile: Compile,
        replacing failedInode: UInt64? = nil,
        onCompiling: @Sendable () async -> Void = {},
    ) async throws {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        // Both apps sharing this cache use the same lock. Keep the lock file
        // in place so waiters always lock the same inode, even after a crash.
        let descriptor = try await lockCache(in: parent)
        defer { close(descriptor) }
        try Task.checkCancellation()
        for url in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(".download-locked-") {
            try fm.removeItem(at: url)
        }
        let replacingFailedCache = failedInode.map { $0 == cacheInode(at: directory) } ?? false
        guard replacingFailedCache || !isInstalled(in: directory) else { return }

        let staging = parent.appendingPathComponent(".download-locked-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for (name, hash) in files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let temporary = try await download(name)
            defer { try? fm.removeItem(at: temporary) }
            guard try sha256(temporary) == hash else { throw GigaAMModel.ModelError.invalidAsset(name) }
            let destination = staging.appendingPathComponent(name)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: destination)
        }

        await onCompiling()
        let source = staging.appendingPathComponent(package)
        let model = try await compile(source)
        defer { try? fm.removeItem(at: model) }
        try fm.moveItem(at: model, to: staging.appendingPathComponent(compiled))
        try fm.removeItem(at: source)
        guard isInstalled(in: staging) else { throw GigaAMModel.ModelError.invalidAsset(compiled) }
        try Task.checkCancellation()

        guard replacingFailedCache || !isInstalled(in: directory) else { return }
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        do {
            try fm.moveItem(at: staging, to: directory)
        } catch CocoaError.fileWriteFileExists {
            guard isInstalled(in: directory) else { throw CocoaError(.fileWriteFileExists) }
        }
    }

    private static func lockCache(in directory: URL) async throws -> Int32 {
        let lock = directory.appendingPathComponent(".install.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try await Task.sleep(for: .milliseconds(50))
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    @concurrent
    static func load(
        from directory: URL, onRepairing: @Sendable () async -> Void, onCompiling: @Sendable () async -> Void,
    ) async throws -> GigaAMModel {
        try await load(from: directory, open: { directory in
            try GigaAMModel(compiledURL: directory.appendingPathComponent(compiled), assets: directory)
        }, repair: { failedInode in
            await onRepairing()
            try await install(in: directory, replacing: failedInode, onCompiling: onCompiling)
            await onCompiling()
        })
    }

    @concurrent
    static func load<Model: Sendable>(
        from directory: URL, open: @Sendable (URL) throws -> Model,
        repair: @Sendable (UInt64) async throws -> Void,
    ) async throws -> Model {
        let inode = cacheInode(at: directory)
        do {
            return try open(directory)
        } catch {
            try Task.checkCancellation()
            guard let inode else { throw error }
            // A repair only replaces the directory that failed. A second
            // caller can reuse an installation published while it waited.
            try await repair(inode)
            try Task.checkCancellation()
            return try open(directory)
        }
    }

    private static func cacheInode(at directory: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        return attributes?[.systemFileNumber] as? UInt64
    }

    private static func download(_ name: String) async throws -> URL {
        guard let origin = URL(string: "https://huggingface.co/inhum/gigaam-v3-coreml/resolve/\(revision)") else {
            throw URLError(.badURL)
        }
        let (temporary, response) = try await URLSession.shared.download(from: origin.appendingPathComponent(name))
        guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        return temporary
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
