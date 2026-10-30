import AppKit

/// Open Notion pages in the existing desktop session when one is running.
@MainActor
struct ProtocolOpener {
    var runningNotionApplicationURL: () -> URL? = {
        NSRunningApplication.runningApplications(withBundleIdentifier: "notion.id").first?.bundleURL
    }

    var openDefault: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var openInApplication: (URL, URL) async throws -> Void = { page, application in
        _ = try await NSWorkspace.shared.open(
            [page], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration(),
        )
    }

    func open(_ target: JobOpenTarget) async -> Bool {
        if case let .notion(page) = target, let application = runningNotionApplicationURL() {
            do {
                try await openInApplication(page, application)
                return true
            } catch {
                // Notion may have quit between the running-app check and handoff.
                return openDefault(page)
            }
        }
        return openDefault(target.url)
    }
}
