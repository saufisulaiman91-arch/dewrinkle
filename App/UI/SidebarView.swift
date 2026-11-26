import SwiftUI
import DewrinkleCore

struct SidebarView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            layersHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.layers) { layer in
                        layerRow(layer)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
            Divider().background(Theme.hairline)
            historyHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.historyRows.enumerated()), id: \.element.id) { _, row in
                        historyRow(row)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.panel)
    }

    private var layersHeader: some View {
        HStack {
            Text("LAYERS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.15)
                .foregroundStyle(Theme.tertiary)
            Spacer()
            Button { model.addLayer() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(model.photo == nil)
            Button { model.deleteSelectedLayer() } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless)
                .disabled(model.selectedLayerIsBackground || model.photo == nil)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func layerRow(_ layer: EditLayer) -> some View {
        let selected = layer.id == model.selectedLayerID
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    model.setLayerVisible(layer.id, !layer.visible)
                } label: {
                    Image(systemName: layer.visible ? "eye" : "eye.slash")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                Button {
                    model.selectLayer(layer.id)
                } label: {
                    Text(layer.name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(selected ? Theme.accent : Theme.primary)
            }
            .font(.system(size: 12))
            if selected {
                TextField("Name", text: Binding(
                    get: { layer.name },
                    set: { model.setLayerName(layer.id, to: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { model.commitHistory("Rename layer") }
                HStack {
                    Text("Opacity")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(layer.opacity * 100) },
                            set: { model.setLayerOpacity(layer.id, Float($0 / 100)) }
                        ),
                        in: 0...100,
                        onEditingChanged: { editing in
                            if !editing { model.commitHistory("\(layer.name) opacity") }
                        }
                    )
                    .tint(Theme.accent)
                    Text("\(Int((layer.opacity * 100).rounded()))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 28, alignment: .trailing)
                        .foregroundStyle(Theme.primary)
                }
                HStack {
                    Button("Up") { model.moveSelectedLayer(up: true) }
                    Button("Down") { model.moveSelectedLayer(up: false) }
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(8)
        .background(selected ? Theme.fill : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var historyHeader: some View {
        Text("HISTORY")
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.15)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private func historyRow(_ row: EditorModel.HistoryRow) -> some View {
        Button {
            model.jumpHistory(to: row.index)
        } label: {
            HStack {
                Text(row.name)
                    .lineLimit(1)
                Spacer()
                if row.isCurrent {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.system(size: 8))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(row.isFuture ? Theme.tertiary : (row.isCurrent ? Theme.accent : Theme.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }
}
