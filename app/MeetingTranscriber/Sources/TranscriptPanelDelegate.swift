import AppKit

/// Enables only `.txt` files in the Generate Meeting Notes from Transcript
/// panel. `allowedContentTypes = [.plainText]` alone also admits Markdown,
/// which conforms to plain text, and the job takes `.txt` only.
final class TranscriptPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    static func accepts(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return true }
        return url.pathExtension.lowercased() == "txt"
    }

    func panel(_: Any, shouldEnable url: URL) -> Bool {
        Self.accepts(url)
    }
}
