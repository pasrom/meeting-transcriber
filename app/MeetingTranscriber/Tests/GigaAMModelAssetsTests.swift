import CryptoKit
import Foundation
@testable import MeetingTranscriber
import XCTest

@MainActor
final class GigaAMModelAssetsTests: XCTestCase {
    func testInvalidHashNeverReachesCompilerOrPublishedCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let probe = InstallProbe()
        var files = fixture.files
        files["gigaam-window.f32"] = String(repeating: "0", count: 64)

        do {
            try await GigaAMModelAssets.install(in: fixture.destination, files: files, download: fixture.download) { source in
                try await probe.compile(source)
            }
            XCTFail("Expected a hash mismatch")
        } catch let GigaAMModel.ModelError.invalidAsset(name) {
            XCTAssertEqual(name, "gigaam-window.f32")
        }

        let compiles = await probe.compiles
        XCTAssertEqual(compiles, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertNoDownloads()
    }

    func testInstallReplacesIncompleteCacheAndRemovesStaleStage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let fm = FileManager.default
        let incomplete = fixture.destination.appendingPathComponent("gigaam_v3_e2e.mlmodelc")
        try fm.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data().write(to: incomplete.appendingPathComponent("coremldata.bin"))
        try fm.createDirectory(at: fixture.root.appendingPathComponent(".download-locked-crashed"), withIntermediateDirectories: false)
        let probe = InstallProbe()

        try await GigaAMModelAssets.install(in: fixture.destination, files: fixture.files, download: fixture.download) { source in
            XCTAssertFalse(GigaAMModelAssets.isInstalled(in: fixture.destination))
            return try await probe.compile(source)
        }

        XCTAssertTrue(GigaAMModelAssets.isInstalled(in: fixture.destination))
        XCTAssertFalse(fm.fileExists(atPath: fixture.destination.appendingPathComponent("gigaam_v3_e2e.mlpackage").path))
        try fixture.assertNoDownloads()
    }

    func testConcurrentInstallersPublishOneCompleteCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let probe = InstallProbe()

        async let first: Void = GigaAMModelAssets.install(
            in: fixture.destination, files: fixture.files, download: fixture.download, compile: probe.compile,
        )
        async let second: Void = GigaAMModelAssets.install(
            in: fixture.destination, files: fixture.files, download: fixture.download, compile: probe.compile,
        )
        _ = try await (first, second)

        let compiles = await probe.compiles
        XCTAssertEqual(compiles, 1)
        XCTAssertTrue(GigaAMModelAssets.isInstalled(in: fixture.destination))
        try fixture.assertNoDownloads()
    }

    func testLoadRepairsPresentButInvalidCacheOnlyOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let probe = InstallProbe()
        try await GigaAMModelAssets.install(in: fixture.destination, files: fixture.files, download: fixture.download, compile: probe.compile)
        let weightsPath = "gigaam_v3_e2e.mlmodelc/weights/weight.bin"
        try Data().write(to: fixture.destination.appendingPathComponent(weightsPath))
        XCTAssertTrue(GigaAMModelAssets.isInstalled(in: fixture.destination))

        let weights = try await GigaAMModelAssets.load(from: fixture.destination, open: { directory in
            let weights = try Data(contentsOf: directory.appendingPathComponent(weightsPath))
            guard !weights.isEmpty else { throw GigaAMModel.ModelError.invalidAsset(weightsPath) }
            return weights
        }, repair: { inode in
            try await GigaAMModelAssets.install(
                in: fixture.destination, files: fixture.files,
                download: fixture.download, compile: probe.compile, replacing: inode,
            )
        })
        XCTAssertEqual(weights, Data([1]))
        let compiles = await probe.compiles
        XCTAssertEqual(compiles, 2)
        try fixture.assertNoDownloads()
    }

    private struct Fixture: Sendable {
        let root: URL
        var destination: URL {
            root.appendingPathComponent("revision")
        }

        var files: [String: String] {
            let names = ["gigaam-melfb.f32", "gigaam-window.f32", "gigaam-vocab.txt", "gigaam_v3_e2e.mlpackage/Manifest.json"]
            return Dictionary(uniqueKeysWithValues: names.map { name in
                let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
                return (name, hash)
            })
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func download(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString)
            try Data(name.utf8).write(to: url)
            return url
        }

        func assertNoDownloads() throws {
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".download-") })
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private actor InstallProbe {
        private(set) var compiles = 0

        func compile(_ source: URL) async throws -> URL {
            compiles += 1
            try await Task.sleep(for: .milliseconds(100))
            let compiled = source.deletingLastPathComponent().appendingPathComponent("test-compiled")
            try FileManager.default.createDirectory(at: compiled.appendingPathComponent("weights"), withIntermediateDirectories: true)
            for name in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                try Data([1]).write(to: compiled.appendingPathComponent(name))
            }
            return compiled
        }
    }
}
