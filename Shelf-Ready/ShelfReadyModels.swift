//
//  ShelfReadyModels.swift
//  Shelf-Ready
//
//  SwiftData model, written CloudKit-compatible so projects sync across iPad/Mac:
//   • every stored property is optional or has a default value
//   • no @Attribute(.unique)
//   • relationships are optional and have an inverse
//   • large image blobs use .externalStorage (CloudKit stores them as assets)
//

import Foundation
import SwiftData

/// One app's App Store submission set — the screenshots being prepared for a single app.
@Model
final class ScreenshotProject {
    var name: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \Shot.project)
    var shots: [Shot]? = []

    /// The app's icon, edited in the layered icon editor (one per app).
    @Relationship(deleteRule: .cascade, inverse: \IconDocument.project)
    var iconDocument: IconDocument?

    init(name: String = "Untitled App") {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Shots ordered by their assigned upload order.
    var orderedShots: [Shot] {
        (shots ?? []).sorted { $0.order < $1.order }
    }
}

/// One screenshot within a project: the source image plus how it should be processed
/// and where it sits in the upload order.
@Model
final class Shot {
    /// Original imported image bytes (PNG/JPEG). CloudKit stores this as an asset.
    @Attribute(.externalStorage) var imageData: Data?

    var sourceFilename: String?
    var addedAt: Date = Date()

    /// Upload order within its device-class group (drives the numeric filename prefix).
    var order: Int = 0

    // Enums are stored as raw strings for CloudKit; typed access via computed vars below.
    var familyRaw: String?
    var orientationRaw: String?
    var fitModeRaw: String?
    var backgroundIsWhite: Bool = false   // letterbox bar color for .fit mode

    var project: ScreenshotProject?

    init(imageData: Data? = nil, sourceFilename: String? = nil) {
        self.imageData = imageData
        self.sourceFilename = sourceFilename
        self.addedAt = Date()
    }

    // MARK: Typed accessors over the raw-string storage

    var family: DeviceFamily? {
        get { familyRaw.flatMap(DeviceFamily.init(rawValue:)) }
        set { familyRaw = newValue?.rawValue }
    }

    var orientation: ScreenOrientation {
        get { orientationRaw.flatMap(ScreenOrientation.init(rawValue:)) ?? .portrait }
        set { orientationRaw = newValue.rawValue }
    }

    var fitMode: FitMode {
        get { fitModeRaw.flatMap(FitMode.init(rawValue:)) ?? .fit }
        set { fitModeRaw = newValue.rawValue }
    }

    var background: RGBAColor { backgroundIsWhite ? .white : .black }
}
