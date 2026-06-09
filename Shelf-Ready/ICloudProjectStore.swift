//
//  ICloudProjectStore.swift
//  Shelf-Ready
//
//  Cross-device hand-off layer. Each Shelf project gets a folder in the app's iCloud Drive
//  container — <container>/Documents/<Name (id)>/ — holding the screenshot image files plus
//  a manifest.json describing each shot (order, device class, fit mode). The folder is the
//  durable, visible, portable home; SwiftData stays the in-app working index.
//
//   • EXPORT  (SwiftData project -> folder): mirror a project out to iCloud Drive after a
//     change, so it syncs to the user's other devices and is browsable in Files/Finder.
//   • IMPORT  (folder -> SwiftData): on launch, pull in any project that isn't already in
//     the local store — that's "pick it up on another device." Non-destructive, import-only.
//
//  Fail-safe iCloud resolution: if the iCloud Documents capability isn't enabled yet (or the
//  user isn't signed into iCloud), it falls back to the app's LOCAL Documents directory, so
//  nothing crashes and single-device use still works. Cross-device sync switches on by itself
//  once the iCloud Documents capability + container are enabled in Xcode — no code change.
//
//  Images in the project folder are named by the shot's stable UUID, so reordering only
//  rewrites the (tiny) manifest, never the images — keeps iCloud upload churn low. The
//  numbered/grouped ASC upload export is a separate step (see ContentView.handleExport).
//

import Foundation
import SwiftData

enum ICloudProjectStore {

    // MARK: - Container / folder layout

    /// Cached projects-root URL, resolved once off the main thread (see `prepare()`).
    private static var cachedRoot: URL?

    /// Resolve the projects root — iCloud Drive Documents when available, else local Documents.
    /// Apple warns `url(forUbiquityContainerIdentifier:)` can block, so this runs OFF the main
    /// thread and caches the result. Call once at launch before the first export/import.
    static func prepare() async {
        let resolved = await Task.detached { () -> URL? in
            let fm = FileManager.default
            if let ubiquity = fm.url(forUbiquityContainerIdentifier: nil) {
                let docs = ubiquity.appendingPathComponent("Documents", isDirectory: true)
                try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
                return docs
            }
            return fm.urls(for: .documentDirectory, in: .userDomainMask).first
        }.value
        cachedRoot = resolved
    }

    /// The folder that holds one subfolder per project. Uses the cached root once `prepare()`
    /// has run; before that, falls back to local Documents (never the blocking iCloud call).
    static func projectsRoot() -> URL? {
        if let cachedRoot { return cachedRoot }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// A filesystem-safe, human-recognizable folder name: the display name plus a short slice
    /// of the project's UUID (keeps folders unique + lets us find the same project after a rename).
    static func folderName(for project: ScreenshotProject) -> String {
        let safe = project.name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "Untitled" : safe
        return "\(base) (\(idTag(project.projectID)))"
    }

    private static func idTag(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// The folder this project SHOULD live at (based on its current name).
    static func folderURL(for project: ScreenshotProject) -> URL? {
        projectsRoot()?.appendingPathComponent(folderName(for: project), isDirectory: true)
    }

    /// The folder this project DOES live at, if any — found by its UUID tag, so a rename of the
    /// display name still locates the existing folder instead of orphaning it.
    static func existingFolderURL(for project: ScreenshotProject) -> URL? {
        guard let root = projectsRoot() else { return nil }
        let tag = "(\(idTag(project.projectID)))"
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.first { $0.lastPathComponent.contains(tag) }
    }

    // MARK: - Manifest

    struct Manifest: Codable {
        var projectID: UUID
        var name: String
        var createdAt: Date
        var updatedAt: Date
        var shots: [ShotEntry]

        struct ShotEntry: Codable {
            var shotID: UUID
            var filename: String          // image file within the project folder
            var order: Int
            var family: String?
            var orientation: String?
            var fitMode: String?
            var backgroundIsWhite: Bool
        }
    }

    // MARK: - Export (SwiftData project -> iCloud Drive folder)

    /// Mirror a project's screenshots + manifest into its iCloud Drive folder. Safe to call
    /// after any change. Images are written once (named by shot UUID); the manifest is always
    /// refreshed; image files for removed shots are pruned.
    @MainActor
    @discardableResult
    static func export(_ project: ScreenshotProject) -> Bool {
        let fm = FileManager.default

        // Locate the existing folder (by UUID tag) and rename it if the display name changed,
        // otherwise create the folder at the current name.
        let desired = folderURL(for: project)
        let dir: URL
        if let existing = existingFolderURL(for: project), let desired, existing != desired {
            try? fm.moveItem(at: existing, to: desired)
            dir = desired
        } else if let existing = existingFolderURL(for: project) {
            dir = existing
        } else if let desired {
            dir = desired
        } else {
            return false
        }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }

        var entries: [Manifest.ShotEntry] = []
        var keep = Set<String>()
        for shot in project.orderedShots {
            guard let data = shot.imageData else { continue }
            let filename = "\(shot.shotID.uuidString).png"
            keep.insert(filename)
            let fileURL = dir.appendingPathComponent(filename)
            if !fm.fileExists(atPath: fileURL.path) {
                if let cg = ScreenshotProcessor.loadCGImage(from: data),
                   let png = try? ScreenshotProcessor.encode(cg, as: .png) {
                    try? png.write(to: fileURL)
                } else {
                    try? data.write(to: fileURL)   // last resort: original bytes
                }
            }
            entries.append(.init(shotID: shot.shotID,
                                 filename: filename,
                                 order: shot.order,
                                 family: shot.familyRaw,
                                 orientation: shot.orientationRaw,
                                 fitMode: shot.fitModeRaw,
                                 backgroundIsWhite: shot.backgroundIsWhite))
        }

        // Prune image files whose shot is gone.
        let onDisk = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in onDisk where file.pathExtension.lowercased() == "png" && !keep.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }

        let manifest = Manifest(projectID: project.projectID,
                                name: project.name,
                                createdAt: project.createdAt,
                                updatedAt: project.updatedAt,
                                shots: entries)
        guard let json = try? Self.encoder.encode(manifest) else { return false }
        try? json.write(to: dir.appendingPathComponent("manifest.json"))
        return true
    }

    /// Remove a project's iCloud Drive folder (called when the project is deleted, so the
    /// launch importer doesn't resurrect it).
    @MainActor
    static func deleteFolder(for project: ScreenshotProject) {
        if let url = existingFolderURL(for: project) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Import (iCloud Drive folders -> SwiftData)

    /// Pull in every project folder that isn't already in the local store (matched by
    /// projectID). Import-only and non-destructive — never deletes or overwrites a local
    /// project. This is the "hand it off, pick it up on another device" path.
    @MainActor
    static func importMissing(into context: ModelContext) {
        let fm = FileManager.default
        guard let root = projectsRoot(),
              let folders = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }

        let existing = Set((try? context.fetch(FetchDescriptor<ScreenshotProject>()))?.map(\.projectID) ?? [])

        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let manifestURL = folder.appendingPathComponent("manifest.json")
            try? fm.startDownloadingUbiquitousItem(at: manifestURL)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? Self.decoder.decode(Manifest.self, from: data),
                  !existing.contains(manifest.projectID) else { continue }

            let project = ScreenshotProject(name: manifest.name)
            project.projectID = manifest.projectID
            project.createdAt = manifest.createdAt
            project.updatedAt = manifest.updatedAt
            context.insert(project)

            for entry in manifest.shots.sorted(by: { $0.order < $1.order }) {
                let imageURL = folder.appendingPathComponent(entry.filename)
                try? fm.startDownloadingUbiquitousItem(at: imageURL)
                let shot = Shot(imageData: try? Data(contentsOf: imageURL), sourceFilename: entry.filename)
                shot.shotID = entry.shotID
                shot.order = entry.order
                shot.familyRaw = entry.family
                shot.orientationRaw = entry.orientation
                shot.fitModeRaw = entry.fitMode
                shot.backgroundIsWhite = entry.backgroundIsWhite
                shot.project = project
                context.insert(shot)
            }
        }
    }

    // MARK: - JSON

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
