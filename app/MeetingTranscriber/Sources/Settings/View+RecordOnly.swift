import SwiftUI

extension View {
    /// Visually inert when `on` is true: dimmed and non-interactive. Used by
    /// pipeline-related Settings sections that have no effect in record-only mode.
    func recordOnlyDisabled(_ on: Bool) -> some View {
        disabled(on).opacity(on ? 0.5 : 1)
    }
}
