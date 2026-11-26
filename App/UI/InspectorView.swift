import SwiftUI
import DewrinkleCore

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brushSection
                effectSection
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
            PercentSlider(
                title: "De-wrinkle Clothing",
                hint: "Sets both sliders below. 50 is the natural amount. 100 is the strongest.",
                percent: Binding(
                    get: { Double(model.parameters.strength * 100) },
                    set: { model.setClothingLevel($0) }
                ),
                onCommit: { model.commitHistory("De-wrinkle clothing") }
            )
            PercentSlider(
                title: "Remove Fine Wrinkles",
                hint: "Sharp crease lines only. Fabric grain stays.",
                percent: binding(\.parameters.fine),
                onCommit: { model.commitHistory("Fine wrinkles") }
            )
            PercentSlider(
                title: "Remove Deep Wrinkles",
                hint: "Lifts fold shadows and lowers fold highlights. The shape of the body stays.",
                percent: binding(\.parameters.coarse),
                onCommit: { model.commitHistory("Deep wrinkles") }
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
            Text("De-wrinkle only touches the mask. The cloth is selected when you open a photo.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("De-wrinkle") { model.detectWrinkles() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .help("Select the clothing and smooth it. Skin, hands, and the hijab stay out unless you include the hijab. (A)")
                Button("Clear") { model.clearMask() }
                    .buttonStyle(.bordered)
                    .help("Clear this layer’s mask so de-wrinkle stops.")
            }
            .controlSize(.small)
            Toggle("Include hijab", isOn: Binding(
                get: { model.includeHijab },
                set: {
                    model.includeHijab = $0
                    model.detectWrinkles()
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .help("Off leaves the hijab out of the crease mask. On searches the hijab for creases too.")
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
            Text("Opening a photo finds creases on the cloth and shows them in red. Paint to add, Option-drag to erase. Embroidery, beading, seams, hems, skin, and hands stay out. The hijab stays out unless Include hijab is on.")
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
