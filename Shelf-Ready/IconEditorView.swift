//
//  IconEditorView.swift
//  Shelf-Ready
//
//  Nondestructive, layered icon editor: a square canvas with a stack of SF Symbol / image
//  layers that are never flattened (composited live, rasterized only on export via
//  ImageRenderer). Undo/redo runs through SwiftData's UndoManager, so every layer edit is
//  reversible — Photoshop-style history.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Color hex helper

extension Color {
    init(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        guard s.count == 6 else { self = .black; return }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

private let iconPalette = ["#FFFFFF", "#000000", "#0A84FF", "#32D7FF", "#5E5CE6", "#30D158", "#FF453A", "#FFD60A"]

// MARK: - Canvas (used on-screen AND for export rasterization)

struct IconCanvasView: View {
    let document: IconDocument

    var body: some View {
        GeometryReader { geo in
            let edge = min(geo.size.width, geo.size.height)
            ZStack {
                Color(hexString: document.backgroundHex)
                ForEach(document.orderedLayers) { layer in
                    if layer.isVisible {
                        IconLayerContent(layer: layer, edge: edge)
                    }
                }
            }
            .frame(width: edge, height: edge)
        }
    }
}

struct IconLayerContent: View {
    let layer: IconLayer
    let edge: CGFloat

    var body: some View {
        content
            .frame(width: edge * layer.scale, height: edge * layer.scale)
            .rotationEffect(.degrees(layer.rotationDegrees))
            .opacity(layer.opacity)
            .position(x: edge * layer.centerX, y: edge * layer.centerY)
    }

    @ViewBuilder private var content: some View {
        switch layer.kind {
        case .symbol:
            Image(systemName: layer.symbolName ?? "star.fill")
                .resizable().scaledToFit()
                .foregroundStyle(Color(hexString: layer.colorHex))
        case .image:
            if let data = layer.imageData, let img = ShotThumbnail.image(from: data) {
                img.resizable().scaledToFit()
            } else {
                Color.clear
            }
        case .pixel:
            if let cg = PixelGrid.cgImage(from: layer.pixelData, size: layer.pixelGridSize) {
                Image(decorative: cg, scale: 1)
                    .resizable().interpolation(.high).scaledToFit()   // smoothed → full-res production icon
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Editor

struct IconEditorView: View {
    @Bindable var document: IconDocument
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selected: IconLayer?
    @State private var exporting = false
    @State private var editingPixels = false
    @State private var pickingSymbol = false
    @State private var status = ""

    private let canvasEdge: CGFloat = 320

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // Canvas
                VStack(spacing: 8) {
                    IconCanvasView(document: document)
                        .frame(width: canvasEdge, height: canvasEdge)
                        .background(.quaternary)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary))
                        .gesture(dragSelected)
                    Text("Renders at 1024 × 1024").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()

                Divider()

                // Layers + inspector
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Layers").font(.headline)
                        Spacer()
                        Menu {
                            Button { addSymbolLayer() } label: { Label("SF Symbol Layer", systemImage: "star") }
                            Button { addPixelLayer() } label: { Label("Pixel-Art Layer", systemImage: "square.grid.3x3.fill") }
                        } label: { Image(systemName: "plus") }
                    }
                    List(selection: $selected) {
                        ForEach(document.orderedLayers) { layer in
                            HStack {
                                Image(systemName: rowSymbol(for: layer))
                                Text(layer.displayName).lineLimit(1)
                                Spacer()
                                Button { layer.isVisible.toggle() } label: {
                                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                                }.buttonStyle(.borderless)
                            }
                            .tag(layer)
                        }
                        .onDelete(perform: deleteLayers)
                        .onMove(perform: moveLayers)
                    }
                    .frame(minHeight: 150)

                    if let layer = selected {
                        inspector(for: layer)
                    } else {
                        Text("Select a layer to edit it.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(width: 340)
                .padding()
            }
            .navigationTitle("Icon — \(document.name)")
            .toolbar {
                ToolbarItemGroup {
                    // Undo/redo arrows removed 2026-06-09: they drove the app-wide UndoManager
                    // that's been pulled out. Undo is meant to live in the image-history sheet
                    // (to be built), not in toolbar arrows.
                    Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
                if case .success(let dir) = result { exportIcon(to: dir) }
            }
            .sheet(isPresented: $editingPixels) {
                if let layer = selected, layer.kind == .pixel {
                    PixelPaintView(layer: layer, document: document)
                }
            }
            .sheet(isPresented: $pickingSymbol) {
                if let layer = selected, layer.kind == .symbol {
                    SymbolPickerView(symbolName: Binding(
                        get: { layer.symbolName ?? "star.fill" },
                        set: { layer.symbolName = $0 }))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !status.isEmpty {
                    Text(status).font(.callout).padding(8)
                        .frame(maxWidth: .infinity).background(.thinMaterial)
                }
            }
        }
    }

    // Drag the selected layer around the canvas (touch on iPad, mouse on Mac).
    private var dragSelected: some Gesture {
        DragGesture()
            .onChanged { value in
                guard let layer = selected else { return }
                layer.centerX = min(1, max(0, value.location.x / canvasEdge))
                layer.centerY = min(1, max(0, value.location.y / canvasEdge))
            }
    }

    @ViewBuilder private func inspector(for layer: IconLayer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if layer.kind == .symbol {
                Button { pickingSymbol = true } label: {
                    Label { Text("Choose Symbol…") } icon: { Image(systemName: layer.symbolName ?? "star.fill") }
                }
                .buttonStyle(.borderedProminent)
                TextField("…or type an exact SF Symbol name", text: Binding(
                    get: { layer.symbolName ?? "" },
                    set: { layer.symbolName = $0 }))
                    .textFieldStyle(.roundedBorder)
                Text("Symbol color").font(.caption)
                swatches(Binding(get: { layer.colorHex }, set: { layer.colorHex = $0 }))
            }
            if layer.kind == .pixel {
                Text("Grid").font(.caption)
                Picker("Grid", selection: Binding(
                    get: { layer.pixelGridSize },
                    set: { newSize in
                        guard newSize != layer.pixelGridSize else { return }
                        layer.pixelGridSize = newSize
                        layer.pixelData = PixelGrid.blank(size: newSize)   // resizing clears the grid
                    })) {
                    Text("64").tag(64); Text("128").tag(128)
                }
                .pickerStyle(.segmented).labelsHidden()
                Button { editingPixels = true } label: {
                    Label("Edit Pixels…", systemImage: "paintbrush.pointed.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            slider("Size", Binding(get: { layer.scale }, set: { layer.scale = $0 }), 0.1...1.0)
            slider("Rotate", Binding(get: { layer.rotationDegrees }, set: { layer.rotationDegrees = $0 }), 0...360)
            slider("Opacity", Binding(get: { layer.opacity }, set: { layer.opacity = $0 }), 0...1)
            Divider()
            Text("Background").font(.caption)
            swatches(Binding(get: { document.backgroundHex }, set: { document.backgroundHex = $0 }))
        }
    }

    private func swatches(_ binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ForEach(iconPalette, id: \.self) { hex in
                Circle().fill(Color(hexString: hex)).frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(
                        binding.wrappedValue == hex ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: binding.wrappedValue == hex ? 3 : 1))
                    .onTapGesture { binding.wrappedValue = hex }
            }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 56, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    // MARK: Layer ops

    private func addSymbolLayer() {
        let layer = IconLayer(kind: .symbol, symbolName: "star.fill")
        layer.order = (document.layers ?? []).count
        layer.document = document
        modelContext.insert(layer)
        selected = layer
        document.updatedAt = Date()
        pickingSymbol = true        // let the user choose the glyph right away
    }

    private func addPixelLayer() {
        let layer = IconLayer(kind: .pixel)
        layer.pixelGridSize = 128
        layer.pixelData = PixelGrid.blank(size: 128)
        layer.scale = 1.0                       // fill the canvas like a paint surface
        layer.order = (document.layers ?? []).count
        layer.document = document
        modelContext.insert(layer)
        selected = layer
        document.updatedAt = Date()
    }

    private func rowSymbol(for layer: IconLayer) -> String {
        switch layer.kind {
        case .symbol: return layer.symbolName ?? "star.fill"
        case .image:  return "photo"
        case .pixel:  return "square.grid.3x3.fill"
        }
    }

    private func deleteLayers(_ offsets: IndexSet) {
        let arr = document.orderedLayers
        for i in offsets { modelContext.delete(arr[i]) }
    }

    private func moveLayers(from source: IndexSet, to dest: Int) {
        var arr = document.orderedLayers
        arr.move(fromOffsets: source, toOffset: dest)
        for (i, l) in arr.enumerated() { l.order = i }
    }

    // MARK: Export → AppIcon.appiconset (single 1024 universal)

    @MainActor private func exportIcon(to dir: URL) {
        let access = dir.startAccessingSecurityScopedResource()
        defer { if access { dir.stopAccessingSecurityScopedResource() } }

        let renderer = ImageRenderer(content: IconCanvasView(document: document).frame(width: 1024, height: 1024))
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let png = try? ScreenshotProcessor.encode(cg, as: .png) else {
            status = "Couldn't render the icon."
            return
        }
        let setDir = dir.appendingPathComponent("AppIcon.appiconset")
        try? FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)
        try? png.write(to: setDir.appendingPathComponent("icon-1024.png"))

        let contents = """
        {
          "images" : [
            {
              "filename" : "icon-1024.png",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        try? contents.data(using: .utf8)?.write(to: setDir.appendingPathComponent("Contents.json"))
        status = "Exported AppIcon.appiconset → \(dir.lastPathComponent)"
    }
}

// MARK: - Pixel-art paint surface (MS-Paint-simple: pencil / fill / eraser / eyedropper)

struct PixelPaintView: View {
    @Bindable var layer: IconLayer
    let document: IconDocument
    @Environment(\.dismiss) private var dismiss

    enum Tool: String, CaseIterable, Identifiable {
        case pencil, fill, eraser, eyedropper
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .pencil:     return "pencil.tip"
            case .fill:       return "drop.fill"
            case .eraser:     return "eraser"
            case .eyedropper: return "eyedropper"
            }
        }
    }

    @State private var tool: Tool = .pencil
    @State private var colorHex = "#000000"
    @State private var size = 128
    @State private var buffer: [UInt8] = []
    @State private var showGrid = true
    @State private var showContext = true
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    private let baseEdge: CGFloat = 300     // canvas edge at 1× (whole icon fits)

    private let palette = ["#FFFFFF", "#000000", "#0A84FF", "#32D7FF", "#5E5CE6", "#30D158", "#FF453A", "#FFD60A"]

    /// Visible layers that sit BELOW this pixel layer — shown as live editing context.
    private var layersBelow: [IconLayer] {
        document.orderedLayers.filter { $0.isVisible && $0.order < layer.order }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                // Tools
                HStack(spacing: 10) {
                    ForEach(Tool.allCases) { t in
                        Button { tool = t } label: {
                            Image(systemName: t.symbol)
                                .frame(width: 30, height: 30)
                                .background(tool == t ? Color.accentColor.opacity(0.25) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Toggle(isOn: $showContext) { Image(systemName: "rectangle.stack") }.toggleStyle(.button)
                    Toggle(isOn: $showGrid) { Image(systemName: "grid") }.toggleStyle(.button)
                }

                // Palette
                HStack(spacing: 8) {
                    ForEach(palette, id: \.self) { hex in
                        Circle().fill(Color(hexString: hex)).frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(
                                colorHex == hex ? Color.accentColor : Color.secondary.opacity(0.3),
                                lineWidth: colorHex == hex ? 3 : 1))
                            .onTapGesture { colorHex = hex }
                    }
                }

                // Canvas — MS-Paint zoom + live context: the layers BELOW composite under the
                // grid (smoothed, real) so you draw the pixel art over the star in place. The
                // chunky grid is a creation aid; the icon itself composites smoothed at full res.
                ScrollView([.horizontal, .vertical]) {
                    let canvasPx = baseEdge * zoom
                    let cellPx = canvasPx / CGFloat(size)
                    ZStack {
                        if showContext {
                            Color(hexString: document.backgroundHex)
                            ForEach(layersBelow) { IconLayerContent(layer: $0, edge: canvasPx) }
                        } else {
                            Color(white: 0.92)
                        }
                        Canvas { ctx, _ in
                            for y in 0..<size {
                                for x in 0..<size {
                                    let i = (y * size + x) * 4
                                    guard i + 3 < buffer.count, buffer[i + 3] > 0 else { continue }
                                    let color = Color(.sRGB,
                                        red: Double(buffer[i]) / 255,
                                        green: Double(buffer[i + 1]) / 255,
                                        blue: Double(buffer[i + 2]) / 255,
                                        opacity: Double(buffer[i + 3]) / 255)
                                    ctx.fill(Path(CGRect(x: CGFloat(x) * cellPx, y: CGFloat(y) * cellPx,
                                                         width: cellPx, height: cellPx)), with: .color(color))
                                }
                            }
                            if showGrid && cellPx >= 10 {   // grid only once cells are big enough to edit
                                var grid = Path()
                                for k in 0...size {
                                    let p = CGFloat(k) * cellPx
                                    grid.move(to: CGPoint(x: p, y: 0)); grid.addLine(to: CGPoint(x: p, y: canvasPx))
                                    grid.move(to: CGPoint(x: 0, y: p)); grid.addLine(to: CGPoint(x: canvasPx, y: p))
                                }
                                ctx.stroke(grid, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                            }
                        }
                    }
                    .frame(width: canvasPx, height: canvasPx)
                    .overlay(Rectangle().strokeBorder(.secondary))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { paint(at: $0.location, px: canvasPx) }
                        .onEnded { _ in commit() })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(MagnifyGesture()
                    .onChanged { zoom = max(1, min(20, baseZoom * $0.magnification)) }
                    .onEnded { _ in baseZoom = zoom })

                // Zoom (1× = whole icon · zoom in to paint individual pixels)
                HStack(spacing: 10) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 1...20) { _ in baseZoom = zoom }
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                    Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                }
            }
            .padding()
            .navigationTitle("Pixel Art — \(size)×\(size)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear", role: .destructive) {
                        buffer = [UInt8](PixelGrid.blank(size: size)); commit()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit(); dismiss() }
                }
            }
            .onAppear { load() }
        }
    }

    // MARK: Buffer ops

    private func load() {
        size = layer.pixelGridSize
        let needed = size * size * 4
        let data = layer.pixelData ?? PixelGrid.blank(size: size)
        buffer = data.count == needed ? [UInt8](data) : [UInt8](PixelGrid.blank(size: size))
    }

    private func commit() {
        layer.pixelGridSize = size
        layer.pixelData = Data(buffer)
        layer.document?.updatedAt = Date()
    }

    private func paint(at location: CGPoint, px: CGFloat) {
        let cx = Int(location.x / px * CGFloat(size))
        let cy = Int(location.y / px * CGFloat(size))
        guard cx >= 0, cx < size, cy >= 0, cy < size else { return }
        switch tool {
        case .pencil:     setCell(cx, cy, PixelGrid.rgba(fromHex: colorHex))
        case .eraser:     setCell(cx, cy, (0, 0, 0, 0))
        case .fill:       floodFill(cx, cy, PixelGrid.rgba(fromHex: colorHex))
        case .eyedropper: pick(cx, cy)
        }
    }

    private func idx(_ x: Int, _ y: Int) -> Int { (y * size + x) * 4 }

    private func setCell(_ x: Int, _ y: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) {
        let i = idx(x, y)
        guard i + 3 < buffer.count else { return }
        buffer[i] = rgba.0; buffer[i + 1] = rgba.1; buffer[i + 2] = rgba.2; buffer[i + 3] = rgba.3
    }

    private func cell(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = idx(x, y)
        guard i + 3 < buffer.count else { return (0, 0, 0, 0) }
        return (buffer[i], buffer[i + 1], buffer[i + 2], buffer[i + 3])
    }

    private func pick(_ x: Int, _ y: Int) {
        let c = cell(x, y)
        guard c.3 > 0 else { return }
        colorHex = String(format: "#%02X%02X%02X", c.0, c.1, c.2)
    }

    /// 4-connected flood fill (bounded by size² ≤ 4096 cells).
    private func floodFill(_ x: Int, _ y: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) {
        let target = cell(x, y)
        if target == rgba { return }
        var stack = [(x, y)]
        while let (cx, cy) = stack.popLast() {
            guard cx >= 0, cx < size, cy >= 0, cy < size else { continue }
            if cell(cx, cy) != target { continue }
            setCell(cx, cy, rgba)
            stack.append((cx + 1, cy)); stack.append((cx - 1, cy))
            stack.append((cx, cy + 1)); stack.append((cx, cy - 1))
        }
    }
}

// MARK: - SF Symbol picker (curated, searchable, runtime-filtered to what resolves on this OS)

struct SymbolPickerView: View {
    @Binding var symbolName: String
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var resolved: [String] = []

    private let columns = [GridItem(.adaptive(minimum: 54), spacing: 8)]

    private var shown: [String] {
        guard !search.isEmpty else { return resolved }
        let q = search.lowercased()
        return resolved.filter { $0.contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(shown, id: \.self) { name in
                        Button {
                            symbolName = name
                            dismiss()
                        } label: {
                            Image(systemName: name)
                                .font(.title2)
                                .frame(width: 50, height: 50)
                                .background(symbolName == name ? Color.accentColor.opacity(0.3)
                                                                : Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding()
            }
            .searchable(text: $search, prompt: "Search \(resolved.count) symbols")
            .navigationTitle("SF Symbols")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                if resolved.isEmpty { resolved = Self.curated.filter(Self.resolves) }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    /// True only if the symbol actually exists on this OS version (keeps broken glyphs out).
    static func resolves(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return true
        #endif
    }

    /// A broad starter set across categories. Anything that doesn't resolve is filtered out,
    /// so it's safe to list liberally; the text field covers anything not here.
    static let curated: [String] = [
        // Shapes & marks
        "star", "star.fill", "star.circle", "heart", "heart.fill", "circle", "circle.fill",
        "square", "square.fill", "triangle", "triangle.fill", "diamond", "diamond.fill",
        "hexagon", "hexagon.fill", "octagon", "octagon.fill", "seal", "seal.fill",
        "shield", "shield.fill", "flag", "flag.fill", "flag.checkered", "bookmark", "bookmark.fill",
        "tag", "tag.fill", "bolt", "bolt.fill", "sparkles", "sparkle", "crown", "crown.fill",
        "rosette", "trophy", "trophy.fill", "medal", "medal.fill",
        // People & hands
        "person", "person.fill", "person.2", "person.2.fill", "person.3.fill",
        "person.crop.circle", "figure.stand", "figure.walk", "figure.run", "figure.wave",
        "hand.raised", "hand.raised.fill", "hand.thumbsup", "hand.thumbsup.fill",
        "hand.thumbsdown", "hand.point.up.left", "eye", "eye.fill", "face.smiling", "brain.head.profile",
        // Nature, weather & animals
        "sun.max", "sun.max.fill", "moon", "moon.fill", "moon.stars", "moon.stars.fill",
        "cloud", "cloud.fill", "cloud.rain", "cloud.rain.fill", "cloud.bolt", "cloud.snow",
        "snowflake", "wind", "tornado", "flame", "flame.fill", "drop", "drop.fill",
        "leaf", "leaf.fill", "tree", "globe", "globe.americas.fill", "mountain.2", "mountain.2.fill",
        "bird", "bird.fill", "ant", "ant.fill", "ladybug", "ladybug.fill", "hare", "hare.fill",
        "tortoise", "tortoise.fill", "pawprint", "pawprint.fill", "fish", "fish.fill", "cat", "dog",
        // Objects & tools
        "house", "house.fill", "building.2", "building.2.fill", "building.columns",
        "gear", "gearshape", "gearshape.fill", "gearshape.2", "wrench.adjustable", "wrench.adjustable.fill",
        "hammer", "hammer.fill", "wrench.and.screwdriver", "screwdriver", "paintbrush",
        "paintbrush.fill", "paintbrush.pointed", "paintbrush.pointed.fill", "paintpalette",
        "pencil", "pencil.tip", "scissors", "paperclip", "link", "lock", "lock.fill", "lock.open",
        "key", "key.fill", "bell", "bell.fill", "alarm", "clock", "clock.fill", "stopwatch",
        "timer", "hourglass", "calendar", "gift", "gift.fill", "cart", "cart.fill", "bag", "bag.fill",
        "creditcard", "creditcard.fill", "dollarsign.circle", "banknote", "briefcase", "briefcase.fill",
        "folder", "folder.fill", "doc", "doc.fill", "doc.text", "book", "book.fill",
        "books.vertical", "newspaper", "graduationcap", "graduationcap.fill", "backpack",
        "ruler", "paperplane", "paperplane.fill", "envelope", "envelope.fill", "tray", "tray.fill",
        "archivebox", "trash", "trash.fill",
        // Media & sound
        "camera", "camera.fill", "photo", "photo.fill", "video", "video.fill", "film",
        "music.note", "music.note.list", "headphones", "mic", "mic.fill", "speaker.wave.2",
        "speaker.wave.2.fill", "guitars", "pianokeys", "megaphone", "megaphone.fill",
        "play.fill", "pause.fill", "stop.fill",
        // Devices & tech
        "desktopcomputer", "laptopcomputer", "display", "iphone", "ipad", "applewatch",
        "airpods", "keyboard", "printer", "tv", "tv.fill", "gamecontroller", "gamecontroller.fill",
        "cpu", "memorychip", "externaldrive", "internaldrive", "server.rack", "wifi",
        "antenna.radiowaves.left.and.right", "network", "battery.100", "bolt.batteryblock",
        // Transport & places
        "car", "car.fill", "bus", "tram", "airplane", "ferry", "sailboat", "bicycle",
        "fuelpump", "fuelpump.fill", "map", "map.fill", "location", "location.fill",
        "mappin", "mappin.circle", "signpost.right",
        // Food
        "cup.and.saucer", "cup.and.saucer.fill", "mug", "mug.fill", "fork.knife",
        "takeoutbag.and.cup.and.straw", "birthday.cake", "carrot",
        // Health & sport
        "cross", "cross.fill", "cross.case", "pills", "pills.fill", "bandage", "stethoscope",
        "bed.double", "dumbbell", "dumbbell.fill", "sportscourt", "soccerball", "basketball.fill",
        "football.fill", "tennis.racket",
        // Symbols & UI
        "plus", "minus", "checkmark", "checkmark.circle", "checkmark.circle.fill", "xmark",
        "xmark.circle", "exclamationmark.triangle", "questionmark.circle", "info.circle",
        "magnifyingglass", "slider.horizontal.3", "line.3.horizontal", "ellipsis", "ellipsis.circle",
        "arrow.up", "arrow.down", "arrow.left", "arrow.right", "arrow.up.right",
        "arrow.clockwise", "arrow.triangle.2.circlepath", "arrowshape.turn.up.left",
        "chevron.right", "chevron.left", "power", "wand.and.stars", "wand.and.rays",
        "atom", "function", "infinity", "command", "flashlight.on.fill"
    ]
}
