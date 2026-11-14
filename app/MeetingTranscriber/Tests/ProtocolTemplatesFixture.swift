import Foundation
@testable import MeetingTranscriber
import XCTest

/// A templates folder in a temp directory, settings over a throwaway defaults
/// suite and a fake opener, for the tests of Settings → Output → Meeting Notes
/// Templates. Opened folders and trashed files are recorded instead of reaching
/// Finder or the real Trash.
@MainActor
final class ProtocolTemplatesFixture {
    let store: ProtocolTemplateStore
    let defaults: UserDefaults
    let settings: AppSettings
    let apps = FakeTemplateOpener()
    private(set) var openedFolders: [URL] = []
    private(set) var trashed: [URL] = []

    init(_ testCase: XCTestCase, templates: [String] = []) throws {
        store = try ProtocolTemplateStore(directory: testCase.makeTempDirectory(prefix: "protocol-templates"))
        let suite = "ProtocolTemplatesFixture-\(getpid())-\(UUID().uuidString)"
        testCase.addTeardownBlock { DefaultsSuite.remove(suite) }
        defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        settings = AppSettings(defaults: defaults)
        try write(templates)
    }

    func write(_ names: [String]) throws {
        for name in names {
            try "Template \(name)".write(to: store.fileURL(named: name), atomically: true, encoding: .utf8)
        }
    }

    /// The folder's entries, sorted.
    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).sorted()
    }

    /// The section's model over the folder, after its first reload. The
    /// default `trashItem` removes the file; a test passes one that throws.
    func makeModel(
        settings: AppSettings? = nil,
        trashItem: ((URL) throws -> Void)? = nil,
    ) -> ProtocolTemplatesModel {
        let model = ProtocolTemplatesModel(
            store: store,
            settings: settings ?? self.settings,
            opener: apps.opener,
            openFile: { self.openedFolders.append($0) },
            trashItem: trashItem ?? { url in
                self.trashed.append(url)
                try FileManager.default.removeItem(at: url)
            },
        )
        model.reload()
        return model
    }
}
