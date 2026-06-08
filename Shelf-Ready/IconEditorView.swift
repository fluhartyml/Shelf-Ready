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
                    .resizable().interpolation(.none).scaledToFit()   // nearest-neighbor: no blur
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
                    Button { modelContext.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!(modelContext.undoManager?.canUndo ?? false))
                    Button { modelContext.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!(modelContext.undoManager?.canRedo ?? false))
                    Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
                if case .success(let dir) = result { exportIcon(to: dir) }
            }
            .sheet(isPresented: $editingPixels) {
                if let layer = selected, layer.kind == .pixel {
                    PixelPaintView(layer: layer)
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
                TextField("SF Symbol name", text: Binding(
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
                    Text("16").tag(16); Text("32").tag(32); Text("64").tag(64)
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
    }

    private func addPixelLayer() {
        let layer = IconLayer(kind: .pixel)
        layer.pixelGridSize = 64
        layer.pixelData = PixelGrid.blank(size: 64)
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
    @State private var size = 64
    @State private var buffer: [UInt8] = []
    @State private var showGrid = true
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    private let baseEdge: CGFloat = 300     // canvas edge at 1× (whole icon fits)

    private let palette = ["#FFFFFF", "#000000", "#0A84FF", "#32D7FF", "#5E5CE6", "#30D158", "#FF453A", "#FFD60A"]

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

                // Canvas — MS-Paint zoom: at 1× the whole icon fits (judge it at size);
                // zoom in to reveal the editable 64×64 grid. Scroll to pan, pinch/slider to zoom.
                ScrollView([.horizontal, .vertical]) {
                    let canvasPx = baseEdge * zoom
                    let cellPx = canvasPx / CGFloat(size)
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
                    .frame(width: canvasPx, height: canvasPx)
                    .background(Color(white: 0.92))
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
