#!/usr/bin/env swift
// Visual regression assertion for the menu-bar red-tint indicator.
//
// Loads a PNG and counts pixels that look meaningfully red.
// Tuned against the Mac mini self-hosted runner's actual output:
// `NSColor.systemRed` in the menu-bar context blends with the dark-mode
// background and the display's colour profile, producing pixels around
// (187, 94, 104) rather than the source (255, 59, 48). Threshold of
// "R > 150 AND R > G + 20" catches those without false-positiving on
// the macOS recording indicator (small, far fewer pixels) or the
// apple-logo highlight.
//
// Usage: scripts/assert-red-pixels.swift <png-path> [--min-count N]
// Exits 0 on pass, 1 on fail, 2 on usage error.

import AppKit
import Foundation

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    die("usage: assert-red-pixels.swift <png-path> [--min-count N]", code: 2)
}
let path = args[1]
var minCount = 30

var i = 2
while i < args.count {
    if args[i] == "--min-count", i + 1 < args.count, let n = Int(args[i + 1]) {
        minCount = n
        i += 2
    } else {
        die("unknown arg: \(args[i])", code: 2)
    }
}

// Load the PNG directly via NSBitmapImageRep — skips the NSImage →
// tiffRepresentation → NSBitmapImageRep round-trip that allocates an
// intermediate TIFF buffer the size of the source image.
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let source = NSBitmapImageRep(data: data) else {
    die("FAIL: could not load PNG at \(path)")
}

// Normalise to device RGB so the R/G thresholds compare against a
// consistent colour space regardless of the PNG's embedded profile.
// `NSBitmapImageRep.converting` can return nil if the source format is
// already a compatible match — fall back to the original rep in that case.
let rep = source.converting(to: NSColorSpace.deviceRGB, renderingIntent: .default) ?? source

guard let pixels = rep.bitmapData else {
    die("FAIL: bitmap has no raw pixel buffer")
}

let width = rep.pixelsWide
let height = rep.pixelsHigh
let samplesPerPixel = rep.samplesPerPixel
let bytesPerRow = rep.bytesPerRow
var redCount = 0

for y in 0 ..< height {
    let row = pixels.advanced(by: y * bytesPerRow)
    for x in 0 ..< width {
        let p = row.advanced(by: x * samplesPerPixel)
        let r = Int(p[0])
        let g = Int(p[1])
        if r > 150, r > g + 20 {
            redCount += 1
        }
    }
}

print("Red pixels in \(width)x\(height) image: \(redCount) (threshold: \(minCount))")

if redCount < minCount {
    die("FAIL: expected ≥\(minCount) red pixels in menubar screenshot, got \(redCount). " +
        "AppState flag may be true but the SwiftUI scene body / MenuBarIcon render path is broken.")
}

print("OK — red-tint rendered (\(redCount) systemRed pixels detected)")
