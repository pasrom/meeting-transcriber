import AppKit
import Foundation

/// `NSOpenPanel` delegate + accessory view that previews how the selected
/// files will be grouped when imported. Refreshes whenever the user changes
/// the selection so they see "1 paired recording + 1 single file → 2
/// transcripts" instead of being surprised after pressing Open.
@MainActor
final class PairedImportPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    let accessoryView: NSView
    private let label: NSTextField

    override init() {
        let label = NSTextField(labelWithString: " ")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.label = label
        self.accessoryView = container
        super.init()
    }

    func panelSelectionDidChange(_ sender: Any?) {
        let urls = (sender as? NSOpenPanel)?.urls ?? []
        label.stringValue = PairedImportSummary.text(forSelectedURLs: urls)
    }
}

enum PairedImportSummary {
    static func text(forSelectedURLs urls: [URL]) -> String {
        // Non-empty so the `NSTextField` keeps its baseline height between selections.
        guard !urls.isEmpty else { return " " }
        let resolution = PairedRecordingResolver.resolve(urls: urls)
        let pairedCount = resolution.paired.count
        let singletonCount = resolution.singletons.count
        let total = pairedCount + singletonCount

        var parts: [String] = []
        if pairedCount > 0 {
            parts.append("\(pairedCount) paired recording\(pairedCount == 1 ? "" : "s")")
        }
        if singletonCount > 0 {
            parts.append("\(singletonCount) single file\(singletonCount == 1 ? "" : "s")")
        }
        let lhs = parts.joined(separator: " + ")
        return "\(lhs) → \(total) transcript\(total == 1 ? "" : "s")"
    }
}
