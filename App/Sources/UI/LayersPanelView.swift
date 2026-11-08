import SwiftUI

/// Layers UI. Used twice:
/// - compact = true: the floating panel in the stage (RealityView attachment, ~420x560 pt),
///   with a "Layers" header and a close button.
/// - compact = false: embedded in the main panel (ProjectWorkspaceView).
///
/// Renaming is inline (TextField in the row) rather than an alert, because alerts are not
/// reliable from views hosted as RealityView attachments.
struct LayersPanelView: View {
    private let compact: Bool

    @Environment(AppModel.self) private var model

    @State private var expandedLayerIDs: Set<UUID> = []
    @State private var renamingLayerID: UUID?
    @State private var renameText = ""

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 12) {
                compactHeader
                Divider()
                ScrollView {
                    layersContent
                        .padding(.bottom, 8)
                }
            }
            .padding(20)
            .frame(width: 420, height: 560, alignment: .top)
        } else {
            layersContent
        }
    }

    // MARK: - Header (compact only)

    private var compactHeader: some View {
        HStack(spacing: 12) {
            Label("Layers", systemImage: "square.3.layers.3d")
                .font(.title2.weight(.semibold))
            Spacer(minLength: 8)
            Button {
                model.isLayersPanelVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close Layers")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var layersContent: some View {
        if let project = model.currentProject {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(project.layers) { layer in
                    layerBlock(layer, in: project)
                }

                Button {
                    model.addLayer(named: "")
                } label: {
                    Label("New Layer", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
            }
        } else {
            Text("No project is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    private func layerBlock(_ layer: Layer, in project: Project) -> some View {
        let items = project.items.filter { $0.layerID == layer.id }
        let isExpanded = expandedLayerIDs.contains(layer.id)

        return VStack(alignment: .leading, spacing: 4) {
            layerRow(layer, itemCount: items.count, isExpanded: isExpanded, canDelete: project.layers.count > 1)

            if isExpanded {
                if items.isEmpty {
                    Text("No objects on this layer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 56)
                        .frame(minHeight: 36)
                } else {
                    ForEach(items) { item in
                        itemRow(item, layerVisible: layer.isVisible)
                    }
                }
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Layer row

    private func layerRow(_ layer: Layer, itemCount: Int, isExpanded: Bool, canDelete: Bool) -> some View {
        HStack(spacing: 6) {
            iconButton(isExpanded ? "chevron.down" : "chevron.right",
                       label: isExpanded ? "Collapse" : "Expand") {
                if isExpanded {
                    expandedLayerIDs.remove(layer.id)
                } else {
                    expandedLayerIDs.insert(layer.id)
                }
            }

            iconButton(layer.isVisible ? "eye" : "eye.slash",
                       label: layer.isVisible ? "Hide layer" : "Show layer") {
                model.setLayerVisible(layer.id, !layer.isVisible)
            }

            iconButton(layer.isLocked ? "lock.fill" : "lock.open",
                       label: layer.isLocked ? "Unlock layer" : "Lock layer") {
                model.setLayerLocked(layer.id, !layer.isLocked)
            }

            if renamingLayerID == layer.id {
                TextField("Layer name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename() }
                iconButton("checkmark", label: "Done") { commitRename() }
            } else {
                Text(layer.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .opacity(layer.isVisible ? 1 : 0.5)
                Spacer(minLength: 8)
                Text("\(itemCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 6)
            }
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                renameText = layer.name
                renamingLayerID = layer.id
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                if renamingLayerID == layer.id { renamingLayerID = nil }
                model.deleteLayer(layer.id)
            } label: {
                Label("Delete Layer", systemImage: "trash")
            }
            .disabled(!canDelete)
        }
    }

    // MARK: - Item row

    private func itemRow(_ item: ProjectItem, layerVisible: Bool) -> some View {
        let isSelected = model.selectedItemID == item.id

        return HStack(spacing: 6) {
            Button {
                model.select(isSelected ? nil : item.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.primitive == .cube ? "cube" : "cube.transparent")
                        .foregroundStyle(.secondary)
                    Text(item.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.isHidden || !layerVisible ? 0.5 : 1)

            iconButton(item.isHidden ? "eye.slash" : "eye",
                       label: item.isHidden ? "Show object" : "Hide object") {
                model.setItemHidden(item.id, !item.isHidden)
            }
        }
        .padding(.leading, 44)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Helpers

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func commitRename() {
        if let id = renamingLayerID {
            model.renameLayer(id, to: renameText)
        }
        renamingLayerID = nil
    }
}
