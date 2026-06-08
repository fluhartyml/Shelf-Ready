//
//  ContentView.swift
//  Shelf-Ready
//

import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Root

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScreenshotProject.createdAt, order: .reverse) private var projects: [ScreenshotProject]
    @State private var selection: ScreenshotProject?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(projects) { project in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.headline)
                        Text("\((project.shots ?? []).count) shot\((project.shots ?? []).count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(project)
                }
                .onDelete(perform: deleteProjects)
            }
            .navigationTitle("Shelf-Ready")
            .toolbar {
                ToolbarItem {
                    Button(action: addProject) { Label("New Asset Set", systemImage: "plus") }
                }
            }
        } detail: {
            if let selection {
                ProjectBoardView(project: selection)
            } else {
                ContentUnavailableView {
                    Label("Select an asset set", systemImage: "square.stack.3d.up.fill")
                } description: {
                    Text("Create an asset set to prepare an app's App Store icon and screenshots.")
                } actions: {
                    Button(action: addProject) {
                        Label("New Asset Set", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func addProject() {
        let p = ScreenshotProject(name: "Untitled")
        modelContext.insert(p)
        selection = p
    }

    private func deleteProjects(_ offsets: IndexSet) {
        for i in offsets { modelContext.delete(projects[i]) }
    }
}

// MARK: - The board for one app's submission set

struct ProjectBoardView: View {
    @Bindable var project: ScreenshotProject
    @Environment(\.modelContext) private var modelContext

    @State private var importingFiles = false
    @State private var exporting = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var zoomShot: Shot?
    @State private var showingIcon = false
    @State private var showPhotos = false
    @State private var status = ""

    var body: some View {
        List {
            Section {
                TextField("Name", text: $project.name)
                    .font(.title3.weight(.semibold))
            }
            ForEach(project.orderedShots) { shot in
                ShotRow(shot: shot)
                    .contentShape(Rectangle())
                    .onTapGesture { zoomShot = shot }
            }
            .onMove(perform: move)
            .onDelete(perform: delete)
        }
        .navigationTitle(project.name.isEmpty ? "Untitled" : project.name)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button { showPhotos = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
                    Button { importingFiles = true } label: { Label("From Files", systemImage: "folder") }
                } label: {
                    Label("Add Screenshots", systemImage: "plus")
                }
                Button { openIcon() } label: {
                    Label("Icon", systemImage: "app.dashed")
                }
                Button { exporting = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled((project.shots ?? []).isEmpty)
                #if os(iOS)
                EditButton()
                #endif
            }
        }
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .fileImporter(isPresented: $importingFiles,
                      allowedContentTypes: [.png, .jpeg, .image],
                      allowsMultipleSelection: true) { handleFileImport($0) }
        .fileImporter(isPresented: $exporting,
                      allowedContentTypes: [.folder]) { handleExport($0) }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .images)
        .sheet(item: $zoomShot) { shot in
            ZoomableImageView(data: shot.imageData)
        }
        .sheet(isPresented: $showingIcon) {
            if let doc = project.iconDocument {
                IconEditorView(document: doc)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !status.isEmpty {
                Text(status)
                    .font(.callout).padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
    }

    // MARK: Reorder / delete

    private func move(from source: IndexSet, to destination: Int) {
        var arr = project.orderedShots
        arr.move(fromOffsets: source, toOffset: destination)
        for (i, shot) in arr.enumerated() { shot.order = i }
        project.updatedAt = Date()
    }

    private func delete(at offsets: IndexSet) {
        let arr = project.orderedShots
        for i in offsets { modelContext.delete(arr[i]) }
    }

    private func openIcon() {
        if project.iconDocument == nil {
            let doc = IconDocument(name: project.name.isEmpty ? "App Icon" : "\(project.name) Icon")
            modelContext.insert(doc)
            project.iconDocument = doc
        }
        showingIcon = true
    }

    // MARK: Add a shot from raw image data (shared by both import paths)

    @discardableResult
    private func addShot(data: Data, filename: String?, order: Int) -> Bool {
        let shot = Shot(imageData: data, sourceFilename: filename)
        if let cg = ScreenshotProcessor.loadCGImage(from: data) {
            let size = ScreenshotProcessor.pixelSize(of: cg)
            if let det = ScreenshotProcessor.detectFamily(forPixelSize: size) {
                shot.family = det.family
                shot.orientation = det.orientation
            }
        }
        shot.order = order
        shot.project = project
        modelContext.insert(shot)
        return true
    }

    // MARK: Import — Files / iCloud Drive

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var added = 0
        var nextOrder = (project.shots ?? []).count
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            addShot(data: data, filename: url.lastPathComponent, order: nextOrder)
            nextOrder += 1; added += 1
        }
        project.updatedAt = Date()
        status = "Imported \(added) from Files."
    }

    // MARK: Import — Photos album

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var added = 0
        var nextOrder = (project.shots ?? []).count
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                addShot(data: data, filename: nil, order: nextOrder)
                nextOrder += 1; added += 1
            }
        }
        photoItems = []
        project.updatedAt = Date()
        status = "Imported \(added) from Photos."
    }

    // MARK: Export — numbered, grouped per device class, sized to spec

    private func handleExport(_ result: Result<URL, Error>) {
        guard case .success(let dir) = result else { return }
        let access = dir.startAccessingSecurityScopedResource()
        defer { if access { dir.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var written = 0
        var skipped = 0

        let grouped = Dictionary(grouping: project.orderedShots) { $0.family }
        for (family, shots) in grouped {
            guard let family else { skipped += shots.count; continue }
            let spec = AppStoreSpec.spec(for: family)
            let famDir = dir.appendingPathComponent(family.rawValue.replacingOccurrences(of: " ", with: ""))
            try? fm.createDirectory(at: famDir, withIntermediateDirectories: true)

            var idx = 1
            for shot in shots {
                guard let data = shot.imageData,
                      let cg = ScreenshotProcessor.loadCGImage(from: data) else { skipped += 1; continue }
                let target = spec.primarySizes(for: shot.orientation).first
                    ?? spec.sizes(for: shot.orientation).first
                guard let target else { skipped += 1; continue }
                guard let rendered = try? ScreenshotProcessor.render(cg, to: target,
                                                                     mode: shot.fitMode,
                                                                     background: shot.background),
                      let png = try? ScreenshotProcessor.encode(rendered, as: .png) else { skipped += 1; continue }
                let name = String(format: "%02d_%@.png", idx, family.rawValue)
                try? png.write(to: famDir.appendingPathComponent(name))
                written += 1; idx += 1
            }
        }
        status = "Exported \(written) screenshot\(written == 1 ? "" : "s")"
            + (skipped > 0 ? " · \(skipped) skipped (need a device class)" : "")
            + " → \(dir.lastPathComponent)"
    }
}

// MARK: - One screenshot row

struct ShotRow: View {
    @Bindable var shot: Shot

    var body: some View {
        HStack(spacing: 12) {
            ShotThumbnail(data: shot.imageData)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            VStack(alignment: .leading, spacing: 6) {
                Text(shot.sourceFilename ?? "Screenshot")
                    .font(.subheadline).lineLimit(1)

                HStack(spacing: 8) {
                    Picker("Device", selection: Binding(
                        get: { shot.family ?? .iPhone },
                        set: { shot.family = $0 })) {
                        ForEach(DeviceFamily.allCases) { fam in
                            Label(fam.displayName, systemImage: fam.symbolName).tag(fam)
                        }
                    }
                    .labelsHidden()

                    Picker("Fit", selection: Binding(
                        get: { shot.fitMode },
                        set: { shot.fitMode = $0 })) {
                        ForEach(FitMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                .font(.caption)

                if let family = shot.family,
                   let target = AppStoreSpec.spec(for: family).primarySizes(for: shot.orientation).first {
                    Text("→ \(target.label)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Cross-platform thumbnail

struct ShotThumbnail: View {
    let data: Data?

    var body: some View {
        if let data, let image = Self.image(from: data) {
            image.resizable().scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
    }

    static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

// MARK: - Pinch-zoom preview (iPad pinch / Mac trackpad; double-tap resets)

struct ZoomableImageView: View {
    let data: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            Group {
                if let data, let image = ShotThumbnail.image(from: data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { scale = max(1, $0.magnification) }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width,
                                                             height: lastOffset.height + $0.translation.height) }
                                .onEnded { _ in lastOffset = offset }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation { scale = 1; offset = .zero; lastOffset = .zero }
                        }
                } else {
                    ContentUnavailableView("No image", systemImage: "photo")
                }
            }
            .navigationTitle("Preview")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
