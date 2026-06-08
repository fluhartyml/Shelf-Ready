//
//  AppStoreSpec.swift
//  Shelf-Ready
//
//  The authoritative App Store Connect screenshot/asset specification.
//
//  Verified against Apple's PRIMARY source on 2026-06-07:
//  developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
//  (Not aggregator blogs — App Store Connect rejects a submission that is even one
//  pixel off spec, so every number here is taken from Apple directly.)
//
//  Strategy encoded here: App Store Connect auto-scales DOWN from the largest size you
//  provide for a device family. So Shelf-Ready targets the single largest ("primary")
//  size per family by default; the smaller accepted sizes are retained for override.
//

import Foundation
import CoreGraphics

// MARK: - Orientation

enum ScreenOrientation: String, CaseIterable, Codable, Identifiable, Sendable {
    case portrait
    case landscape
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

// MARK: - A single accepted screenshot size

struct ScreenshotSize: Identifiable, Hashable, Codable, Sendable {
    let width: Int          // pixels, as the image must be in this orientation
    let height: Int
    let orientation: ScreenOrientation
    /// True if this is the size Shelf-Ready uploads by default for its family
    /// (the largest; Apple auto-scales the rest of the shelf from it).
    let isPrimary: Bool

    var id: String { "\(width)x\(height)" }
    var pixelSize: CGSize { CGSize(width: width, height: height) }
    var aspectRatio: Double { Double(width) / Double(height) }
    var label: String { "\(width) × \(height)" }

    init(_ width: Int, _ height: Int, _ orientation: ScreenOrientation, primary: Bool = false) {
        self.width = width
        self.height = height
        self.orientation = orientation
        self.isPrimary = primary
    }
}

// MARK: - Device families

enum DeviceFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case iPhone
    case iPad
    case appleTV
    case appleWatch
    case mac
    case visionPro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iPhone:     return "iPhone"
        case .iPad:       return "iPad"
        case .appleTV:    return "Apple TV"
        case .appleWatch: return "Apple Watch"
        case .mac:        return "Mac"
        case .visionPro:  return "Apple Vision Pro"
        }
    }

    /// SF Symbol used to represent the family in the UI.
    var symbolName: String {
        switch self {
        case .iPhone:     return "iphone"
        case .iPad:       return "ipad"
        case .appleTV:    return "appletv"
        case .appleWatch: return "applewatch"
        case .mac:        return "macbook"
        case .visionPro:  return "visionpro"
        }
    }

    /// Which orientations App Store Connect accepts for this family.
    var supportedOrientations: [ScreenOrientation] {
        switch self {
        case .iPhone, .iPad:
            return [.portrait, .landscape]
        case .appleTV, .mac, .visionPro:
            return [.landscape]          // landscape only
        case .appleWatch:
            return [.portrait]           // watch shelves are upright
        }
    }
}

// MARK: - Per-family spec

struct DeviceSpec: Identifiable, Sendable {
    let family: DeviceFamily
    /// All sizes App Store Connect accepts for this family, primary flagged.
    let acceptedSizes: [ScreenshotSize]
    /// Plain-language note shown to the user.
    let note: String

    var id: String { family.rawValue }
    var displayName: String { family.displayName }

    /// The default upload size(s) — the largest per orientation. Apple scales the rest down.
    func primarySizes(for orientation: ScreenOrientation) -> [ScreenshotSize] {
        acceptedSizes.filter { $0.orientation == orientation && $0.isPrimary }
    }

    func sizes(for orientation: ScreenOrientation) -> [ScreenshotSize] {
        acceptedSizes.filter { $0.orientation == orientation }
    }
}

// MARK: - The catalog

enum AppStoreSpec {

    // Format rules. Apple's page lists: .png/.jpg/.jpeg, 1–10 per device class.
    // Apple's screenshot page does NOT explicitly state a color-space / alpha rule, but
    // App Store Connect has historically rejected images carrying an alpha channel, so
    // Shelf-Ready flattens to opaque sRGB by default (safe for every family). If a real
    // upload ever bounces on this, re-verify against Apple and relax.
    enum Format {
        static let allowedExtensions = ["png", "jpg", "jpeg"]
        static let minPerDeviceClass = 1
        static let maxPerDeviceClass = 10
        static let flattenAlpha = true      // defensive default
        static let forceSRGB = true         // defensive default
    }

    static let all: [DeviceSpec] = [iPhone, iPad, appleTV, appleWatch, mac, visionPro]

    static func spec(for family: DeviceFamily) -> DeviceSpec {
        all.first { $0.family == family }!
    }

    // iPhone — primary 6.9"; 6.5" retained as the documented fallback shelf.
    static let iPhone = DeviceSpec(
        family: .iPhone,
        acceptedSizes: [
            ScreenshotSize(1320, 2868, .portrait, primary: true),
            ScreenshotSize(2868, 1320, .landscape, primary: true),
            ScreenshotSize(1284, 2778, .portrait),
            ScreenshotSize(2778, 1284, .landscape),
            ScreenshotSize(1242, 2688, .portrait),
            ScreenshotSize(2688, 1242, .landscape),
            ScreenshotSize(1179, 2556, .portrait),
            ScreenshotSize(2556, 1179, .landscape)
        ],
        note: "Upload the 6.9\" size (1320 × 2868). App Store Connect scales every smaller iPhone shelf from it."
    )

    // iPad — primary 13".
    static let iPad = DeviceSpec(
        family: .iPad,
        acceptedSizes: [
            ScreenshotSize(2064, 2752, .portrait, primary: true),
            ScreenshotSize(2752, 2064, .landscape, primary: true),
            ScreenshotSize(2048, 2732, .portrait),
            ScreenshotSize(2732, 2048, .landscape)
        ],
        note: "Upload the 13\" size (2064 × 2752). App Store Connect scales smaller iPad shelves from it."
    )

    // Apple TV — landscape only, HD or 4K. The pain point Shelf-Ready exists to remove.
    static let appleTV = DeviceSpec(
        family: .appleTV,
        acceptedSizes: [
            ScreenshotSize(3840, 2160, .landscape, primary: true),  // 4K
            ScreenshotSize(1920, 1080, .landscape)                  // 1080p
        ],
        note: "Landscape only. Upload 4K (3840 × 2160) or 1080p (1920 × 1080). Must show the tvOS interface, not a scaled-up phone screen."
    )

    // Apple Watch — upright; one size used across all localizations. Largest = Ultra 3.
    static let appleWatch = DeviceSpec(
        family: .appleWatch,
        acceptedSizes: [
            ScreenshotSize(422, 514, .portrait, primary: true),  // Ultra 3
            ScreenshotSize(416, 496, .portrait),                 // Series 11 / 10
            ScreenshotSize(410, 502, .portrait),                 // Ultra 2 / Ultra
            ScreenshotSize(396, 484, .portrait),                 // Series 9 / 8 / 7
            ScreenshotSize(368, 448, .portrait),                 // Series 6 / 5 / 4 / SE
            ScreenshotSize(312, 390, .portrait)                  // Series 3
        ],
        note: "Use one size consistently across every localization. Largest current shelf is Ultra 3 (422 × 514)."
    )

    // Mac — 16:10, landscape only.
    static let mac = DeviceSpec(
        family: .mac,
        acceptedSizes: [
            ScreenshotSize(2880, 1800, .landscape, primary: true),
            ScreenshotSize(2560, 1600, .landscape),
            ScreenshotSize(1440, 900, .landscape),
            ScreenshotSize(1280, 800, .landscape)
        ],
        note: "16:10 aspect ratio, landscape. Largest accepted is 2880 × 1800."
    )

    // Apple Vision Pro — single size.
    static let visionPro = DeviceSpec(
        family: .visionPro,
        acceptedSizes: [
            ScreenshotSize(3840, 2160, .landscape, primary: true)
        ],
        note: "Single size: 3840 × 2160, landscape."
    )
}
