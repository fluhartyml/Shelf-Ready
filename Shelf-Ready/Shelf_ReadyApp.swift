//
//  Shelf_ReadyApp.swift
//  Shelf-Ready
//
//  Created by Michael Fluharty on 6/7/26.
//

import SwiftUI
import SwiftData

@main
struct Shelf_ReadyApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ScreenshotProject.self,
            Shot.self,
            IconDocument.self,
            IconLayer.self,
        ])
        // Try the CloudKit-backed store first (syncs projects across iPad/Mac).
        // Fall back to a local-only store, then in-memory, so the app ALWAYS launches
        // even if iCloud isn't configured or signed in yet (fail-safe, no crash).
        func makeContainer() -> ModelContainer {
            let cloud = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
                return container
            }
            let local = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
            if let container = try? ModelContainer(for: schema, configurations: [local]) {
                return container
            }
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memory])
        }
        let container = makeContainer()
        // No app-wide UndoManager. SwiftData's built-in undo snapshots the ENTIRE data store
        // and crashes when deleting a set (it tries to snapshot the set's lazily-loaded
        // IconDocument link). It also wasn't the undo Michael wants — his intended undo is a
        // separate, scoped build, to his own spec. Removed 2026-06-09; ⌘Z is off until then.
        return container
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
