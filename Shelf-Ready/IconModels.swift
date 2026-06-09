//
//  IconModels.swift
//  Shelf-Ready
//
//  Nondestructive, layered icon document (Photoshop-style): a square canvas with an
//  ordered stack of layers that are NEVER flattened — they're composited only at export,
//  so every edit stays reversible. Combined with SwiftData's UndoManager (wired in the
//  App), this gives per-layer undo/redo history.
//
//  CloudKit-compatible like the rest of the model: optional/defaulted properties,
//  no unique constraints, optional inverse relationship, .externalStorage blobs.
//

import Foundation
import SwiftData
import CoreGraphics

@Model
final class IconDocument {
    var name: String = "App Icon"
    /// Canvas is always square; this is the master edge length in points (icons render at 1024).
    var canvasSize: Int = 1024
    var backgroundHex: String = "#000000"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// The app this icon belongs to (optional inverse of ScreenshotProject.iconDocument).
    var project: ScreenshotProject?

    @Relationship(deleteRule: .cascade, inverse: \IconLayer.document)
    var layers: [IconLayer]? = []

    init(name: String = "App Icon") {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Layers bottom-to-top (draw order).
    var orderedLayers: [IconLayer] {
        (layers ?? []).sorted { $0.order < $1.order }
    }
}

/// Light/Dark are mutually-exclusive mode variants for a background layer: the editor shows one
/// at a time, and Save flattens both. (See the icon-layer model in the DeveloperNotes.)
enum IconAppearance: String, Codable, CaseIterable, Hashable { case light, dark }

@Model
final class IconLayer {
    enum Kind: String, Codable, CaseIterable { case symbol, image, pixel, background }

    var order: Int = 0
    var kindRaw: String = "symbol"

    /// User-editable layer name. Empty -> fall back to the kind-based default (see displayName).
    var name: String = ""
    /// For .background layers: which appearance this background is shown in (light/dark); nil otherwise.
    var appearanceRaw: String?

    /// Symbol layer: an SF Symbol name (Michael builds icons mainly from SF Symbols in layers).
    var symbolName: String?
    /// Image layer: imported artwork.
    @Attribute(.externalStorage) var imageData: Data?

    // Pixel layer: a square paint grid used ONLY for creation (hand-drawing artwork). The
    // chunky grid is an editing aid; in the final icon the layer composites at FULL resolution
    // (smoothed) to match the other full-res layers — not blocky. RGBA8 row-major buffer
    // (pixelGridSize² × 4 bytes); nil = empty/clear.
    var pixelGridSize: Int = 128
    @Attribute(.externalStorage) var pixelData: Data?

    var colorHex: String = "#FFFFFF"      // tint for symbol layers
    var opacity: Double = 1.0
    var isVisible: Bool = true

    // Transform, normalized to the canvas (0…1 center, scale = fraction of canvas edge).
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var scale: Double = 0.6
    var rotationDegrees: Double = 0.0

    var document: IconDocument?

    init(kind: Kind = .symbol, symbolName: String? = nil, imageData: Data? = nil) {
        self.kindRaw = kind.rawValue
        self.symbolName = symbolName
        self.imageData = imageData
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .symbol }
        set { kindRaw = newValue.rawValue }
    }

    var appearance: IconAppearance? {
        get { appearanceRaw.flatMap(IconAppearance.init(rawValue:)) }
        set { appearanceRaw = newValue?.rawValue }
    }

    var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .symbol:     return symbolName ?? "Symbol"
        case .image:      return "Image"
        case .pixel:      return "Pixel \(pixelGridSize)×\(pixelGridSize)"
        case .background: return appearance == .dark ? "Dark Mode Background" : "Light Mode Background"
        }
    }
}

// MARK: - Pixel grid helpers (CoreGraphics, cross-platform)

/// Turns a pixel layer's RGBA8 buffer into a CGImage for nearest-neighbor compositing, plus
/// blank-buffer and hex→bytes helpers. No UIKit/AppKit — same as the rest of the engine, so the
/// one Multiplatform target compiles for iPad, Mac, and Vision alike.
enum PixelGrid {
    static let bytesPerPixel = 4
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A fully-transparent buffer for a size×size grid.
    static func blank(size: Int) -> Data {
        Data(count: max(1, size * size * bytesPerPixel))
    }

    /// Build a CGImage from an RGBA8 (premultiplied) row-major buffer. Our paint is either
    /// fully opaque (a = 255) or fully clear (all 0), so straight == premultiplied here.
    static func cgImage(from data: Data?, size: Int) -> CGImage? {
        guard size > 0 else { return nil }
        let count = size * size * bytesPerPixel
        let buffer = data ?? blank(size: size)
        guard buffer.count == count, let provider = CGDataProvider(data: buffer as CFData) else { return nil }
        return CGImage(
            width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * bytesPerPixel,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// (r,g,b,a) bytes for a "#RRGGBB" hex string.
    static func rgba(fromHex hex: String, alpha: UInt8 = 255) -> (UInt8, UInt8, UInt8, UInt8) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        guard s.count == 6 else { return (0, 0, 0, alpha) }
        return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF), alpha)
    }
}
