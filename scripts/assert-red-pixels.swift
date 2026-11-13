#!/usr/bin/env swift
// Visual regression assertion for the menu-bar red-tint indicator.
//
// Loads a PNG and counts pixels that are clearly red: red above 150, at
// least 50 above green and at least 40 above blue.
//
// Both margins are measured on the Mac mini self-hosted runner. The tint is
// `NSColor.systemRed`; in the captured menu bar its pixels ran from the
// antialiased edge (184, 126, 138) to the core (255, 79, 68), and an earlier
// dark-mode capture blended it to about (187, 94, 104). The menu bar is
// translucent, so the strip also shows the wallpaper: a warm region of it sat
// at about (150, 122, 112), red at most 27 above green. A margin of 20 over
// green alone counted some 1500 of those pixels against a threshold of 30, so
// the check passed whatever the icon showed. The blue margin keeps pink and
// magenta out.
//
// Still counted: any other clearly red or orange mark in the strip. That
// covers the app's own permission badge, error badge and record-only dot, the
// system's recording indicators, and a wallpaper that is red or orange behind
// the menu bar. The channel-health lane rules out the permission badge only.
// Cropping the capture to the status item, or comparing against a capture
// without the tint, would remove the dependence on what else is in the strip.
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
// Bytes, not samples: a PNG without alpha loads with three samples in a
// four-byte pixel, and stepping by samples would read across pixels.
let bytesPerPixel = rep.bitsPerPixel / 8
// The loop below reads one byte per sample with red first.
guard rep.bitsPerSample == 8, !rep.bitmapFormat.contains(.alphaFirst) else {
    die("FAIL: unsupported bitmap layout (bitsPerSample \(rep.bitsPerSample), format \(rep.bitmapFormat.rawValue))")
}
let bytesPerRow = rep.bytesPerRow
var redCount = 0

for y in 0 ..< height {
    let row = pixels.advanced(by: y * bytesPerRow)
    for x in 0 ..< width {
        let p = row.advanced(by: x * bytesPerPixel)
        let r = Int(p[0])
        let g = Int(p[1])
        let b = Int(p[2])
        if r > 150, r > g + 50, r > b + 40 {
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
