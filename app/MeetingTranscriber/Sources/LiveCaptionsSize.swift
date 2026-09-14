import CoreGraphics

/// Size preset for the live caption bar (Settings → Transcription → Caption
/// size). A preset couples the caption font with the panel dimensions that
/// fit it, because `LiveCaptionsWindowController` runs a fixed-size panel (see
/// its header on why auto-sizing was abandoned): a font change without a
/// matching panel change would either clip lines or leave dead space.
///
/// Raw values are the `UserDefaults` wire format (`AppSettings.liveCaptionsSize`);
/// `LiveCaptionsSizeTests` pins them.
enum LiveCaptionsSize: String, CaseIterable, Codable {
    case small
    case medium
    case large

    /// Point size of the caption rows.
    var fontSize: CGFloat {
        switch self {
        case .small: 16
        case .medium: 22
        case .large: 28
        }
    }

    /// Point size of the backend label above the rows: half the row size,
    /// which reproduces the 11 pt the label shipped with at `.medium`, but
    /// never below 10 pt, the smallest size AppKit uses for text anywhere.
    var labelFontSize: CGFloat {
        max(10, fontSize / 2)
    }

    /// Fixed panel dimensions: wide enough for a sentence at `fontSize`,
    /// tall enough for the backend label plus four rows, the row spacing and
    /// the overlay's padding, with one wrapped row of headroom (rows do wrap,
    /// about equally often at every preset; `LiveCaptionsSizeTests` pins the
    /// relation). `.medium` is the size the bar shipped with before the
    /// preset existed.
    var panelSize: CGSize {
        switch self {
        case .small: CGSize(width: 520, height: 160)
        case .medium: CGSize(width: 720, height: 200)
        case .large: CGSize(width: 920, height: 260)
        }
    }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}
