#!/usr/bin/env swift
//
// Rasterise docs/brand/harf-icon.svg into Resources/AppIcon.icns.
//
// Run as:  swift Tools/build-icon.swift        (or `make brand`)
//
// AppKit has read SVG since macOS 14, so the 1024pt master that
// Tools/build-brand.py emits is the only source; there are no intermediate
// PNGs in the repository and nothing to keep in step by hand.
//
// The drawing goes into an NSBitmapImageRep that has an alpha channel,
// deliberately. An app icon is a rounded tile on nothing, and every shortcut
// for this — qlmanage, sips against an SVG — composites onto white first, so
// the corners come out as four white triangles that are only visible once the
// icon is on a coloured Dock. The iconset itself is built in a temporary
// directory: it is derived output, and nothing but the .icns belongs in the
// tree.

import AppKit
import Foundation

/// The ten representations `iconutil` expects. macOS picks among them by
/// point size and backing scale; omitting any of them makes the Finder
/// upscale a smaller one.
let representations: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let source = repositoryRoot.appendingPathComponent("docs/brand/harf-icon.svg")
let destination = repositoryRoot.appendingPathComponent("Resources/AppIcon.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard let artwork = NSImage(contentsOf: source) else {
    fail("could not read \(source.path). Run Tools/build-brand.py first.")
}

/// One square PNG with a transparent ground.
func render(_ image: NSImage, pixels: Int) -> Data {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else {
        fail("could not allocate a \(pixels)×\(pixels) bitmap")
    }
    representation.size = NSSize(width: pixels, height: pixels)

    guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
        fail("could not open a drawing context for \(pixels)×\(pixels)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        fail("could not encode the \(pixels)×\(pixels) PNG")
    }
    return data
}

let workingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("harf-icon-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = workingDirectory.appendingPathComponent("Harf.iconset")
try? FileManager.default.removeItem(at: workingDirectory)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workingDirectory) }

for (points, scale) in representations {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let name = "icon_\(points)x\(points)\(suffix).png"
    try render(artwork, pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    print("rendered   \(name) (\(points * scale)px)")
}

try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fail("iconutil exited with \(iconutil.terminationStatus)")
}

let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) ?? 0
print("wrote      Resources/AppIcon.icns (\(bytes) bytes)")
