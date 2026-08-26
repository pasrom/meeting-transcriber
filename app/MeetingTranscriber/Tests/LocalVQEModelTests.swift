// Tests for LocalVQEModel, the resolver that decides which .gguf the echo
// canceller runs against. The rule under test is a precedence order plus one
// deliberate refusal: an override that points at nothing must NOT quietly fall
// back to the bundled model, because the whole reason to set the override is
// to measure one specific model.
@testable import MeetingTranscriber
import XCTest

final class LocalVQEModelTests: XCTestCase {
    private func existing(_ paths: String...) -> (String) -> Bool {
        let set = Set(paths)
        return { set.contains($0) }
    }

    func testBundledModelIsUsedWhenNoOverrideIsSet() {
        let resolution = LocalVQEModel.resolve(
            override: nil,
            bundledPath: "/App.app/Contents/Resources/model.gguf",
            fileExists: existing("/App.app/Contents/Resources/model.gguf"),
        )
        XCTAssertEqual(resolution, .found(path: "/App.app/Contents/Resources/model.gguf"))
        XCTAssertEqual(resolution.path, "/App.app/Contents/Resources/model.gguf")
    }

    func testOverrideWinsOverTheBundledModel() {
        let resolution = LocalVQEModel.resolve(
            override: "/tmp/other.gguf",
            bundledPath: "/App.app/Contents/Resources/model.gguf",
            fileExists: existing("/tmp/other.gguf", "/App.app/Contents/Resources/model.gguf"),
        )
        XCTAssertEqual(resolution, .found(path: "/tmp/other.gguf"))
    }

    func testOverridePointingAtNothingDoesNotFallBackToTheBundle() {
        let resolution = LocalVQEModel.resolve(
            override: "/tmp/typo.gguf",
            bundledPath: "/App.app/Contents/Resources/model.gguf",
            fileExists: existing("/App.app/Contents/Resources/model.gguf"),
        )
        XCTAssertEqual(resolution, .overrideMissing(path: "/tmp/typo.gguf"))
        XCTAssertNil(resolution.path)
    }

    // Two ways to have no bundled model: the bundle names none, or it names one
    // that is not on disk (a stripped or half-assembled bundle). Treating the
    // second as `.absent` rather than handing a dead path to the C library
    // keeps the failure at the resolver.
    func testAbsentWhenTheBundleOffersNoUsableModel() {
        for bundledPath in [nil, "/App.app/Contents/Resources/model.gguf"] {
            let resolution = LocalVQEModel.resolve(
                override: nil,
                bundledPath: bundledPath,
                fileExists: existing(),
            )
            XCTAssertEqual(resolution, .absent, "bundledPath: \(bundledPath ?? "nil")")
            XCTAssertNil(resolution.path)
        }
    }

    // An exported-but-empty variable is the normal shape of "unset" in CI, and
    // a here-doc or a `$(...)` capture makes that empty value a NEWLINE rather
    // than a space. Trimming only spaces would classify "\n" as a set override
    // naming a nonexistent file, which reports as a dangling path instead of as
    // no override at all.
    func testBlankOverrideIsTreatedAsUnset() {
        for blank in ["   ", "\n", "\t", " \n "] {
            let resolution = LocalVQEModel.resolve(
                override: blank,
                bundledPath: "/App.app/Contents/Resources/model.gguf",
                fileExists: existing("/App.app/Contents/Resources/model.gguf"),
            )
            XCTAssertEqual(
                resolution, .found(path: "/App.app/Contents/Resources/model.gguf"),
                "blank override \(blank.debugDescription) should read as unset",
            )
        }
    }

    // MARK: - Finding the model in a real bundle

    // These build an actual Bundle on disk. The pure resolver above is given a
    // bundledPath; this is the code that PRODUCES one, it is the only thing
    // that can silently answer "no model" in a shipped app, and until now
    // nothing exercised it. Its three implicit pins are the prefix, the
    // extension, and the location, and each is asserted below.
    private func makeBundle(resources: [String], file: StaticString = #filePath, line: UInt = #line) throws -> Bundle {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalVQEModelTests-\(UUID().uuidString).bundle")
        let resourcesDir = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "".write(
            to: root.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8,
        )
        for relative in resources {
            let target = resourcesDir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try "weights".write(to: target, atomically: true, encoding: .utf8)
        }
        return try XCTUnwrap(Bundle(url: root), "could not open the test bundle", file: file, line: line)
    }

    func testFindsTheModelInTheResourcesRoot() throws {
        let bundle = try makeBundle(resources: ["localvqe-v1.4-aec-200K-f32.gguf"])
        let path = try XCTUnwrap(LocalVQEModel.bundledModelPath(in: bundle))
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "localvqe-v1.4-aec-200K-f32.gguf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    // The name carries a version with dots and an uppercase segment, which is
    // the shape most likely to trip a resource lookup.
    func testFindsAModelWhateverVersionTheNameCarries() throws {
        let bundle = try makeBundle(resources: ["localvqe-v2.0-AEC-1.3M-bf16.gguf"])
        let path = try XCTUnwrap(LocalVQEModel.bundledModelPath(in: bundle))
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "localvqe-v2.0-AEC-1.3M-bf16.gguf")
    }

    func testIgnoresGgufFilesThatAreNotOurs() throws {
        let bundle = try makeBundle(resources: ["some-other-model.gguf"])
        XCTAssertNil(LocalVQEModel.bundledModelPath(in: bundle))
    }

    func testIgnoresOurPrefixWithTheWrongExtension() throws {
        let bundle = try makeBundle(resources: ["localvqe-v1.4-aec-200K-f32.bin"])
        XCTAssertNil(LocalVQEModel.bundledModelPath(in: bundle))
    }

    func testEmptyBundleYieldsNoPath() throws {
        let bundle = try makeBundle(resources: [])
        XCTAssertNil(LocalVQEModel.bundledModelPath(in: bundle))
    }

    // Documents a real limit rather than a wish: the lookup is NOT recursive.
    // A future change that declares the model as an SPM resource would nest it
    // inside a generated .bundle, and the shipped app would find nothing while
    // every other test stayed green. This test is what would go red.
    func testDoesNotSearchSubdirectories() throws {
        let bundle = try makeBundle(resources: ["nested/localvqe-v1.4-aec-200K-f32.gguf"])
        XCTAssertNil(
            LocalVQEModel.bundledModelPath(in: bundle),
            "the lookup is deliberately shallow; if this ever passes, the install path moved",
        )
    }
}
