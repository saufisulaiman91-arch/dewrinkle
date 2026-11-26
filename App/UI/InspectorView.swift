import SwiftUI
import DewrinkleCore

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brushSection
                effectSection
                noiseSection
                maskSection
                outputSection
            }
            .padding(16)
        }
        .background(Theme.panel)
        .scrollIndicators(.visible)
    }

    private var effectSection: some View {
        InspectorSection(title: "De-wrinkle") {
            HStack {
                Button("Natural") { model.usePreset(.standard) }
                    .help("Natural preset. Strength about 50%, broad folds and satin sheen stay. (no shortcut)")
                Button("Strong") { model.usePreset(.strong) }
                    .help("Strong preset. More of the crease shading is lifted. Broad folds are still partly kept.")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            PercentSlider(
                title: "Strength",
                hint: "How far crease shading moves toward smooth cloth. 50 is the natural default.",
                percent: binding(\.parameters.strength),
                onCommit: { model.commitHistory("De-wrinkle strength") }
            )
            PercentSlider(
                title: "Preserve folds",
                hint: "Keeps wide highlight and shadow. Higher leaves the drape of the skirt alone.",
                percent: Binding(
                    get: { Double(model.parameters.preserveFolds * 100) },
                    set: { model.parameters.preserveFolds = Float($0 / 100) }
                ),
                onCommit: { model.commitHistory("Preserve folds") }
            )
            PercentSlider(
                title: "Fine wrinkles",
                hint: "Small creases and crumpling. Weave stays in the high layer and is not blurred.",
                percent: binding(\.parameters.fine),
                onCommit: { model.commitHistory("Fine wrinkles") }
            )
            PercentSlider(
                title: "Coarse wrinkles",
                hint: "Broader folds. The radius stops short of a hijab or abaya’s drape.",
                percent: binding(\.parameters.coarse),
                onCommit: { model.commitHistory("Coarse wrinkles") }
            )
            Text(model.radiusCaption())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Custom radii", isOn: Binding(
                get: { model.useCustomRadii },
                set: { model.setCustomRadii($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            if model.useCustomRadii {
                radiusField("Detail", value: $model.detailRadius)
                radiusField("Fine", value: $model.fineRadius)
                radiusField("Coarse", value: $model.coarseRadius)
            }
            Button("Reset sliders") { model.resetEffect() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .help("Put de-wrinkle back to the Natural preset.")
        }
    }

    private var noiseSection: some View {
        InspectorSection(title: "Noise · \(model.selectedLayer?.name ?? "Layer")") {
            PercentSlider(
                title: "Luminance",
                hint: "Grain. Edge-aware, so seams are not the thing being smoothed.",
                percent: binding(\.noise.luminance),
                onCommit: { model.commitHistory("Noise reduction on \(model.selectedLayer?.name ?? "layer")") }
            )
            PercentSlider(
                title: "Colour",
                hint: "Chroma noise, blurred at a quarter of the resolution.",
                percent: binding(\.noise.chroma)
            )
            PercentSlider(
                title: "Detail",
                hint: "Higher keeps weave and edges. Lower lets the denoise go further.",
                percent: binding(\.noise.detail)
            )
            Toggle("Limit to mask", isOn: Binding(
                get: { model.noise.limitToMask },
                set: {
                    model.noise.limitToMask = $0
                    model.schedulePreview()
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            Text("Off until you raise an amount. It runs before de-wrinkle. The preview is downscaled, so judge grain on the export.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset noise") { model.resetNoise() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .help("Turn noise reduction off on this layer.")
        }
    }

    private var brushSection: some View {
        InspectorSection(title: "Brush") {
            Picker("Mode", selection: Binding(
                get: { model.brush.mode },
                set: { model.brush.mode = $0 }
            )) {
                Text("Paint").tag(BrushMode.paint)
                Text("Restore").tag(BrushMode.restore)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Paint adds de-wrinkle. Restore erases it. Option-drag also erases. (B to paint, E to erase)")
            PercentSlider(
                title: "Size",
                hint: "Full-resolution pixels. [ and ] change it. Option-drag restores.",
                percent: Binding(
                    get: { Double(model.brush.radius) },
                    set: { model.brush.radius = Float($0) }
                ),
                range: 8...1600
            )
            PercentSlider(
                title: "Hardness",
                hint: "100 is a hard edge. 0 feathers from the center.",
                percent: Binding(
                    get: { Double(model.brush.hardness * 100) },
                    set: { model.brush.hardness = Float($0 / 100) }
                )
            )
            PercentSlider(
                title: "Opacity",
                hint: "Each dab builds on the last. Restore paints the mask back out.",
                percent: Binding(
                    get: { Double(model.brush.opacity * 100) },
                    set: { model.brush.opacity = Float($0 / 100) }
                )
            )
        }
    }

    private var maskSection: some View {
        InspectorSection(title: "Mask") {
            Text("De-wrinkle only touches the mask. Noise is global unless you limit it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Auto suggest") { model.detectGarment() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .help("Fill this layer with the garment, including the hijab and not the face. (A)")
                Button("Clear") { model.clearMask() }
                    .buttonStyle(.bordered)
                    .help("Clear this layer’s mask so de-wrinkle stops.")
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                Button("Subject") { model.applyQuickMask("Select subject") }
                    .help("Select the person. Face and hands stay in this mask.")
                Button("Clothes") { model.applyQuickMask("Select clothing") }
                    .help("Select clothing, leaving out skin and the hijab.")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            HStack(spacing: 8) {
                Button("Skin") { model.applyQuickMask("Select skin") }
                    .help("Select face and hands, grown from the detected skin. Pink satin is not treated as skin.")
                Button("Hijab") { model.applyQuickMask("Select hijab") }
                    .help("Select the hijab around the face, stopping at the skin and the dress.")
                Button("Ground") { model.applyQuickMask("Select background") }
                    .help("Select everything that is not the person.")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            Button(model.canvasTool == .clickSelect ? "Click select is on" : "Click to select") {
                model.canvasTool = .clickSelect
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(Theme.accent)
            .help("Click the cloth, hijab, skin, or background. Shift-click adds, Option-click subtracts.")
            PercentSlider(
                title: "Select tolerance",
                hint: "How far Select Hijab and a missed click grow into similar colour. Hijab stays off the face and off the dress.",
                percent: $model.selectTolerance,
                range: 2...40
            )
            HStack {
                Button("Invert mask") { model.invertSelectedMask() }
                    .help("Swap painted and unpainted parts of this layer’s mask.")
                Button("Feather") { model.featherSelectedMask() }
                    .help("Soften the mask edge. De-wrinkle also feathers the brush as you paint.")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(Theme.accent)
            Toggle("Show mask", isOn: Binding(
                get: { model.maskOverlayVisible },
                set: {
                    model.maskOverlayVisible = $0
                    model.schedulePreview()
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            Text("Paint creases with the brush. Auto suggest and the select buttons fill this layer’s mask. Click select uses the person, clothing, skin, or background under the cursor. Shift-click adds, Option-click subtracts.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var outputSection: some View {
        InspectorSection(title: "Output") {
            Picker("Format", selection: $model.exportSettings.container) {
                ForEach(ExportContainer.allCases, id: \.self) { container in
                    Text(container.menuTitle).tag(container)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("JPEG, 16-bit TIFF, or 16-bit PNG. Export is ⌘E. A rotation is saved in the pixels, tagged upright.")
            if model.exportSettings.container == .jpeg {
                PercentSlider(
                    title: "JPEG quality",
                    hint: "92 is the default. The embedded ICC profile (sRGB, Display P3, or Adobe RGB) and EXIF are kept.",
                    percent: Binding(
                        get: { Double(model.exportSettings.jpegQuality * 100) },
                        set: { model.exportSettings.jpegQuality = Float($0 / 100) }
                    ),
                    range: 60...100
                )
            } else if model.exportSettings.container == .tiff16 {
                Text("16-bit LZW TIFF. Same ICC profile and EXIF as the file you opened, orientation set to upright.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("16-bit PNG with the original ICC profile.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(formatNote)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formatNote: String {
        switch model.photo?.source {
        case .jpeg:
            return "This file opened as JPEG, so JPEG is the default export. Switch the format if you want a 16-bit TIFF."
        case .tiff:
            return "This file opened as TIFF, so 16-bit TIFF is the default export."
        case .png:
            return "This file opened as PNG, so 16-bit PNG is the default export."
        case .other, .none:
            return "The default matches whatever you open."
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<EditorModel, Float>) -> Binding<Double> {
        Binding(
            get: { Double(model[keyPath: keyPath] * 100) },
            set: {
                model[keyPath: keyPath] = Float($0 / 100)
                model.schedulePreview()
            }
        )
    }

    private func radiusField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 52, alignment: .leading)
                .foregroundStyle(Theme.secondary)
            Slider(value: value, in: 1...800, onEditingChanged: { editing in
                if !editing { model.applyRadiusFields() }
            })
            .tint(Theme.accent)
            Text("\(Int(value.wrappedValue.rounded()))")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(Theme.primary)
        }
            .font(.system(size: 12))
            .help("\(title) radius in full-resolution pixels. Leave custom radii off to use the frame size.")
            .onChange(of: value.wrappedValue) { _, _ in
            model.applyRadiusFields()
        }
    }
}
