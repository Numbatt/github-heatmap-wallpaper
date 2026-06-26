#if canImport(AppKit)
import AppKit
import Combine
import Foundation
import SwiftUI

/// SwiftUI-based theme editor. Invoked from the CLI via
/// `gh-wallpaper theme-edit`. Owns its own `NSApplication.shared` event
/// loop — the daemon code path never enters this module.
public enum ThemeEditor {

    /// Outcome of a single editor session, returned to the CLI.
    public enum Outcome: Equatable {
        case saved(themeID: String, applyImmediately: Bool)
        case cancelled
    }

    /// Sync entry for callers already on the OS main thread (the CLI's
    /// `dispatchEditorSync` path). Bridges into the `@MainActor` impl
    /// without going through `await MainActor.run` — that wrapper, when
    /// it ends up calling `NSApplication.run()`, starves both
    /// `DispatchQueue.main` and MainActor continuations and breaks the
    /// live preview + the post-editor wallpaper apply.
    public static func runOnMainThread(seed: Theme, themeName: String, mustRename: Bool = false) -> Outcome {
        precondition(Thread.isMainThread, "ThemeEditor.runOnMainThread must be called from the main thread")
        return MainActor.assumeIsolated {
            run(seed: seed, themeName: themeName, mustRename: mustRename)
        }
    }

    /// Opens the editor window and blocks until the user closes it.
    /// Returns the outcome so the caller can decide whether to refresh
    /// the wallpaper, write to config, etc.
    ///
    /// Pass `mustRename: true` when seeding from a built-in theme — the
    /// name field will start empty (with a hint placeholder) and Save
    /// stays disabled until the user types a non-built-in name.
    @MainActor
    public static func run(seed: Theme, themeName: String, mustRename: Bool = false) -> Outcome {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let model = ThemeEditorModel(seed: seed, themeName: mustRename ? "" : themeName)
        model.placeholderName = mustRename ? "my-\(themeName)" : "my-theme"
        let view = ThemeEditorView(model: model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1060),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "gh-wallpaper · theme editor"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)

        let delegate = WindowDelegate(model: model)
        window.delegate = delegate

        app.activate(ignoringOtherApps: true)
        app.run()

        // After the editor's run loop returns, drop back to a hidden-from-Dock
        // policy so the rest of the CLI (refresh, wallpaper-set, etc.) runs as
        // a background utility again. Without this, the binary remains a
        // `.regular` app for the rest of the process lifetime, which can
        // confuse `NSWorkspace.setDesktopImageURL` on some macOS builds.
        app.setActivationPolicy(.prohibited)

        return delegate.outcome
    }

    /// Holds the editor's outcome across the `NSApp.run()` boundary and
    /// terminates the run loop on window close.
    @MainActor
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        var outcome: Outcome = .cancelled
        let model: ThemeEditorModel

        init(model: ThemeEditorModel) {
            self.model = model
            super.init()
            model.onClose = { [weak self] outcome in
                guard let self = self else { return }
                self.outcome = outcome
                NSApp.stop(nil)
                // Post a no-op event so `NSApp.run()` returns immediately.
                NSApp.postEvent(.dummyEvent(), atStart: false)
                NSApp.windows.forEach { $0.close() }
            }
        }

        nonisolated func windowWillClose(_ notification: Notification) {
            // User closed via the red traffic light; treat as cancel and
            // stop the run loop so the CLI subcommand returns. This needs
            // to be nonisolated because AppKit calls it from the run loop.
            DispatchQueue.main.async {
                NSApp.stop(nil)
                NSApp.postEvent(.dummyEvent(), atStart: false)
            }
        }
    }
}

private extension NSEvent {
    /// A safe no-op event used to nudge the run loop after `NSApp.stop`.
    /// Plain `NSEvent()` triggers a SwiftUI runtime warning about
    /// `_NSEventDescription`; the explicit `.applicationDefined` form
    /// avoids it.
    static func dummyEvent() -> NSEvent {
        return NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) ?? NSEvent()
    }
}

// MARK: - Model

@MainActor
final class ThemeEditorModel: ObservableObject {
    @Published var themeName: String
    @Published var background: Color
    @Published var headline: Color
    @Published var ramp: [Color]   // exactly 5 entries

    /// Source absolute path the user picked from `NSOpenPanel`. Used for
    /// the preview's resolved image. On save, this file is copied to
    /// `Paths.customThemesImagesDir/<theme-id>.<ext>` and the JSON stores
    /// the relative `images/<theme-id>.<ext>`.
    @Published var sourceImagePath: String?
    @Published var dimAlpha: Double

    // Headline display options (global config, not per-theme).
    /// Empty string = use the default "DESIGN  BUILD  SHIP".
    @Published var headlineText: String
    @Published var headlineUseSystemFont: Bool
    @Published var headlineFontFamily: String
    @Published var headlineSizeScale: Double
    @Published var recentFontFamilies: [String]

    @Published var previewImage: NSImage?
    @Published var statusMessage: String = ""
    @Published var isSaving = false

    /// Placeholder text for the name field. Set by `ThemeEditor.run` to
    /// hint at a sensible name (e.g. "my-dracula" when forking dracula).
    var placeholderName: String = "my-theme"

    /// Set by the view's modifier; the model uses this to trigger an
    /// initial render on first display.
    var onClose: ((ThemeEditor.Outcome) -> Void)?

    /// Filename of the original image when editing an existing theme that
    /// already had an image copied. We track it so we can leave it alone
    /// if the user doesn't change the image.
    let originalThemeID: String

    private let renderer: PreviewRenderer?
    private var renderTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(seed: Theme, themeName: String) {
        self.themeName = themeName
        self.originalThemeID = seed.id
        self.background = Color(hex: seed.background) ?? .black
        self.headline = Color(hex: seed.headlineColor) ?? .white
        self.ramp = seed.cellRamp.map { Color(hex: $0) ?? .gray }
        if let p = seed.backgroundImagePath, FileManager.default.fileExists(atPath: p) {
            self.sourceImagePath = p
        } else {
            self.sourceImagePath = nil
        }
        self.dimAlpha = seed.backgroundDimAlpha ?? 0.4

        // Headline options: load from current config so the editor reflects reality.
        let savedOpts = (try? ConfigStore.read())?.resolvedHeadlineOptions() ?? .default
        self.headlineText = savedOpts.text ?? ""
        switch savedOpts.resolvedFont {
        case .pixelGlyphs:
            self.headlineUseSystemFont = false
            self.headlineFontFamily = "SF Mono"
        case .system(let family):
            self.headlineUseSystemFont = true
            self.headlineFontFamily = family
        }
        self.headlineSizeScale = savedOpts.resolvedSizeScale
        self.recentFontFamilies = []

        self.renderer = try? PreviewRenderer()

        // Subscribe to *input fields only*. Subscribing to `objectWillChange`
        // would create a feedback loop because `previewImage` is also
        // @Published — every successful render would trigger another debounced
        // render, and depending on timing the very first task could get
        // cancelled by the next round before the assignment lands, leaving
        // `previewImage` permanently nil ("forever loading"). Listing each
        // input avoids that.
        let inputChanged = Publishers.MergeMany([
            $themeName.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $background.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $headline.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $ramp.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $sourceImagePath.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $dimAlpha.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $headlineText.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $headlineUseSystemFont.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $headlineFontFamily.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $headlineSizeScale.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ])
        inputChanged
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.regeneratePreview() }
            .store(in: &cancellables)
    }

    func regeneratePreview() {
        guard let renderer = renderer else {
            statusMessage = "resvg not on PATH — preview unavailable"
            return
        }
        renderTask?.cancel()
        let theme = currentTheme(forPreview: true)
        let headlineOpts = currentHeadlineOptions()
        renderTask = Task { @MainActor in
            do {
                // resvg subprocess + PNG-bytes read off-main (Data is Sendable).
                let pngData = try await Task.detached(priority: .userInitiated) {
                    try renderer.renderPNGData(theme: theme, headline: headlineOpts)
                }.value
                if Task.isCancelled { return }
                // NSImage decode happens on main so SwiftUI's Image(nsImage:)
                // sees a fully-realized bitmap. Off-main NSImage construction
                // can leave the image with a lazy representation that the
                // SwiftUI binding never gets around to rendering.
                guard let img = PreviewRenderer.imageFromPNG(data: pngData) else {
                    throw RasterizerError.ioError("could not decode preview PNG")
                }
                self.previewImage = img
                self.statusMessage = ""
            } catch {
                if Task.isCancelled { return }
                self.statusMessage = "preview failed: \(error)"
            }
        }
    }

    /// Builds the current `HeadlineOptions` from the model's display fields.
    func currentHeadlineOptions() -> HeadlineOptions {
        let text: String? = headlineText.isEmpty ? nil : headlineText
        let font: HeadlineFont
        if headlineUseSystemFont {
            let family = headlineFontFamily.trimmingCharacters(in: .whitespaces)
            font = .system(family: family.isEmpty ? "SF Mono" : family)
        } else {
            font = .pixelGlyphs
        }
        let scale: Double? = headlineSizeScale == 1.0 ? nil : headlineSizeScale
        return HeadlineOptions(text: text, font: font, sizeScale: scale)
    }

    /// True when the current theme name is a non-empty, non-builtin id.
    /// Drives the Save button's enabled state and ensures users forking a
    /// built-in must pick a different name before they can commit.
    var canSave: Bool {
        let id = sanitizedID(themeName)
        if id.isEmpty { return false }
        let builtinIDs = Set(Themes.builtins.map(\.id) + ["auto"])
        return !builtinIDs.contains(id)
    }

    /// The label that appears on the bare Save button. Empty / built-in
    /// names show a hint about what's wrong instead of an action verb.
    var saveLabel: String {
        let id = sanitizedID(themeName)
        if id.isEmpty { return "Save as custom theme…" }
        let builtinIDs = Set(Themes.builtins.map(\.id) + ["auto"])
        if builtinIDs.contains(id) { return "Pick a non-built-in name to save" }
        return "Save as custom theme '\(id)'"
    }

    /// The label for the Save & Apply button.
    var applyLabel: String {
        let id = sanitizedID(themeName)
        if id.isEmpty { return "Save & apply…" }
        let builtinIDs = Set(Themes.builtins.map(\.id) + ["auto"])
        if builtinIDs.contains(id) { return "Pick a non-built-in name" }
        return "Save & apply '\(id)'"
    }

    /// Builds a `Theme` from the model. `forPreview=true` puts the
    /// absolute source path in `backgroundImagePath` so SVGBuilder can
    /// emit a usable href; `forPreview=false` substitutes the post-save
    /// relative path so the JSON written to disk is portable.
    func currentTheme(forPreview: Bool) -> Theme {
        let id = sanitizedID(themeName)
        let imagePath: String?
        if let src = sourceImagePath {
            if forPreview {
                imagePath = src
            } else {
                let ext = (src as NSString).pathExtension.lowercased()
                imagePath = "images/\(id).\(ext)"
            }
        } else {
            imagePath = nil
        }
        return Theme(
            id: id.isEmpty ? "untitled" : id,
            background: background.hex,
            backgroundIsGradient: false,
            cellRamp: ramp.map { $0.hex },
            headlineColor: headline.hex,
            gradientSVG: nil,
            backgroundImagePath: imagePath,
            backgroundDimAlpha: imagePath == nil ? nil : dimAlpha
        )
    }

    // MARK: - Preset application

    /// Replaces the editable color fields (background, headline, ramp)
    /// with the values from `theme`. Leaves the theme name, image
    /// background, and dim-overlay slider alone — those are independent
    /// of the color preset. For gradient-backed themes (e.g. `midnight`)
    /// the editor's solid-color swatch can't show a gradient, so we pull
    /// the gradient's last `stop-color` out of the embedded `<defs>` and
    /// use that as a representative solid — for radial gradients the
    /// outer stop is the color most readers associate with the theme.
    func applyDefaults(from theme: Theme) {
        if !theme.backgroundIsGradient, let c = Color(hex: theme.background) {
            background = c
        } else if theme.backgroundIsGradient,
                  let svg = theme.gradientSVG,
                  let hex = Self.lastStopColor(in: svg),
                  let c = Color(hex: hex) {
            background = c
        }
        if let c = Color(hex: theme.headlineColor) {
            headline = c
        }
        if theme.cellRamp.count == 5 {
            ramp = theme.cellRamp.map { Color(hex: $0) ?? .gray }
        }
    }

    /// Returns the last `stop-color="…"` value in a gradient SVG snippet,
    /// or nil if none parse. Used as a solid-color fallback when applying
    /// gradient theme presets — see `applyDefaults(from:)`.
    private static func lastStopColor(in gradientSVG: String) -> String? {
        // Scan for occurrences of stop-color="…"; take the last one. The
        // built-in gradient strings are tiny so a linear scan is fine.
        let needle = "stop-color=\""
        var search = gradientSVG[...]
        var last: String? = nil
        while let openRange = search.range(of: needle) {
            let valueStart = openRange.upperBound
            guard let closeQuote = search[valueStart...].firstIndex(of: "\"") else { break }
            last = String(search[valueStart..<closeQuote])
            search = search[closeQuote...]
        }
        return last
    }

    // MARK: - Image picker

    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            sourceImagePath = url.path
        }
    }

    func clearImage() {
        sourceImagePath = nil
    }

    // MARK: - Save / Cancel

    func save(applyImmediately: Bool) {
        let id = sanitizedID(themeName)
        guard !id.isEmpty else {
            statusMessage = "theme name can't be empty"
            return
        }
        let builtinIDs = Set(Themes.builtins.map(\.id) + ["auto"])
        if builtinIDs.contains(id) {
            statusMessage = "'\(id)' is a built-in theme — pick a different name"
            return
        }
        isSaving = true
        do {
            // If an image is set, copy the source into the themes/images
            // directory under <id>.<ext>. The JSON stores the relative
            // path so the theme stays portable.
            if let src = sourceImagePath {
                try copyImageIntoThemesDir(source: src, themeID: id)
            }
            let themeForDisk = currentTheme(forPreview: false)
            let writtenURL = try CustomThemes.shared.save(themeForDisk)

            // Persist headline options to config.toml (silently skips if no config yet).
            let headlineOpts = currentHeadlineOptions()
            if var savedConfig = try? ConfigStore.read() {
                savedConfig.headlineText = headlineOpts.text
                savedConfig.headlineFont = headlineOpts.font
                savedConfig.headlineSizeScale = headlineOpts.sizeScale
                try? ConfigStore.write(savedConfig)
            }

            isSaving = false

            // Explicit confirmation modal so the user gets unambiguous
            // feedback before the window closes. Without it, the editor
            // window vanishes silently and the user has no idea whether
            // the save succeeded — they have to scan the terminal output
            // to be sure.
            let alert = NSAlert()
            if applyImmediately {
                alert.messageText = "Saved theme '\(id)'"
                alert.informativeText = "Applying it as your wallpaper now…\n\n\(writtenURL.path)"
            } else {
                alert.messageText = "Saved theme '\(id)'"
                alert.informativeText = "Run `gh-wallpaper theme \(id)` to switch to it.\n\n\(writtenURL.path)"
            }
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()

            onClose?(.saved(themeID: id, applyImmediately: applyImmediately))
        } catch {
            isSaving = false
            statusMessage = "save failed: \(error)"
            let alert = NSAlert()
            alert.messageText = "Save failed"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func cancel() {
        onClose?(.cancelled)
    }

    private func copyImageIntoThemesDir(source: String, themeID: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.customThemesImagesDir, withIntermediateDirectories: true)
        let ext = (source as NSString).pathExtension.lowercased()
        let dest = Paths.customThemesImagesDir.appendingPathComponent("\(themeID).\(ext)")
        // If source and dest are the same path (re-saving an unchanged theme),
        // skip the copy — Copying onto itself errors out.
        if (source as NSString).standardizingPath == dest.path {
            return
        }
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(atPath: source, toPath: dest.path)
    }

    private func sanitizedID(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        // Replace whitespace runs with hyphens; strip anything that isn't
        // letter/digit/hyphen so the id is filename-safe.
        var out = ""
        for ch in trimmed {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == "-" || ch == "_" || ch == " " {
                out.append("-")
            }
        }
        // Collapse repeated hyphens.
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - View

struct ThemeEditorView: View {
    @ObservedObject var model: ThemeEditorModel

    var body: some View {
        VStack(spacing: 16) {
            preview
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    controls
                    Divider().padding(.vertical, 12)
                    headlineSection
                }
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 1000, minHeight: 920)
        .onAppear { model.regeneratePreview() }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.05))
            if let img = model.previewImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView("Rendering preview…")
            }
        }
        .frame(height: 480)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Theme name").frame(width: 110, alignment: .leading)
                TextField(model.placeholderName, text: $model.themeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
            }

            HStack {
                Text("Preset").frame(width: 110, alignment: .leading)
                presetMenu
                    .frame(maxWidth: 280)
                Spacer()
            }

            ColorRow(label: "Background", color: $model.background, trailing: {
                imageRowControls
            })

            ColorRow(label: "Headline", color: $model.headline, trailing: { EmptyView() })

            ForEach(0..<5) { i in
                ColorRow(label: "Level \(i)", color: $model.ramp[i], trailing: { EmptyView() })
            }

            HStack {
                Text("Dim overlay").frame(width: 110, alignment: .leading)
                Slider(value: $model.dimAlpha, in: 0...1)
                    .frame(maxWidth: 280)
                    .disabled(model.sourceImagePath == nil)
                Text(String(format: "%.2f", model.dimAlpha))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(model.sourceImagePath == nil ? .secondary : .primary)
                Spacer()
            }
        }
    }

    private var headlineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Headline")
                .font(.headline)
                .padding(.bottom, 2)

            // Text
            HStack {
                Text("Text").frame(width: 110, alignment: .leading)
                TextField("DESIGN  BUILD  SHIP", text: $model.headlineText)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }

            // Font style toggle
            HStack {
                Text("Font style").frame(width: 110, alignment: .leading)
                Picker("", selection: $model.headlineUseSystemFont) {
                    Text("Pixel glyphs").tag(false)
                    Text("System font").tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                Spacer()
            }

            // System font controls (only when system font selected)
            if model.headlineUseSystemFont {
                HStack(alignment: .top) {
                    Text("Family").frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        FontFamilyPickerButton(
                            family: $model.headlineFontFamily,
                            recentFamilies: $model.recentFontFamilies
                        )
                        // Inline sample: SwiftUI renders this instantly (no resvg).
                        Text(model.headlineText.isEmpty ? "DESIGN  BUILD  SHIP" : model.headlineText)
                            .font(.custom(
                                model.headlineFontFamily.isEmpty ? "SF Mono" : model.headlineFontFamily,
                                size: 20
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                    Spacer()
                }
                .onChange(of: model.headlineUseSystemFont) { _, isSystem in
                    if isSystem && model.headlineFontFamily.isEmpty {
                        model.headlineFontFamily = "SF Mono"
                    }
                }
            }

            // Size scale
            HStack {
                Text("Size").frame(width: 110, alignment: .leading)
                Slider(value: $model.headlineSizeScale, in: 0.5...2.0, step: 0.05)
                    .frame(maxWidth: 200)
                Text(String(format: "%.0f%%", model.headlineSizeScale * 100))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 44, alignment: .trailing)
                Stepper("", value: $model.headlineSizeScale, in: 0.5...2.0, step: 0.05)
                    .labelsHidden()
                Spacer()
            }

            Text("Headline settings apply globally (all themes + wallpaper rotations).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Drop-down that lets the user paste another theme's color palette
    /// onto the current draft without leaving the window. Only the color
    /// fields are copied — name, image background, and dim overlay stay
    /// put so the user can A/B presets while keeping their bespoke
    /// image/blur setup. Built-ins listed first; other custom themes
    /// (excluding the one being edited) appear below them.
    private var presetMenu: some View {
        Menu("Apply defaults from…") {
            Section("Built-in") {
                ForEach(Themes.builtins, id: \.id) { theme in
                    Button(theme.id) { model.applyDefaults(from: theme) }
                }
            }
            let customs = CustomThemes.shared.all().filter { $0.id != model.originalThemeID }
            if !customs.isEmpty {
                Section("Custom") {
                    ForEach(customs, id: \.id) { theme in
                        Button(theme.id) { model.applyDefaults(from: theme) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var imageRowControls: some View {
        if let src = model.sourceImagePath {
            Text((src as NSString).lastPathComponent)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Remove") { model.clearImage() }
        } else {
            Button("Add image…") { model.pickImage() }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.saveLabel) { model.save(applyImmediately: false) }
                    .disabled(model.isSaving || !model.canSave)
                Button(model.applyLabel) { model.save(applyImmediately: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSaving || !model.canSave)
            }
        }
    }
}

// MARK: - Font family picker

private struct FontFamilyPickerButton: View {
    @Binding var family: String
    @Binding var recentFamilies: [String]
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 6) {
                Text(family.isEmpty ? "Select font…" : family)
                    .font(family.isEmpty ? .body : .custom(family, size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 200, maxWidth: 280)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            FontFamilyPopoverContent(
                selectedFamily: $family,
                recentFamilies: $recentFamilies,
                isPresented: $showPopover
            )
        }
    }
}

private struct FontFamilyPopoverContent: View {
    @Binding var selectedFamily: String
    @Binding var recentFamilies: [String]
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private let allFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    private var filteredFamilies: [String] {
        guard !searchText.isEmpty else { return allFamilies }
        return allFamilies.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search fonts…", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(10)

            Divider()

            List {
                if searchText.isEmpty, !recentFamilies.isEmpty {
                    Section("Recently used") {
                        ForEach(recentFamilies, id: \.self) { f in fontRow(f) }
                    }
                    Section("All fonts") {
                        ForEach(filteredFamilies, id: \.self) { f in fontRow(f) }
                    }
                } else {
                    ForEach(filteredFamilies, id: \.self) { f in fontRow(f) }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 300, height: 400)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private func fontRow(_ f: String) -> some View {
        HStack {
            Text(f).font(.custom(f, size: 14)).lineLimit(1)
            Spacer()
            if f == selectedFamily {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFamily = f
            recentFamilies.removeAll { $0 == f }
            recentFamilies.insert(f, at: 0)
            if recentFamilies.count > 5 { recentFamilies = Array(recentFamilies.prefix(5)) }
            isPresented = false
        }
    }
}

// MARK: - Color rows

private struct ColorRow<Trailing: View>: View {
    let label: String
    @Binding var color: Color
    @ViewBuilder let trailing: Trailing

    /// Local mirror of the bound color as text. We keep this as `@State`
    /// rather than computing from `color` on every render so the user can
    /// type partial hex (`#f`, `#ff`) without us yanking the field back
    /// to the canonical `#rrggbb` form mid-edit.
    @State private var hexText: String = ""

    var body: some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            ColorPicker("", selection: $color, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 44)
            TextField("#rrggbb[aa]", text: $hexText)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onAppear { hexText = color.hex }
                // External update (e.g. ColorPicker) → resync the field,
                // but only if the field doesn't already round-trip to the
                // same color. Skipping the assignment when they agree
                // avoids clobbering an in-progress edit that happens to
                // currently parse to the same color.
                .onChange(of: color) { _, newColor in
                    if Color(hex: hexText)?.hex != newColor.hex {
                        hexText = newColor.hex
                    }
                }
                // User edit → push to the bound color the moment the text
                // parses as a valid hex. Invalid text (e.g. mid-typing
                // `#ff`) leaves `color` untouched.
                .onChange(of: hexText) { _, newText in
                    if let c = Color(hex: newText), c.hex != color.hex {
                        color = c
                    }
                }
            trailing
            Spacer()
        }
    }
}

// MARK: - Color <-> hex

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var int: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&int) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((int & 0xF00) >> 8) / 15
            g = Double((int & 0x0F0) >> 4) / 15
            b = Double(int & 0x00F) / 15
            a = 1
        case 4:
            r = Double((int & 0xF000) >> 12) / 15
            g = Double((int & 0x0F00) >> 8) / 15
            b = Double((int & 0x00F0) >> 4) / 15
            a = Double(int & 0x000F) / 15
        case 6:
            r = Double((int & 0xFF0000) >> 16) / 255
            g = Double((int & 0x00FF00) >> 8) / 255
            b = Double(int & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((int & 0xFF000000) >> 24) / 255
            g = Double((int & 0x00FF0000) >> 16) / 255
            b = Double((int & 0x0000FF00) >> 8) / 255
            a = Double(int & 0x000000FF) / 255
        default: return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// `#rrggbb` (or `#rrggbbaa` when alpha < 1) in sRGB. SwiftUI `Color`
    /// conversions can drift slightly across color spaces; we stay in sRGB
    /// for parity with CSS and resvg. Alpha is preserved so themes whose
    /// ramp varies by opacity (e.g. `paper`'s single-ink alpha scale)
    /// round-trip through the editor without collapsing to one color.
    var hex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        let r = max(0, min(255, Int((ns.redComponent * 255).rounded())))
        let g = max(0, min(255, Int((ns.greenComponent * 255).rounded())))
        let b = max(0, min(255, Int((ns.blueComponent * 255).rounded())))
        let a = max(0, min(255, Int((ns.alphaComponent * 255).rounded())))
        if a == 255 {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        return String(format: "#%02x%02x%02x%02x", r, g, b, a)
    }
}
#endif
