//
// make-icon.swift
//
// Renders a source image into a macOS `.iconset` directory.
//
// Why this exists rather than plain `sips` resizing: a raw square bitmap is not
// what a macOS app icon looks like. Apple's icon geometry for Big Sur and later is
// a rounded rectangle ("squircle") inset inside a transparent canvas — the artwork
// occupies 824×824 of a 1024×1024 canvas with a corner radius of 185.4pt. Only
// applying that mask makes a photo read as a native app icon; the system does not
// round arbitrary bitmaps for you.
//
// Usage: swift make-icon.swift <input-image> <output.iconset>
//
import AppKit
import CoreGraphics
import Foundation

// MARK: - Icon geometry

/// Full icon canvas, in pixels at 1x.
let canvasSide: CGFloat = 1024

/// How the artwork is placed inside the canvas.
enum IconGeometry: String {
    /// Apple's standard layout: artwork inset inside the canvas, leaving a
    /// transparent margin all round. This is what stock macOS icons look like.
    case inset
    /// Artwork fills the entire canvas, with the corners rounded to the same
    /// curvature. No margin is wasted and it still reads as a macOS icon.
    case full
    /// Artwork fills the entire canvas with square corners.
    case sharp
}

/// Apple's standard: 824px artwork inside a 1024px canvas.
let standardArtworkRatio: CGFloat = 824.0 / 1024.0
/// Apple's standard corner radius, for that 824px artwork.
let standardCornerRadius: CGFloat = 185.4
/// Corner radius relative to the artwork side, taken from Apple's standard
/// geometry so a full-bleed icon keeps the same visual curvature.
let squircleRadiusRatio: CGFloat = standardCornerRadius / 824.0

// MARK: - Arguments

let arguments = CommandLine.arguments

guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: swift make-icon.swift <input-image> <output.iconset> [full|inset|sharp]\n".utf8)
    )
    exit(2)
}

let inputPath = arguments[1]
let iconsetPath = arguments[2]

// Defaults to `full`: the artwork fills the whole icon, with no transparent
// margin. Pass `inset` for Apple's stock inset layout, or `sharp` for square
// corners.
let geometryArgument = arguments.count >= 4 ? arguments[3] : IconGeometry.full.rawValue
guard let geometry = IconGeometry(rawValue: geometryArgument) else {
    FileHandle.standardError.write(
        Data("error: unknown geometry '\(geometryArgument)' (expected full, inset or sharp)\n".utf8)
    )
    exit(2)
}

guard let sourceImage = NSImage(contentsOfFile: inputPath) else {
    FileHandle.standardError.write(Data("error: cannot read image at \(inputPath)\n".utf8))
    exit(1)
}

guard let source = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("error: cannot decode image at \(inputPath)\n".utf8))
    exit(1)
}

// MARK: - Trimming transparent borders

/// Alpha at or below this counts as "invisible".
///
/// A small non-zero threshold keeps near-invisible stray pixels or compression
/// noise at the edges from defeating the trim.
let alphaThreshold: UInt8 = 8

/// Bounding box of everything visible in `image`, in **top-left** coordinates.
///
/// Verified against a probe rather than assumed: for a `premultipliedLast`
/// bitmap context, memory row 0 is the *top* of the image, and
/// `CGImage.cropping(to:)` takes a top-left-origin rect. Both agree, so no manual
/// vertical flip is required — and getting that wrong would silently mirror the
/// artwork.
///
/// - Returns: `nil` when nothing is visible.
func visibleBounds(of image: CGImage) -> CGRect? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width
    var maxX = -1
    var minY = height
    var maxY = -1

    for y in 0..<height {
        let rowStart = y * width * 4
        for x in 0..<width where pixels[rowStart + x * 4 + 3] > alphaThreshold {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Source image with any transparent border removed, so the visible artwork can
/// fill the icon canvas.
///
/// Trimming is on by default because a source with a transparent border would
/// otherwise sit inset inside the icon with no way to tell why. It can be turned
/// off for artwork that *should* float with padding, via the `no-trim` argument
/// (or `ICON_TRIM=0` in the build script).
let trimArgument = arguments.count >= 5 ? arguments[4] : "trim"
let shouldTrim = trimArgument != "no-trim"

let sourceBounds = shouldTrim ? visibleBounds(of: source) : nil
let artwork: CGImage
if let bounds = sourceBounds, bounds.width >= 8, bounds.height >= 8,
   bounds.width != CGFloat(source.width) || bounds.height != CGFloat(source.height) {
    // `cropping(to:)` is top-left origin, matching `visibleBounds`.
    artwork = source.cropping(to: bounds) ?? source
    print("""
          trimmed transparent border: \(source.width)x\(source.height) \
          -> \(Int(bounds.width))x\(Int(bounds.height)) \
          (insets left \(Int(bounds.minX)) top \(Int(bounds.minY)))
          """)
} else {
    artwork = source
}

// MARK: - Rendering

/// Draws the artwork at `side` pixels with the chosen icon geometry.
///
/// The artwork is scaled to **fill** the target rect and centre-cropped, matching
/// how macOS icons treat non-square artwork, rather than squashing it to fit.
func renderIcon(side: Int, geometry: IconGeometry) -> CGImage? {
    let pixelSide = CGFloat(side)

    // Artwork size and corner curvature, per geometry.
    let artworkRatio: CGFloat
    let cornerRatio: CGFloat
    switch geometry {
    case .inset:
        artworkRatio = standardArtworkRatio
        cornerRatio = squircleRadiusRatio
    case .full:
        artworkRatio = 1
        cornerRatio = squircleRadiusRatio
    case .sharp:
        artworkRatio = 1
        cornerRatio = 0
    }

    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    // Start fully transparent so the inset margin stays clear.
    context.clear(CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide))
    context.interpolationQuality = .high

    let artworkSidePixels = pixelSide * artworkRatio
    let inset = (pixelSide - artworkSidePixels) / 2
    let artworkRect = CGRect(
        x: inset,
        y: inset,
        width: artworkSidePixels,
        height: artworkSidePixels
    )

    // Clip to the rounded rectangle before drawing, so the artwork itself is
    // masked rather than a mask being composited on top of it.
    let mask = CGPath(
        roundedRect: artworkRect,
        cornerWidth: artworkSidePixels * cornerRatio,
        cornerHeight: artworkSidePixels * cornerRatio,
        transform: nil
    )
    context.addPath(mask)
    context.clip()

    // Aspect-fill: scale so the smaller dimension covers the target rect, then
    // centre the overflow.
    let sourceWidth = CGFloat(artwork.width)
    let sourceHeight = CGFloat(artwork.height)
    let fillScale = max(artworkSidePixels / sourceWidth, artworkSidePixels / sourceHeight)
    let drawnWidth = sourceWidth * fillScale
    let drawnHeight = sourceHeight * fillScale
    let drawRect = CGRect(
        x: artworkRect.midX - drawnWidth / 2,
        y: artworkRect.midY - drawnHeight / 2,
        width: drawnWidth,
        height: drawnHeight
    )
    context.draw(artwork, in: drawRect)

    return context.makeImage()
}

/// The `.iconset` members `iconutil` expects, as (filename, pixel side) pairs.
let variants: [(name: String, side: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - Write

let fileManager = FileManager.default
let iconsetURL = URL(fileURLWithPath: iconsetPath)

try? fileManager.removeItem(at: iconsetURL)
do {
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(
        Data("error: cannot create \(iconsetPath): \(error.localizedDescription)\n".utf8)
    )
    exit(1)
}

for variant in variants {
    guard let image = renderIcon(side: variant.side, geometry: geometry) else {
        FileHandle.standardError.write(
            Data("error: could not render \(variant.name)\n".utf8)
        )
        exit(1)
    }

    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(
            Data("error: could not encode \(variant.name)\n".utf8)
        )
        exit(1)
    }

    let destination = iconsetURL.appendingPathComponent(variant.name)
    do {
        try data.write(to: destination)
    } catch {
        FileHandle.standardError.write(
            Data("error: cannot write \(variant.name): \(error.localizedDescription)\n".utf8)
        )
        exit(1)
    }
}

print("rendered \(variants.count) variants into \(iconsetPath) (\(geometry.rawValue))" )
