#!/usr/bin/env swift
// Generates animated GIFs of the menu bar icon animations for documentation.
// Usage: swift scripts/generate_menu_bar_gifs.swift
// Output: docs/menu-bar-*.gif

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Drawing Constants (mirrored from MenuBarIcon.swift)

// Native 18pt constants — identical to MenuBarIcon.swift
let barWidth: CGFloat = 2.2
let barSpacing: CGFloat = 3.6
let barCount = 5
let defaultBarHeights: [CGFloat] = [0.25, 0.50, 0.75, 0.45, 0.30]
let lineHeight: CGFloat = 1.4
let lineSpacingVal: CGFloat = 2.8
let lineWidths: [CGFloat] = [0.70, 0.55, 0.65, 0.50, 0.40]
let lineLeftInset: CGFloat = 0.12
let frameCount = 6

func barsLayout(in rect: NSRect) -> (left: CGFloat, centerY: CGFloat) {
    let barsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * (barSpacing - barWidth)
    return (left: (rect.width - barsWidth) / 2, centerY: rect.height / 2)
}

func textLayout(in rect: NSRect) -> (top: CGFloat, left: CGFloat) {
    let linesHeight = CGFloat(barCount) * lineHeight + CGFloat(barCount - 1) * (lineSpacingVal - lineHeight)
    return (top: rect.height / 2 + linesHeight / 2, left: rect.width * lineLeftInset)
}

// MARK: - Drawing Functions

let recordingFrames: [[CGFloat]] = [
    [0.25, 0.50, 0.75, 0.45, 0.30],
    [0.40, 0.30, 0.65, 0.70, 0.25],
    [0.20, 0.60, 0.40, 0.55, 0.50],
    [0.50, 0.45, 0.70, 0.25, 0.40],
    [0.30, 0.65, 0.50, 0.60, 0.20],
    [0.45, 0.35, 0.55, 0.40, 0.65],
]

func drawIdle(in rect: NSRect) {
    let layout = barsLayout(in: rect)
    for i in 0..<barCount {
        let x = layout.left + CGFloat(i) * barSpacing
        let barH = rect.height * defaultBarHeights[i]
        let barRect = NSRect(x: x, y: layout.centerY - barH / 2, width: barWidth, height: barH)
        NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
}

func drawRecording(in rect: NSRect, frame: Int) {
    let heights = recordingFrames[frame % recordingFrames.count]
    let layout = barsLayout(in: rect)
    for i in 0..<barCount {
        let x = layout.left + CGFloat(i) * barSpacing
        let barH = rect.height * heights[i]
        let barRect = NSRect(x: x, y: layout.centerY - barH / 2, width: barWidth, height: barH)
        NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
}

let transcribeMorphSteps: [CGFloat] = [0.0, 0.15, 0.35, 0.6, 0.85, 1.0]

func drawTranscribing(in rect: NSRect, frame: Int) {
    let h = rect.height
    let t = transcribeMorphSteps[frame % transcribeMorphSteps.count]
    let bars = barsLayout(in: rect)
    let text = textLayout(in: rect)

    for i in 0..<barCount {
        let srcX = bars.left + CGFloat(i) * barSpacing
        let srcH = h * defaultBarHeights[i]
        let srcY = bars.centerY - srcH / 2

        let tgtX = text.left
        let tgtW = rect.width * lineWidths[i]
        let tgtY = text.top - CGFloat(i) * lineSpacingVal - lineHeight

        let x = srcX + (tgtX - srcX) * t
        let y = srcY + (tgtY - srcY) * t
        let rw = barWidth + (tgtW - barWidth) * t
        let rh = srcH + (lineHeight - srcH) * t
        let radius = min(rw, rh) / 2

        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: rw, height: rh),
                     xRadius: radius, yRadius: radius).fill()
    }
}

let diarizeSplitSteps: [CGFloat] = [0.0, 0.2, 0.5, 0.8, 1.0, 0.8]

func drawDiarizing(in rect: NSRect, frame: Int) {
    let h = rect.height
    let t = diarizeSplitSteps[frame % diarizeSplitSteps.count]
    let layout = barsLayout(in: rect)

    let maxShift: CGFloat = 2.5
    let verticalSep: CGFloat = 1.5

    for i in 0..<barCount {
        let isGroupA = (i % 2 == 0)
        let barH = h * defaultBarHeights[i]
        let x = layout.left + CGFloat(i) * barSpacing + (isGroupA ? -maxShift : maxShift) * t
        let y = layout.centerY - barH / 2 + (isGroupA ? verticalSep : -verticalSep) * t

        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: barH),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
}

func drawProtocol(in rect: NSRect, frame: Int) {
    let text = textLayout(in: rect)
    let visibleLines = (frame % frameCount) + 1

    for i in 0..<min(visibleLines, barCount) {
        let lineW = rect.width * lineWidths[i]
        let lineY = text.top - CGFloat(i) * lineSpacingVal - lineHeight
        NSBezierPath(roundedRect: NSRect(x: text.left, y: lineY, width: lineW, height: lineHeight),
                     xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
    }
}

// MARK: - Rendering

let nativeSize: CGFloat = 18
let pixelSize = 100
let scaleFactor = CGFloat(pixelSize) / nativeSize

func renderFrame(draw: @escaping (NSRect) -> Void) -> CGImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Fill white background at pixel size
    let fullRect = NSRect(x: 0, y: 0, width: CGFloat(pixelSize), height: CGFloat(pixelSize))
    NSColor.white.setFill()
    fullRect.fill()

    // Scale coordinate system: draw at native 18pt, output at 100px
    let transform = NSAffineTransform()
    transform.scale(by: scaleFactor)
    transform.concat()

    let nativeRect = NSRect(x: 0, y: 0, width: nativeSize, height: nativeSize)
    NSColor.black.setFill()
    draw(nativeRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

func writeGIF(name: String, frames: [CGImage], delay: Double = 0.4) {
    let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let docsDir = scriptDir.deletingLastPathComponent().appendingPathComponent("docs")
    try! FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
    let url = docsDir.appendingPathComponent(name) as CFURL

    let properties: CFDictionary = [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0
        ]
    ] as CFDictionary

    let frameProperties: CFDictionary = [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay
        ]
    ] as CFDictionary

    let dest = CGImageDestinationCreateWithURL(url, UTType.gif.identifier as CFString, frames.count, nil)!
    CGImageDestinationSetProperties(dest, properties)

    for frame in frames {
        CGImageDestinationAddImage(dest, frame, frameProperties)
    }

    CGImageDestinationFinalize(dest)
    print("  Generated: docs/\(name)")
}

// MARK: - Generate

print("Generating menu bar icon GIFs...")

// Idle (static, single frame shown twice for visibility)
let idleFrame = renderFrame { drawIdle(in: $0) }
writeGIF(name: "menu-bar-idle.gif", frames: [idleFrame, idleFrame], delay: 1.0)

// Recording
let recFrames = (0..<frameCount).map { i in renderFrame { drawRecording(in: $0, frame: i) } }
writeGIF(name: "menu-bar-recording.gif", frames: recFrames)

// Transcribing
let transFrames = (0..<frameCount).map { i in renderFrame { drawTranscribing(in: $0, frame: i) } }
writeGIF(name: "menu-bar-transcribing.gif", frames: transFrames)

// Diarizing
let diarFrames = (0..<frameCount).map { i in renderFrame { drawDiarizing(in: $0, frame: i) } }
writeGIF(name: "menu-bar-diarizing.gif", frames: diarFrames)

// Protocol
let protoFrames = (0..<frameCount).map { i in renderFrame { drawProtocol(in: $0, frame: i) } }
writeGIF(name: "menu-bar-protocol.gif", frames: protoFrames)

print("Done!")
