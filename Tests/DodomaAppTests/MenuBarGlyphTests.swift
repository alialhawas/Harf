import AppKit
import XCTest

@testable import DodomaAppKit

/// The status item's idle image.
///
/// `MenuBarGlyph.swift` is generated from a font that is not in this
/// repository, so nothing here can be checked by re-deriving it. What can be
/// checked is that the outline survived generation intact and sits where a
/// menu bar image has to sit: inside its box, upright, and big enough to read
/// as a letter rather than a speck.
final class MenuBarGlyphTests: XCTestCase {
    private let box = NSRect(x: 0, y: 0, width: 18, height: 18)

    func testTheImageIsAnEighteenPointTemplate() {
        let image = MenuBarGlyph.image()
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        // Without this the glyph keeps its own colour and stays teal when the
        // menu bar inverts under selection or a dark appearance.
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "Harf")
    }

    func testThePathIsNotEmpty() {
        XCTAssertGreaterThan(MenuBarGlyph.path().elementCount, 0)
        XCTAssertFalse(MenuBarGlyph.path().isEmpty)
    }

    func testThePathStaysInsideItsBox() {
        let bounds = MenuBarGlyph.path().bounds
        XCTAssertTrue(box.contains(bounds), "\(bounds) escapes \(box)")
    }

    /// A generator that emitted the letter at the wrong scale, or flipped it
    /// out of the box and back by the width of a rounding error, would still
    /// produce a path that draws. This is what would catch it.
    func testTheLetterFillsMostOfTheBox() {
        let bounds = MenuBarGlyph.path().bounds
        XCTAssertGreaterThan(bounds.height, box.height / 2)
        XCTAssertGreaterThan(bounds.width, box.width / 3)
    }

    /// The image draws in an unflipped context, so the path has to be y-up.
    /// A y-down path built for SVG would put the letter's mass below the
    /// baseline rather than above the box's midline, which is what an
    /// upside-down ح looks like numerically.
    func testTheLetterIsCentredRatherThanClingingToAnEdge() {
        let bounds = MenuBarGlyph.path().bounds
        XCTAssertEqual(bounds.midX, box.midX, accuracy: 1.0)
        XCTAssertEqual(bounds.midY, box.midY, accuracy: 1.0)
    }

    func testTheImageRendersSomethingOpaque() throws {
        let image = MenuBarGlyph.image()
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        representation.size = NSSize(width: 36, height: 36)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()

        var covered = 0
        for x in 0..<36 {
            for y in 0..<36 where (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                covered += 1
            }
        }
        XCTAssertGreaterThan(covered, 36 * 36 / 20, "the glyph drew almost nothing")
    }
}
