//
//  DeveloperNotes.swift
//  Shelf-Ready
//
//  Persistent in-tree brief (per Michael's "every project gets a DeveloperNotes" rule).
//  Survives session resets: what this app is, why, and where it's going.
//

/*
 SHELF-READY — Developer Notes
 =============================

 Version:        0.1 (in development)
 Developer:      Michael Fluharty
 Engineered with: Claude (Anthropic), 100% Claude — no ChatGPT in the loop
 License:        (Michael to set)
 Created:        2026-06-07
 Platforms:      Multiplatform (iPad-primary; runs on Apple Silicon Mac + Vision)
 Bundle ID:      com.nightgard.Shelf-Ready

 MISSION
 -------
 Take the punishment out of App Store submission graphics. You feed Shelf-Ready the raw
 screenshots you took for your app; it resizes each to App Store Connect's strict per-device
 specs, lets you arrange them on a board and set their upload order, then exports a numbered,
 device-grouped set ready to drag into App Store Connect — plus your app icon.

 WHY IT EXISTS
 -------------
 Michael loves making Apple TV apps but AVOIDS shipping them because the App Store Connect
 image step (tvOS sizing especially) is so stressful. Shelf-Ready removes that barrier.
 Done-bar / proof of concept ("physician, heal thyself"): Shelf-Ready must prepare its OWN
 icon + screenshots and upload them to App Store Connect clean. It proves itself by shipping
 itself.

 ARCHITECTURE
 ------------
 • AppStoreSpec.swift     — authoritative ATC dimension table, verified 2026-06-07 against
                            Apple's primary source. Strategy: upload the largest per family,
                            Apple auto-scales the smaller shelves.
 • ScreenshotProcessor.swift — cross-platform resize/format engine (CoreGraphics + ImageIO,
                            no UIKit/AppKit). Fit/Fill/Exact, opaque sRGB flatten (no alpha),
                            PNG/JPEG, device-class auto-detect by aspect ratio.
 • ShelfReadyModels.swift — SwiftData model (ScreenshotProject ▸ Shot), CloudKit-compatible
                            (optional/defaulted props, no unique, optional inverse relationship,
                            .externalStorage image blobs). Syncs projects across iPad/Mac.
 • ContentView.swift      — project list + per-project board: import, auto-detect, reorder,
                            per-shot device/fit controls, export.

 ROADMAP
 -------
 v0.1  ▸ spec model ✓ · resize engine ✓ · models ✓ · import/board/export UI ✓ (compiles)
 v0.2  ▸ runtime-test on real screenshots · storyboard grid (vs list) · Apple TV first-class
         polish (4K/1080p, icon/Top Shelf) · app icon (SF Symbol layers) · Dynamic Type pass
 v0.3  ▸ dogfood: prepare Shelf-Ready's own submission with Shelf-Ready · App Store Connect
         record · submit

 ATTRIBUTION
 -----------
 Original work by Michael Fluharty, engineered with Claude. Spec data sourced from Apple's
 App Store Connect screenshot-specifications reference.

 SETUP NOTES
 -----------
 • CloudKit: to actually SYNC, the iCloud container must be set in Signing & Capabilities
   (the wizard enabled CloudKit but the entitlement container looked empty). The app still
   launches without it (local fallback).
*/
