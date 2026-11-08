import SwiftUI

/// The project panel: every control for the open project.
///
/// - `.hand`: lives next to the LEFT hand as a RealityView attachment (StageView places it).
///   ~520 × 720 pt with its own glass background and a Pin button.
/// - `.window`: shown in the main window when hand tracking isn't available. The window
///   provides the glass.
///
/// Presentations (alerts, sheets, file pickers, menus) are avoided in the `.hand` context because
/// they aren't reliable from immersive-space attachments: errors show inline, item actions expand
/// inline, and "Import models" asks the main window to present the file picker.
struct ProjectPanelView: View {
    enum Context { case hand, window }

    private let context: Context

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// Item whose inline action strip is expanded (hand context).
    @State private var expandedItemID: UUID?
    @State private var isLeaving = false

    private static let quickScales: [Double] = [1, 5, 10, 25, 50, 100]

    init(context: Context) {
        self.context = context
    }

    private var isHand: Bool { context == .hand }

    var body: some View {
        if isHand {
            panel
                .frame(width: 520, height: 720)
                .glassBackgroundEffect()
        } else {
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.currentProject != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: isHand ? 12 : 16) {
                        if let error = model.lastError {
                            errorBanner(error)
                        }
                        modeSection
                        viewSection
                        scaleSection
                        placementSection
                        navigateSection
                        sceneSection
                        objectsSection
                    }
                    .padding(isHand ? 16 : 24)
                }
            } else {
                Spacer(minLength: 0)
                Text("No project is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Divider()
            footer
        }
    }

    // MARK: - 1. Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentProject?.name ?? "QVision")
                    .font(isHand ? .title3.weight(.semibold) : .title2.weight(.semibold))
                    .lineLimit(1)
                Text(objectCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isHand {
                Button {
                    model.isProjectPanelVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonBorderShape(.circle)
                .accessibilityLabel("Hide panel")
                .help("Hide the panel. Turn your left palm toward you and tap the palm button to bring it back.")
            }
        }
        .padding(.horizontal, isHand ? 20 : 24)
        .padding(.vertical, isHand ? 14 : 18)
    }

    private var objectCountText: String {
        let count = model.currentProject?.items.count ?? 0
        let objects = count == 1 ? "1 object" : "\(count) objects"
        return objects
    }

    // MARK: - 2. Mode

    private var modeSection: some View {
        PanelSection("Mode", systemImage: "hand.tap", compact: isHand) {
            Picker("Mode", selection: modeBinding) {
                ForEach(InteractionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.interactionMode == .edit
                 ? "Pinch and drag to move. Pinch with both hands to scale, twist to rotate."
                 : "Nothing moves. Tap a model, or a part of it, to see its details in the Inspector.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.interactionMode == .inspect && !model.isInspectorWindowOpen {
                Button {
                    openWindow(id: AppModel.inspectorWindowID)
                } label: {
                    Label("Open Inspector", systemImage: "info.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 3. View

    private var viewSection: some View {
        PanelSection("View", systemImage: "eye", compact: isHand) {
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
                    .padding(.top, 2)
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

    // MARK: - 4. Scale

    private var scaleSection: some View {
        let percent = model.sceneScalePercent

        return PanelSection("Scale", systemImage: "arrow.up.left.and.arrow.down.right", compact: isHand) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scale 1:\(DisplayFormat.scaleDenominator(percent: percent))")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Spacer(minLength: 8)
                Text("\(Int(percent.rounded())) %")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: scaleBinding, in: 1...100, step: 1)
                .accessibilityLabel("Scene scale")
                .accessibilityValue("\(Int(percent.rounded())) percent")

            HStack(spacing: 6) {
                ForEach(Self.quickScales, id: \.self) { value in
                    let isCurrent = Int(percent.rounded()) == Int(value)
                    Button {
                        model.sceneScalePercent = value
                    } label: {
                        Text("\(Int(value))%")
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .tint(isCurrent ? Color.accentColor : nil)
                    .accessibilityLabel("Scale \(Int(value)) percent")
                }
            }

            Toggle(isOn: tabletopBinding) {
                Label("Table height", systemImage: "arrow.up.to.line")
            }
            .disabled(percent >= 100)
            .frame(minHeight: 44)

            Text(percent >= 100
                 ? "100 % is real size. Scale the whole scene down to view it like a model."
                 : "The whole scene shrinks in place. Table height lifts it to 75 cm.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 5. Placement

    private var placementSection: some View {
        let selectedID = model.selectedItemID
        let selectedLocked = selectedID.map { model.isItemLocked($0) } ?? false

        return PanelSection("Placement", systemImage: "square.and.arrow.down.on.square", compact: isHand) {
            Toggle(isOn: snapBinding) {
                Label("Snap to floor", systemImage: "arrow.down.to.line")
            }
            .frame(minHeight: 44)

            Button {
                model.dropSelectedToFloor()
            } label: {
                Label("Drop selected to floor", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(selectedID == nil || selectedLocked)
        }
    }

    // MARK: - 6. Navigate

    private var navigateSection: some View {
        PanelSection("Navigate", systemImage: "move.3d", compact: isHand) {
            Toggle(isOn: flyBinding) {
                Label("Fly mode", systemImage: "airplane")
            }
            .frame(minHeight: 44)

            Text("Clench both fists, then push to move (farther = faster), twist to turn. Open a hand to stop.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = handTrackingWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Fly speed")
                Spacer(minLength: 8)
                Text(flySpeedText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: flySpeedBinding, in: 0.25...4, step: 0.25)
                .accessibilityLabel("Fly speed")
                .accessibilityValue(flySpeedText)

            Button {
                model.recenter()
            } label: {
                Label("Recenter", systemImage: "scope")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private var flySpeedText: String {
        let speed = model.flySpeed
        let isHalfStep = (speed * 2).rounded() == speed * 2
        return String(format: isHalfStep ? "%.1f×" : "%.2f×", Double(speed))
    }

    private var handTrackingWarning: String? {
        switch model.hands.status {
        case .denied:
            return "Hand tracking is not allowed. Enable it for QVision in Settings › Privacy & Security to use Fly mode and the hand panel."
        case .unsupported:
            return "Hand tracking isn't available on this device (for example in the Simulator), so Fly mode won't respond."
        case .failed(let message):
            return "Hand tracking stopped: \(message)"
        default:
            return nil
        }
    }

    // MARK: - 7. Scene

    private var sceneSection: some View {
        PanelSection("Scene", systemImage: "cube.transparent", compact: isHand) {
            HStack(spacing: 10) {
                sceneButton("Import models", systemImage: "square.and.arrow.down") {
                    requestImport()
                }
                sceneButton("Add test cube", systemImage: "cube") {
                    Task { await model.addTestCube() }
                }
                sceneButton("Reset scene", systemImage: "arrow.counterclockwise") {
                    model.resetScene()
                }
            }
            .disabled(model.isLoading)

            if let progress = model.importProgress {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(progress)
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func sceneButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.bordered)
    }

    /// The file picker is presented by RootView in the main window (reliable there), which is
    /// opened for it if needed and handed back to the hand panel afterwards.
    private func requestImport() {
        model.isImportPickerRequested = true
        if !model.isMainWindowOpen {
            openWindow(id: AppModel.mainWindowID)
        }
    }

    // MARK: - 8. Objects

    private var objectsSection: some View {
        PanelSection("Objects", systemImage: "list.bullet", compact: isHand) {
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
        let isExpanded = isHand && expandedItemID == item.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    model.select(isSelected ? nil : item.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.primitive == .cube ? "cube" : "cube.transparent")
                            .foregroundStyle(.secondary)
                        Text(item.name)
                            .lineLimit(1)
                        if layer?.isLocked == true {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(layer?.name ?? "No layer")
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 48)
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

                if isHand {
                    Button {
                        expandedItemID = isExpanded ? nil : item.id
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(isExpanded ? "Hide actions" : "More actions")
                } else {
                    Menu {
                        itemMenuActions(item, layers: project.layers)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("More actions")
                }
            }
            .padding(.trailing, 4)

            if isExpanded {
                inlineActions(item, layers: project.layers)
            }
        }
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Menu content for the `.window` context.
    @ViewBuilder
    private func itemMenuActions(_ item: ProjectItem, layers: [Layer]) -> some View {
        Button {
            Task { await model.duplicateItem(item.id) }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .disabled(model.isLoading)

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

        Button {
            model.dropItemToFloor(item.id)
        } label: {
            Label("Drop to Floor", systemImage: "arrow.down.circle")
        }
        .disabled(model.isItemLocked(item.id))

        Button(role: .destructive) {
            model.removeItem(item.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Inline action strip for the `.hand` context (no menus in attachments).
    private func inlineActions(_ item: ProjectItem, layers: [Layer]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                inlineButton("Duplicate", systemImage: "plus.square.on.square") {
                    Task { await model.duplicateItem(item.id) }
                }
                .disabled(model.isLoading)

                inlineButton("Drop to floor", systemImage: "arrow.down.circle") {
                    model.dropItemToFloor(item.id)
                }
                .disabled(model.isItemLocked(item.id))

                inlineButton("Delete", systemImage: "trash") {
                    expandedItemID = nil
                    model.removeItem(item.id)
                }
                .tint(.red)
            }

            if layers.count > 1 {
                Text("Move to layer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(layers) { layer in
                            Button {
                                model.moveItem(item.id, toLayer: layer.id)
                            } label: {
                                Label(layer.name, systemImage: layer.id == item.layerID ? "checkmark" : "square.3.layers.3d")
                                    .font(.callout)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .tint(layer.id == item.layerID ? Color.accentColor : nil)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func inlineButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Errors (inline; alerts aren't reliable from attachments)

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .padding(.top, 2)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                model.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Dismiss message")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 9. Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                toggleLayersWindow()
            } label: {
                Label(model.isLayersWindowOpen ? "Hide Layers" : "Layers", systemImage: "square.3.layers.3d")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.bordered)
            .disabled(model.currentProject == nil)

            Button(role: .destructive) {
                leave()
            } label: {
                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isLeaving || model.currentProject == nil)
        }
        .controlSize(.large)
        .padding(.horizontal, isHand ? 16 : 24)
        .padding(.vertical, isHand ? 14 : 18)
    }

    private func toggleLayersWindow() {
        if model.isLayersWindowOpen {
            dismissWindow(id: AppModel.layersWindowID)
        } else {
            openWindow(id: AppModel.layersWindowID)
        }
    }

    /// Leave: back to All Projects.
    /// openWindow(main) → closeProject() → dismiss Layers / Inspector → dismissImmersiveSpace().
    private func leave() {
        guard !isLeaving else { return }
        isLeaving = true

        let layersOpen = model.isLayersWindowOpen
        let inspectorOpen = model.isInspectorWindowOpen

        if !model.isMainWindowOpen {
            openWindow(id: AppModel.mainWindowID)
        }
        model.closeProject()
        if layersOpen {
            dismissWindow(id: AppModel.layersWindowID)
        }
        if inspectorOpen {
            dismissWindow(id: AppModel.inspectorWindowID)
        }

        // Claim the transition synchronously so RootView's own stage sync (if its window is
        // alive) sees `.transitioning` and doesn't dismiss the space a second time.
        let needsDismiss = model.stageState == .open
        if needsDismiss {
            model.stageState = .transitioning
        }
        let appModel = model
        let dismissSpace = dismissImmersiveSpace
        let panelOpen = model.isProjectPanelVisible
        let closeWindow = dismissWindow
        Task { @MainActor in
            if needsDismiss {
                await dismissSpace()
                appModel.stageState = .closed
            }
            isLeaving = false
            // The panel window is where Leave was tapped; close it last.
            if panelOpen {
                closeWindow(id: AppModel.panelWindowID)
            }
        }
    }

    // MARK: - Bindings

    private var modeBinding: Binding<InteractionMode> {
        Binding(
            get: { model.interactionMode },
            set: { newValue in
                model.interactionMode = newValue
                if newValue == .inspect && !model.isInspectorWindowOpen {
                    openWindow(id: AppModel.inspectorWindowID)
                }
            }
        )
    }

    private var viewModeBinding: Binding<ViewMode> {
        Binding(get: { model.viewMode }, set: { model.viewMode = $0 })
    }

    private var environmentBinding: Binding<EnvironmentPreset> {
        Binding(get: { model.environment }, set: { model.environment = $0 })
    }

    private var scaleBinding: Binding<Double> {
        Binding(get: { model.sceneScalePercent }, set: { model.sceneScalePercent = $0 })
    }

    private var tabletopBinding: Binding<Bool> {
        Binding(get: { model.isTabletop }, set: { model.isTabletop = $0 })
    }

    private var snapBinding: Binding<Bool> {
        Binding(get: { model.snapToFloor }, set: { model.snapToFloor = $0 })
    }

    private var flyBinding: Binding<Bool> {
        Binding(get: { model.isFlyModeEnabled }, set: { model.isFlyModeEnabled = $0 })
    }

    private var flySpeedBinding: Binding<Float> {
        Binding(get: { model.flySpeed }, set: { model.flySpeed = $0 })
    }
}

/// A titled card grouping one part of the project panel.
private struct PanelSection<Content: View>: View {
    let title: String
    let systemImage: String
    let compact: Bool
    let content: Content

    init(_ title: String, systemImage: String, compact: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .padding(compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 20 : 24, style: .continuous))
    }
}
