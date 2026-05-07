import AppKit

/// Badge overlay kind for the menu bar icon.
enum BadgeKind: CaseIterable {
    case inactive
    case recording
    case transcribing
    case diarizing
    case processing
    case userAction
    case done
    case error
    case updateAvailable

    /// Whether this badge kind uses animation.
    var isAnimated: Bool {
        switch self {
        case .recording, .transcribing, .diarizing, .processing: true

        default: false
        }
    }
}

/// Composites a menu bar icon (waveform + optional badge overlay).
///
/// The base icon is a waveform (5 vertical bars). Depending on the badge kind,
/// the waveform animates differently:
/// - `.recording`: bars bounce like a live audio signal
/// - `.transcribing`: bars morph into horizontal text lines (audio → text)
/// - `.diarizing`: bars split into two groups (speaker separation)
/// - `.processing`: text lines appear sequentially (protocol being written)
///
/// Rendered as template image — macOS handles light/dark mode automatically.
/// `@MainActor` because cache initialisation, NSApp / NSAppearance reads, and
/// `image(badge:…)` all need to run on the main actor. All known call sites
/// (menu bar UI, `BadgeKind.compute(...)` consumers in AppState) are
/// MainActor-bound already, so the annotation tightens the contract without
/// breaking anyone.
@MainActor
enum MenuBarIcon {
    /// Number of distinct animation frames. Pure constant.
    nonisolated static let frameCount = 6

    /// Returns the next animation frame for `badge`, or `current` if `badge`
    /// is non-animated. Static badges (idle, error, …) ignore the timer tick
    /// so the App scene's body does not re-evaluate every 0.4 s. Pure math —
    /// `nonisolated` so it can be called from any context (tests, off-main).
    nonisolated static func nextFrame(_ current: Int, badge: BadgeKind) -> Int {
        guard badge.isAnimated else { return current }
        return (current + 1) % frameCount
    }

    // MARK: - Shared Layout Constants

    // All `nonisolated` because they're pure constants consumed from the
    // rendering closure (which can be invoked off-main during composition).

    nonisolated private static let barWidth: CGFloat = 2.2
    nonisolated private static let barSpacing: CGFloat = 3.6
    nonisolated private static let barCount = 5
    nonisolated private static let defaultBarHeights: [CGFloat] = [0.25, 0.50, 0.75, 0.45, 0.30]

    nonisolated private static let lineHeight: CGFloat = 1.4
    nonisolated private static let lineSpacing: CGFloat = 2.8
    nonisolated private static let lineWidths: [CGFloat] = [0.70, 0.55, 0.65, 0.50, 0.40]
    nonisolated private static let lineLeftInset: CGFloat = 0.12 // multiplied by rect width

    /// Pure layout math used from the rendering closure (off-main during
    /// composition). `nonisolated` so the closure isn't forced onto MainActor.
    nonisolated static func barsLayout(in rect: NSRect) -> (left: CGFloat, centerY: CGFloat) {
        let barsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * (barSpacing - barWidth)
        return (left: (rect.width - barsWidth) / 2, centerY: rect.height / 2)
    }

    nonisolated static func textLayout(in rect: NSRect) -> (top: CGFloat, left: CGFloat) {
        let linesHeight = CGFloat(barCount) * lineHeight + CGFloat(barCount - 1) * (lineSpacing - lineHeight)
        return (top: rect.height / 2 + linesHeight / 2, left: rect.width * lineLeftInset)
    }

    // MARK: - Cache

    /// Pre-rendered frames keyed by BadgeKind. Populated once eagerly when
    /// the type is first referenced. The type is `@MainActor`, so the
    /// initialiser runs on MainActor and can safely read NSApp/NSAppearance.
    private static let cache: [BadgeKind: [NSImage]] = {
        var result: [BadgeKind: [NSImage]] = [:]
        for badge in BadgeKind.allCases {
            let count = badge.isAnimated ? frameCount : 1
            result[badge] = (0 ..< count).map { frame in renderImage(badge: badge, frame: frame) }
        }
        return result
    }()

    // MARK: - Public

    /// Returns a pre-rendered 18x18pt template `NSImage` for the given badge and animation frame.
    ///
    /// If `permissionOverlay` or `recordOnlyOverlay` is true, a red badge is composited over the
    /// base icon — this bypasses the pre-rendered cache and forces a non-template image, because
    /// the overlay is red (template rendering is monochrome).
    static func image(
        badge: BadgeKind,
        animationFrame: Int = 0,
        permissionOverlay: Bool = false,
        recordOnlyOverlay: Bool = false,
    ) -> NSImage {
        if permissionOverlay || recordOnlyOverlay {
            // Honour the cache's frame discipline: animated badges advance, static ones
            // stay on frame 0. Without this, the live animationFrame leaks through and
            // makes `.inactive` (idle waveform) bounce as if recording.
            let frame = badge.isAnimated ? animationFrame : 0
            return renderImage(
                badge: badge, frame: frame,
                permissionOverlay: permissionOverlay,
                recordOnlyOverlay: recordOnlyOverlay,
            )
        }
        guard let frames = cache[badge] else { return renderImage(badge: badge, frame: animationFrame) }
        return frames[animationFrame % frames.count]
    }

    // MARK: - Rendering

    private static func renderImage(
        badge: BadgeKind,
        frame: Int,
        permissionOverlay: Bool = false,
        recordOnlyOverlay: Bool = false,
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        // The `.error` badge and either red-dot overlay all need an explicit foreground color
        // (matching the menu bar appearance), because the image is non-template (the red mark
        // must stay red in both light and dark mode).
        let needsExplicitForeground = badge == .error || permissionOverlay || recordOnlyOverlay
        // Snapshot the dark-mode appearance on the calling thread (the cache
        // builder runs at type init on the main thread; ad-hoc overlay
        // renders also originate from `image(badge:…)` on MainActor). The
        // NSImage closure can be invoked off-main during composition, so
        // we cannot read NSApp from inside it under Swift 6.
        let isDark = NSApp?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = NSImage(size: size, flipped: false) { rect in
            if needsExplicitForeground {
                (isDark ? NSColor.white : NSColor.black).setFill()
            } else {
                NSColor.black.setFill()
            }

            switch badge {
            case .transcribing:
                drawTranscribingAnimation(in: rect, frame: frame)

            case .diarizing:
                drawDiarizingAnimation(in: rect, frame: frame)

            case .processing:
                drawProtocolAnimation(in: rect, frame: frame)

            case .error:
                drawRecordingAnimation(in: rect, frame: 0)

            case .updateAvailable:
                drawRecordingAnimation(in: rect, frame: 0)
                drawUpdateArrow(in: rect)

            default:
                drawRecordingAnimation(in: rect, frame: frame)
            }

            // Overlay precedence: permission errors win over record-only because a permission
            // problem actually breaks recording, so the user must see it first.
            if permissionOverlay || badge == .error {
                drawExclamationBadge(in: rect)
            } else if recordOnlyOverlay {
                drawRecordOnlyBadge(in: rect)
            }

            return true
        }
        image.isTemplate = !needsExplicitForeground
        return image
    }

    // MARK: - Recording Animation (bouncing waveform)

    private static let recordingFrames: [[CGFloat]] = [
        [0.25, 0.50, 0.75, 0.45, 0.30],
        [0.40, 0.30, 0.65, 0.70, 0.25],
        [0.20, 0.60, 0.40, 0.55, 0.50],
        [0.50, 0.45, 0.70, 0.25, 0.40],
        [0.30, 0.65, 0.50, 0.60, 0.20],
        [0.45, 0.35, 0.55, 0.40, 0.65],
    ]

    private static func drawRecordingAnimation(in rect: NSRect, frame: Int) {
        let heights = recordingFrames[frame % recordingFrames.count]
        let layout = barsLayout(in: rect)

        for i in 0 ..< barCount {
            let x = layout.left + CGFloat(i) * barSpacing
            let barH = rect.height * heights[i]
            let barRect = NSRect(
                x: x,
                y: layout.centerY - barH / 2,
                width: barWidth,
                height: barH,
            )
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    // MARK: - Transcribing Animation (waveform → text lines)

    private static let transcribeMorphSteps: [CGFloat] = [0.0, 0.15, 0.35, 0.6, 0.85, 1.0]

    private static func drawTranscribingAnimation(in rect: NSRect, frame: Int) {
        let h = rect.height
        let t = transcribeMorphSteps[frame % transcribeMorphSteps.count]
        let bars = barsLayout(in: rect)
        let text = textLayout(in: rect)

        for i in 0 ..< barCount {
            // Source: vertical bar
            let srcX = bars.left + CGFloat(i) * barSpacing
            let srcH = h * defaultBarHeights[i]
            let srcY = bars.centerY - srcH / 2

            // Target: horizontal text line
            let tgtX = text.left
            let tgtW = rect.width * lineWidths[i]
            let tgtY = text.top - CGFloat(i) * lineSpacing - lineHeight

            // Interpolate
            let x = srcX + (tgtX - srcX) * t
            let y = srcY + (tgtY - srcY) * t
            let rw = barWidth + (tgtW - barWidth) * t
            let rh = srcH + (lineHeight - srcH) * t
            let radius = min(rw, rh) / 2

            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: rw, height: rh),
                xRadius: radius,
                yRadius: radius,
            ).fill()
        }
    }

    // MARK: - Diarizing Animation (bars split into two speaker groups)

    private static let diarizeSplitSteps: [CGFloat] = [0.0, 0.2, 0.5, 0.8, 1.0, 0.8]

    private static func drawDiarizingAnimation(in rect: NSRect, frame: Int) {
        let h = rect.height
        let t = diarizeSplitSteps[frame % diarizeSplitSteps.count]
        let layout = barsLayout(in: rect)

        let maxShift: CGFloat = 2.5
        let verticalSep: CGFloat = 1.5

        for i in 0 ..< barCount {
            let isGroupA = i.isMultiple(of: 2)
            let barH = h * defaultBarHeights[i]

            let x = layout.left + CGFloat(i) * barSpacing + (isGroupA ? -maxShift : maxShift) * t
            let y = layout.centerY - barH / 2 + (isGroupA ? verticalSep : -verticalSep) * t

            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: barH),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2,
            ).fill()
        }
    }

    // MARK: - Error Badge (exclamation mark in bottom-right)

    private static func drawExclamationBadge(in rect: NSRect) {
        let size: CGFloat = 7.0
        let margin: CGFloat = 0.5
        let cx = rect.maxX - size / 2 - margin
        let cy = rect.minY + size / 2 + margin

        // Red circle
        NSColor.systemRed.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size),
        ).fill()

        // White "!" on top
        NSColor.white.setFill()

        // Stem
        let stemW: CGFloat = 1.3
        let stemH: CGFloat = 2.8
        let stemY = cy + size / 2 - 1.8 - stemH
        NSBezierPath(
            roundedRect: NSRect(x: cx - stemW / 2, y: stemY, width: stemW, height: stemH),
            xRadius: stemW / 2, yRadius: stemW / 2,
        ).fill()

        // Dot
        let dotSize: CGFloat = 1.3
        let dotY = cy - size / 2 + 1.0
        NSBezierPath(ovalIn: NSRect(x: cx - dotSize / 2, y: dotY, width: dotSize, height: dotSize)).fill()
    }

    // MARK: - Record-Only Badge (solid red dot in bottom-right)

    private static func drawRecordOnlyBadge(in rect: NSRect) {
        let size: CGFloat = 5.0
        let margin: CGFloat = 0.5
        let cx = rect.maxX - size / 2 - margin
        let cy = rect.minY + size / 2 + margin

        NSColor.systemRed.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size),
        ).fill()
    }

    // MARK: - Update Available (small upward arrow badge in bottom-right)

    private static func drawUpdateArrow(in rect: NSRect) {
        let size: CGFloat = 6.0
        let margin: CGFloat = 0.5
        let cx = rect.maxX - size / 2 - margin
        let cy = rect.minY + size / 2 + margin

        // Arrow pointing up: triangle + stem
        let arrow = NSBezierPath()
        // Triangle head
        arrow.move(to: NSPoint(x: cx, y: cy + size / 2)) // top
        arrow.line(to: NSPoint(x: cx - size / 3, y: cy + 0.5)) // bottom-left
        arrow.line(to: NSPoint(x: cx + size / 3, y: cy + 0.5)) // bottom-right
        arrow.close()
        arrow.fill()

        // Stem
        let stemWidth: CGFloat = 1.4
        let stem = NSRect(x: cx - stemWidth / 2, y: cy - size / 3, width: stemWidth, height: size / 2)
        NSBezierPath(roundedRect: stem, xRadius: stemWidth / 2, yRadius: stemWidth / 2).fill()
    }

    // MARK: - Protocol Generation Animation (text lines appearing sequentially)

    private static func drawProtocolAnimation(in rect: NSRect, frame: Int) {
        let text = textLayout(in: rect)
        let visibleLines = (frame % frameCount) + 1

        for i in 0 ..< min(visibleLines, barCount) {
            let lineW = rect.width * lineWidths[i]
            let lineY = text.top - CGFloat(i) * lineSpacing - lineHeight
            NSBezierPath(
                roundedRect: NSRect(x: text.left, y: lineY, width: lineW, height: lineHeight),
                xRadius: lineHeight / 2,
                yRadius: lineHeight / 2,
            ).fill()
        }
    }
}

// MARK: - Badge State Logic (pure function, testable without UI)

extension BadgeKind {
    /// Computes the current badge from plain value inputs.
    ///
    /// This is a pure function with no object dependencies — tests can call it
    /// directly with any combination of inputs without driving WatchLoop into states.
    static func compute(
        watchLoopActive: Bool,
        watchLoopState: WatchLoop.State,
        transcriberState: TranscriberState,
        activeJobState: JobState?,
        updateAvailable: Bool,
        permissionProblem: Bool = false,
    ) -> BadgeKind {
        if watchLoopActive {
            if watchLoopState == .recording { return .recording }
            switch transcriberState {
            case .waitingForSpeakerCount, .waitingForSpeakerNames: return .userAction
            case .protocolReady: return .done
            case .error: return .error
            case .transcribing, .recordingDone: return .transcribing
            case .generatingProtocol: return .processing
            default: break
            }
        }
        switch activeJobState {
        case .transcribing: return .transcribing
        case .diarizing: return .diarizing
        case .some: return .processing
        case .none: break
        }
        if permissionProblem { return .error }
        if updateAvailable { return .updateAvailable }
        return .inactive
    }
}
