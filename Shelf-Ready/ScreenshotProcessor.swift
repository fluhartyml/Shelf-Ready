//
//  ScreenshotProcessor.swift
//  Shelf-Ready
//
//  The resize/format engine: turn a raw screenshot into an App Store Connect-compliant
//  image at an exact ScreenshotSize. Cross-platform on purpose — built on CoreGraphics +
//  ImageIO only (no UIKit/AppKit), so the one Multiplatform target compiles identically
//  for iPad, Mac, and Vision.
//
//  Compliance guarantees per render:
//   • Output is exactly the target pixel dimensions (App Store Connect rejects 1px off).
//   • Output is opaque sRGB with NO alpha channel (drawn onto an opaque background).
//   • Exported as PNG (or JPEG) per AppStoreSpec.Format.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum FitMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Scale to fit inside the target, letterbox the remainder with the background color.
    /// Never crops content — safest default for screenshots.
    case fit
    /// Scale to fill the target, center-crop the overflow. No bars, but edges are lost.
    case fill
    /// Resample straight to the target dimensions, ignoring aspect. Use only when the
    /// source is already the correct aspect (e.g. a true device/simulator screenshot).
    case exact

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit:   return "Fit (letterbox)"
        case .fill:  return "Fill (crop)"
        case .exact: return "Exact (resample)"
        }
    }
}

struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double, green: Double, blue: Double
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)
}

enum ScreenshotProcessorError: LocalizedError {
    case cannotReadImage(URL)
    case cannotCreateContext
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .cannotReadImage(let url): return "Couldn't read an image at \(url.lastPathComponent)."
        case .cannotCreateContext:      return "Couldn't create the drawing context."
        case .cannotEncode:             return "Couldn't encode the processed image."
        }
    }
}

enum ScreenshotProcessor {

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Loading

    /// Load a CGImage from a file URL without UIKit/AppKit.
    static func loadCGImage(from url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ScreenshotProcessorError.cannotReadImage(url) }
        return image
    }

    /// Load a CGImage from in-memory image data (what Shot stores).
    static func loadCGImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return image
    }

    static func pixelSize(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }

    // MARK: Rendering to an exact spec size

    /// Render `source` to exactly `target.pixelSize`, opaque sRGB, using `mode`.
    static func render(_ source: CGImage,
                       to target: ScreenshotSize,
                       mode: FitMode,
                       background: RGBAColor = .black) throws -> CGImage {
        let w = target.width
        let h = target.height

        // Opaque context (no alpha) in sRGB — this is what flattens alpha + fixes color space.
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ScreenshotProcessorError.cannotCreateContext }

        ctx.interpolationQuality = .high

        // Fill the opaque background first (becomes the letterbox bars in .fit).
        ctx.setFillColor(red: background.red, green: background.green,
                         blue: background.blue, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let drawRect = destinationRect(sourceW: source.width, sourceH: source.height,
                                       targetW: w, targetH: h, mode: mode)

        if mode == .fill {
            // Clip to the target so center-crop overflow is discarded.
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.draw(source, in: drawRect)

        guard let out = ctx.makeImage() else { throw ScreenshotProcessorError.cannotCreateContext }
        return out
    }

    /// Compute where to draw the source inside the target for the given mode.
    private static func destinationRect(sourceW: Int, sourceH: Int,
                                        targetW: Int, targetH: Int,
                                        mode: FitMode) -> CGRect {
        let sw = CGFloat(sourceW), sh = CGFloat(sourceH)
        let tw = CGFloat(targetW), th = CGFloat(targetH)

        switch mode {
        case .exact:
            return CGRect(x: 0, y: 0, width: tw, height: th)
        case .fit:
            let scale = min(tw / sw, th / sh)
            let dw = sw * scale, dh = sh * scale
            return CGRect(x: (tw - dw) / 2, y: (th - dh) / 2, width: dw, height: dh)
        case .fill:
            let scale = max(tw / sw, th / sh)
            let dw = sw * scale, dh = sh * scale
            return CGRect(x: (tw - dw) / 2, y: (th - dh) / 2, width: dw, height: dh)
        }
    }

    // MARK: Encoding

    enum OutputFormat: String, CaseIterable, Codable, Identifiable, Sendable {
        case png, jpeg
        var id: String { rawValue }
        var utType: UTType { self == .png ? .png : .jpeg }
        var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    /// Encode to PNG/JPEG data. Output carries no alpha (the render context is opaque).
    static func encode(_ image: CGImage, as format: OutputFormat, jpegQuality: Double = 0.95) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, format.utType.identifier as CFString, 1, nil
        ) else { throw ScreenshotProcessorError.cannotEncode }

        var options: [CFString: Any] = [:]
        if format == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = jpegQuality }

        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ScreenshotProcessorError.cannotEncode }
        return data as Data
    }

    // MARK: Device-class auto-detect

    /// Best-guess device family + orientation for a raw screenshot, by matching aspect ratio
    /// against the accepted sizes. Returns nil if nothing is a close match.
    static func detectFamily(forPixelSize size: CGSize) -> (family: DeviceFamily, orientation: ScreenOrientation)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let ratio = Double(size.width) / Double(size.height)

        var best: (DeviceFamily, ScreenOrientation, Double)? = nil
        for spec in AppStoreSpec.all {
            for accepted in spec.acceptedSizes {
                let diff = abs(accepted.aspectRatio - ratio)
                if best == nil || diff < best!.2 {
                    best = (spec.family, accepted.orientation, diff)
                }
            }
        }
        // Only accept a match within a small aspect tolerance (~3%).
        guard let b = best, b.2 < 0.03 else { return nil }
        return (b.0, b.1)
    }
}
