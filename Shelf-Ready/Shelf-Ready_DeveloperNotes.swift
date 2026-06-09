//
//  Shelf-Ready_DeveloperNotes.swift
//  Shelf-Ready
//
//  PLAN OF RECORD — the full brief for what Shelf-Ready is and every feature we intend it
//  to have. Persistent in-tree (per Michael's "every project gets a DeveloperNotes" rule):
//  survives session resets so a fresh Claude — or Michael without Claude — can pick up the
//  whole vision from the source tree alone.
//
//  This file SUPERSEDES the scope in DeveloperNotes.swift (the 2026-06-07 morning stub).
//  Both are comments-only and harmless to the build; consolidate when convenient.
//

/*
 SHELF-READY — DEVELOPER NOTES (PLAN OF RECORD)
 ==============================================

 Version:         0.1 (in development)
 Developer:       Michael Fluharty
 Engineered with: Claude (Anthropic) — 100% Claude, no ChatGPT in the loop
 Created:         2026-06-07   ·   Plan-of-record expanded: 2026-06-08
 Platforms:       Multiplatform (iPad-primary; runs on Apple Silicon Mac + Vision bonus)
 Bundle ID:       com.nightgard.Shelf-Ready
 Repo:            github.com/fluhartyml/Shelf-Ready
 Storage:         SwiftData + CloudKit (cross-device iPad <-> Mac)

 ============================================================================================
 MISSION
 ============================================================================================
 Take the punishment out of getting an app READY FOR THE SHELF — the App Store Connect
 graphics step. You feed Shelf-Ready the raw screenshots you took of your own app and the
 raw materials for your icon; it produces (a) every screenshot resized to App Store Connect's
 strict per-device specs, ordered and numbered for upload, device-grouped; and (b) a clean,
 correctly-built app icon. Entirely OFFLINE — "via App Store Connect" names the destination,
 not a network call. The user uploads on the site themselves.

 ============================================================================================
 WHY IT EXISTS — TWO BARRIERS IT REMOVES
 ============================================================================================
 1. THE SCREENSHOT / tvOS PUNISHMENT.
    Michael loves making Apple TV apps but AVOIDS shipping them because the App Store Connect
    image step (tvOS sizing especially) is so stressful it gates otherwise-finished apps.
    Apple TV therefore gets FIRST-CLASS treatment here — removing that punishment is both the
    reason to exist and the marketing angle.

 2. THE ICON-CREATION PUNISHMENT (the "flatten disease").
    The usual path — describe an icon to a generative image tool (ChatGPT) — fails in four
    ways that are really ONE problem: the tool has no layers and no alpha, so it returns a
    flattened raster, "a picture of an icon already installed" rather than the artwork.
    The four costumes of that one disease, all observed in practice:
      a. It rounds the corners (Apple wants a full-bleed SQUARE; the OS rounds at display).
      b. It adds a background BEHIND the icon (an object-in-a-scene must have a "behind").
      c. It flattens the described foreground/midground/background into one raster — the
         separate layers you asked for don't survive.
      d. "Make the background black" becomes a flood-fill that can't tell background-white
         from artwork-white, so it eats the white INSIDE your glyphs (cog teeth, negative
         space, a 2-bit blue/WHITE foreground).
    A real layered, nondestructive editor makes all four IMPOSSIBLE at once. That editor is
    the second half of Shelf-Ready.

 DONE-BAR ("physician, heal thyself"): Shelf-Ready is not done until it has prepared its OWN
 App Store submission — its own icon AND its own ordered screenshots — and uploaded them
 clean. It proves itself by shipping itself. Anti-fake-green baked into the definition of done.

 ============================================================================================
 THE TWO HALVES
 ============================================================================================

 HALF A — SUBMISSION-ASSET PACKAGER  (screenshots)
 -------------------------------------------------
 • Import the raw screenshots the user took of their own app (Photos and/or Files).
 • Auto-detect device class by aspect ratio; let the user override.
 • Resize each shot to App Store Connect's STRICT per-device specs.
 • Fit / Fill / Exact placement per shot.
 • Opaque output: flatten alpha, force sRGB, PNG/JPEG (ATC rejects alpha).
 • Arrange on a reorderable board; set the UPLOAD ORDER.
 • Export device-grouped, NUMERIC-PREFIXED files so they upload in the intended order.
 • Apple TV first-class: 4K (3840x2160) and 1080p (1920x1080), landscape only; Top Shelf.
 • Strategy: export the LARGEST per device family; Apple auto-scales the smaller shelves.

 HALF B — LAYERED, NONDESTRUCTIVE ICON EDITOR  (Photoshop-inspired)
 -----------------------------------------------------------------
 A square canvas with an ORDERED STACK OF LAYERS that are NEVER flattened until export, so
 every edit stays reversible. The canvas SQUARE *is* the icon — there is no "outside" for a
 stray background to occupy. Corners stay hard and square; the OS rounds them later.

 Layer kinds (current + planned):
   • SYMBOL layer  (built)   — a real SF Symbol, rendered as VECTOR. No native pixel
                               resolution, so it composites razor-sharp at 1024 with zero
                               scaling artifact. Flat tint color per layer; no shading.
   • IMAGE layer   (built)   — imported high-res artwork/clipart; sampled into the output
                               (downscaled smoothly, or kept native if already >= output).
   • PIXEL layer   (planned) — a low-resolution paint grid (16/32/64) drawn MS-Paint-style,
                               composited NEAREST-NEIGHBOR so it stays crisp blocks, never
                               blurred. See "PIXEL-ART EDITOR" below.

 Per-layer controls:
   • Visibility, opacity, flat fill/tint color (true 2-bit / flat color, no shading).
   • Transform: center (normalized 0..1), scale (fraction of canvas edge), rotation.
   • Z-ORDER (reorder): bring forward / send backward one step; bring to front / send to back.
     The layer-list order IS the composite order IS the z-order — reordering is just reindexing
     `IconLayer.order`. Same drag-to-reorder gesture as the screenshot board (learn once,
     used twice).

 Background & dark mode:
   • The BACKMOST layer / document background is a real, edge-to-edge fill the user owns —
     solid, gradient (e.g. a plasma red/yellow glow), or pixel art. Never a spurious backdrop.
   • "Dark-mode black background" is a LAYER PROPERTY, not a destructive repaint: set the
     bottom layer's fill. Upper layers keep their real alpha and sit untouched on top; black
     shows through ONLY true transparency, never the intentional white inside a glyph.
   • Target the layered .icon / Icon Composer model (light/dark/tinted background variants),
     which is structurally the same foreground/background stack — Apple moved toward this.

 Export:
   • Render the master at 1024x1024, opaque, hard corners, no transparency, no rounded mask.
   • Emit AppIcon.appiconset (and/or .icon). Single-1024 delivery: ship the master; the OS
     generates the smaller shelves. Nail the 1024.

 ============================================================================================
 PIXEL-ART EDITOR  (Half B, PIXEL layer — planned, this is the 2026-06-08 design)
 ============================================================================================
 The MS-Paint editor Michael always wanted but never found on the App Store, living as a
 layer type inside the icon editor (and a candidate to spin off as its own standalone app —
 shared engine).

 Core idea — the "pixel" is decoupled from the hardware pixel:
   • Old pixel art: a pixel WAS a hardware pixel (~72 PPI, chunky, visible).
   • Retina displays (220-460 PPI) make a true 1:1 pixel invisible. So modern pixel art is a
     CHOSEN ART UNIT — a cell on a grid — and the hardware just renders each cell as a block.
   • Workflow: DRAW SMALL on a grid, RENDER THE MASTER BIG. Each art-cell upscales
     nearest-neighbor to an NxN block of device pixels (crisp, no anti-alias blur).
   • Authoring direction is TOP-DOWN like Apple's icons: choose the grid relative to the 1024
     master, render at 1024, let Apple downscale the smaller shelves. (Downscaling discards
     detail you have; upscaling invents detail you don't — down is safe, up is lossy.)

 Tools (Paint-simple is the point):
   • Pencil, fill bucket, eraser, eyedropper, line, rectangle, ellipse, swatch palette.
   • Pixel-art niceties that cost little here: grid toggle, mirror/symmetry drawing,
     selectable grid resolution (16x16 / 32x32 / 64x64).
   • Hard pencil (no anti-aliased brush) + nearest-neighbor scaling = the "blur off" path.

 Why it pairs with SF Symbols — gap-filling:
   • Use the REAL SF Symbol where Apple ships one (e.g. a cog, a standing figure).
   • DRAW it on the pixel layer where Apple DOESN'T (e.g. a specific chess knight, if no
     such symbol exists — see Open Questions). SF Symbol where it exists, hand-drawn pixel
     where it doesn't — same stack, same icon.

 Known hard case: pixel art is HARDEST to keep crisp at the tiny shelves (16-29 px). A 32x32
 design downscaled to 16/20 px resamples and the clean grid blurs/aliases. Single-1024
 delivery mostly rescues this, but preview the smallest shelf explicitly if it must be sharp.

 ============================================================================================
 ARCHITECTURE  (grounded in the real source tree as of 2026-06-08)
 ============================================================================================
 • AppStoreSpec.swift        — authoritative ATC dimension table (verified 2026-06-07 against
                               Apple's primary source). Largest-per-family upload strategy.
 • ScreenshotProcessor.swift — cross-platform resize/format engine (CoreGraphics + ImageIO,
                               no UIKit/AppKit). Fit/Fill/Exact, opaque sRGB flatten, PNG/JPEG,
                               device-class auto-detect by aspect ratio.
 • ShelfReadyModels.swift     — SwiftData (ScreenshotProject -> Shot), CloudKit-compatible.
 • IconModels.swift           — SwiftData icon document: IconDocument (square canvas, 1024,
                               backgroundHex) + IconLayer (Kind {symbol, image}; planned: pixel).
                               orderedLayers = bottom-to-top draw order; never flattened.
 • ContentView.swift          — project list + screenshot board (import/detect/reorder/export).
 • IconEditorView.swift       — layered icon editor UI.
 • Shelf_ReadyApp.swift        — app entry; SwiftData container + UndoManager (per-layer undo).

 ============================================================================================
 ASSET WORKFLOW — LOCKED DESIGN  (worked out with Michael 2026-06-09)
 ============================================================================================
 The authoritative spec for how an asset set turns into a submission. The detail view is TWO
 differentiated sections — ICON on top, SCREENSHOTS below — each a group with a reveal carat
 ">" and drag-and-drop ordering. Both halves write their output into the set's iCloud Drive
 project folder (the durable, browsable, cross-device home; see ICloudProjectStore.swift).

 SCREENSHOTS
 -----------
 • Input: import from Photos / Files / "From Folder" (point at a folder — Desktop, an export
   dump, the apartment archive — and pull every image in filename order).
 • Organize: grouped by DEVICE (iPhone / iPad / Apple TV / macOS …); each group has a reveal
   carat ">"; inside a group, drag-and-drop sets the order the user wants.
 • Resize: AUTO-resize each shot to the exact App Store Connect pixel spec for its device
   target. Per-shot MANUAL OVERRIDE via two fields  [ NNNN ] x [ NNNN ]  under each draggable
   shot, pre-filled with the predetermined size, editable. The override RESAMPLES STRAIGHT to
   the typed pixels. RESIZE ONLY — NEVER CROP (the whole image is always kept; nothing is cut
   off). Rationale: ASC is finicky and rejects off-by-one sizes (e.g. a 6.5" simulator shot
   landing at 1242x2689 instead of 2688) — exact resize fixes it; the override lets the user
   force any exact accepted size.
 • Naming: "{NN} {device} {asset set name}" — ZERO-PADDED (01..10), numbered PER DEVICE GROUP,
   auto-generated on add and REWRITTEN on reorder. e.g. "01 iPhone Shelf Project". Purpose: in
   the ASC upload picker the user selects 01 -> 10 in sequence and they upload in that order.
 • Output: written to the set's iCloud Drive project folder.

 ICONS  (assumes PRODUCTION-READY icons — all generation/editing already complete; the layered
 icon editor is a SEPARATE concern, out of scope for this packaging flow)
 --------------------------------------------------------------------------------------------
 • Three appearance WELLS, exactly as Xcode's AppIcon asset page labels them:
   ANY APPEARANCE (light/default), DARK, TINTED.
   NOTE: Michael's word "clear" == the TINTED well. VERIFY against Apple whether iOS 26 /
   Liquid Glass adds a SEPARATE "Clear" appearance distinct from Tinted before building.
 • The user drags a finished icon into the correct appearance well and can move it between
   wells; confirms placement.
 • "GENERATE ICON SET" button -> produces the required sizes and saves them into the set's
   iCloud Drive project folder. Sizes (VERIFY against Apple post-WWDC): iOS = a single 1024
   per appearance; macOS = the full ladder (16/32/128/256/512 @ 1x/2x).
 • Generated icon file names: "{light/dark/tinted} {NNNNxNNNN}px {asset set name}".
   e.g. "light 1024x1024px Shelf Project", "dark 512x512px Shelf Project".
 • The user opens the iCloud Drive folder and DRAGS each file into the matching well in Xcode's
   AppIcon asset page. Shelf-Ready does NOT write into the .xcassets itself.

 APPLE IS THE SOURCE OF TRUTH — VERIFY, DON'T ASSUME (Michael's standing rule):
 • Re-verify the iPhone screenshot pixel spec (6.9" = 1320x2868) against Apple post-WWDC 2026.
 • Verify the icon appearance set (Any/Dark/Tinted, +Clear?) and the required size set against
   Apple before building Generate Icon Set.

 ============================================================================================
 ROADMAP
 ============================================================================================
 v0.1 (now) ▸ spec model ✓ · resize engine ✓ · models ✓ · screenshot board ✓ · icon editor
              with symbol+image layers ✓ (compiles green; runs iPad + Mac).
 v0.2       ▸ runtime-test on real screenshots · storyboard grid view · Apple TV polish
              (4K/1080p, Top Shelf) · PIXEL layer (grid + Paint tools + nearest-neighbor) ·
              layer reordering UI · light/dark background variants · Dynamic Type pass.
 v0.3       ▸ DOGFOOD: prepare Shelf-Ready's own icon + screenshots with Shelf-Ready ·
              create the App Store Connect record · submit (the done-bar).
 later      ▸ candidate spin-off: standalone "modern MS Paint" using the shared pixel engine.

 ============================================================================================
 OPEN QUESTIONS / DECISIONS PENDING (Michael's calls)
 ============================================================================================
 • Deployment target: currently ~26.4; lower toward ~iPadOS 18 to widen device reach? (paused
   decision from 2026-06-07).
 • Screenshot input source: Photos vs Files as the primary path?
 • SF Symbol availability: confirm `gearshape` and `figure.stand` exist (believed yes), and
   whether ANY chess/knight glyph exists (believed NO — would be the first pixel-layer case).
   Verify in the SF Symbols app / the editor's symbol picker; do not assume a `chess.knight`.
 • CloudKit: set the iCloud container in Signing & Capabilities to actually SYNC (wizard
   enabled CloudKit but the entitlement container looked empty; app still launches locally).
 • Standalone pixel-art app: ship the pixel engine as its own product too, or keep it a layer?

 ============================================================================================
 PROCESS NOTES (how to work on this with Michael — from 2026-06-07)
 ============================================================================================
 • BUILD, don't over-ask: make the sensible standard call and keep moving; show working
   results, not a running commentary of intentions. Over-asking lost a whole session once.
 • NO simulators: xcodebuild compile-checks only; Michael runs it in Xcode himself.
 • Icons come from SF Symbol layers (and now pixel layers); Michael does NOT make tinted icons
   (absent because he doesn't make it, not because it's forbidden).

 ATTRIBUTION
 -----------
 Original work by Michael Fluharty, engineered with Claude. App Store spec data sourced from
 Apple's App Store Connect screenshot-specifications reference.
*/
