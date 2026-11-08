import SwiftUI
import UniformTypeIdentifiers

/// The one main panel inside a project. Every control lives here, on a single scroll.
struct ProjectWorkspaceView: View {
    @Environment(AppModel.self) private var model

    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    viewSection
                    navigateSection
                    sceneSection
                    objectsSection
                    if let project = model.currentProject,
                       let selectedID = model.selectedItemID,
                       let item = project.items.first(where: { $0.id == selectedID }) {
                        inspectorSection(item, in: project)
                    }
                    layersSection
                }
                .padding(24)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: AppModel.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importAssets(urls) }
            case .failure(let error):
                model.lastError = "Couldn't open the file picker: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 1. Header

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                model.closeProject()
            } label: {
                Label("All Projects", systemImage: "chevron.left")
            }
            .controlSize(.large)

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.currentProject?.name ?? "")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(objectCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var objectCountText: String {
        let count = model.currentProject?.items.count ?? 0
        return count == 1 ? "1 object" : "\(count) objects"
    }

    // MARK: - 2. View

    private var viewSection: some View {
        PanelSection("View", systemImage: "eye") {
            Picker("View mode", selection: viewModeBinding) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.viewMode == .full {
                Text("Environment")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Picker("Environment", selection: environmentBinding) {
                    ForEach(EnvironmentPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - 3. Navigate

    private var navigateSection: some View {
        PanelSection("Navigate", systemImage: "move.3d") {
            Toggle(isOn: flyBinding) {
                Label("Fly mode", systemImage: "airplane")
            }
            .frame(minHeight: 44)

            Text("Clench both fists, then push to move, twist to turn. Open a hand to stop.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = handTrackingWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.recenter()
            } label: {
                Label("Recenter", systemImage: "scope")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private var handTrackingWarning: String? {
        switch model.hands.status {
        case .denied:
            return "Hand tracking is not allowed. Enable it for QVision in Settings › Privacy & Security to use Fly mode and the palm menu."
        case .unsupported:
            return "Hand tracking isn't available on this device (for example in the Simulator), so Fly mode won't respond."
        case .failed(let message):
            return "Hand tracking stopped: \(message)"
        default:
            return nil
        }
    }

    // MARK: - 4. Scene

    private var sceneSection: some View {
        PanelSection("Scene", systemImage: "cube.transparent") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                sceneButton("Import models", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                sceneButton("Add test cube", systemImage: "cube") {
                    Task { await model.addTestCube() }
                }
                sceneButton("Reset scene", systemImage: "arrow.counterclockwise") {
                    model.resetScene()
                }
                sceneButton(model.isLayersPanelVisible ? "Hide Layers…" : "Layers…",
                            systemImage: "square.3.layers.3d") {
                    model.isLayersPanelVisible.toggle()
                }
            }
            .disabled(model.isLoading)
        }
    }

    private func sceneButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - 5. Objects

    private var objectsSection: some View {
        PanelSection("Objects", systemImage: "list.bullet") {
            if let project = model.currentProject, !project.items.isEmpty {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(project.items) { item in
                        objectRow(item, in: project)
                    }
                }
            } else {
                Text("No objects yet. Import a USDZ, USD, Reality or OBJ file, or add a test cube.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func objectRow(_ item: ProjectItem, in project: Project) -> some View {
        let isSelected = model.selectedItemID == item.id
        let layer = project.layer(item.layerID)
        let dimmed = item.isHidden || !(layer?.isVisible ?? true)

        return HStack(spacing: 8) {
            Button {
                model.select(isSelected ? nil : item.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.primitive == .cube ? "cube" : "cube.transparent")
                        .foregroundStyle(.secondary)
                    Text(item.name)
                        .lineLimit(1)
                    if layer?.isLocked == true {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(layer?.name ?? "No layer")
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(dimmed ? 0.5 : 1)

            Button {
                model.setItemHidden(item.id, !item.isHidden)
            } label: {
                Image(systemName: item.isHidden ? "eye.slash" : "eye")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .accessibilityLabel(item.isHidden ? "Show object" : "Hide object")

            Menu {
                itemActions(item, layers: project.layers)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel("More actions")
        }
        .padding(.trailing, 6)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            itemActions(item, layers: project.layers)
        }
    }

    @ViewBuilder
    private func itemActions(_ item: ProjectItem, layers: [Layer]) -> some View {
        Button {
            Task { await model.duplicateItem(item.id) }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        Menu {
            ForEach(layers) { layer in
                Button {
                    model.moveItem(item.id, toLayer: layer.id)
                } label: {
                    if layer.id == item.layerID {
                        Label(layer.name, systemImage: "checkmark")
                    } else {
                        Text(layer.name)
                    }
                }
            }
        } label: {
            Label("Move to Layer", systemImage: "square.3.layers.3d")
        }

        Button(role: .destructive) {
            model.removeItem(item.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - 6. Inspector

    private func inspectorSection(_ item: ProjectItem, in project: Project) -> some View {
        PanelSection("Inspector", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(inspectorSubtitle(item, in: project))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    model.setItemHidden(item.id, !item.isHidden)
                } label: {
                    Label(item.isHidden ? "Show" : "Hide",
                          systemImage: item.isHidden ? "eye" : "eye.slash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await model.duplicateItem(item.id) }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoading)

                Button(role: .destructive) {
                    model.removeItem(item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func inspectorSubtitle(_ item: ProjectItem, in project: Project) -> String {
        var parts: [String] = []
        parts.append("Layer: " + (project.layer(item.layerID)?.name ?? "None"))
        if model.isItemLocked(item.id) { parts.append("Locked") }
        if item.isHidden { parts.append("Hidden") }
        if item.primitive == .cube {
            parts.append("Test cube")
        } else if let file = item.assetFileName {
            parts.append(file)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Layers (same UI as the floating hand panel)

    private var layersSection: some View {
        PanelSection("Layers", systemImage: "square.3.layers.3d") {
            LayersPanelView(compact: false)
        }
    }

    // MARK: - Bindings

    private var viewModeBinding: Binding<ViewMode> {
        Binding(get: { model.viewMode }, set: { model.viewMode = $0 })
    }

    private var environmentBinding: Binding<EnvironmentPreset> {
        Binding(get: { model.environment }, set: { model.environment = $0 })
    }

    private var flyBinding: Binding<Bool> {
        Binding(get: { model.isFlyModeEnabled }, set: { model.isFlyModeEnabled = $0 })
    }
}

/// A titled card grouping one part of the main panel.
private struct PanelSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
