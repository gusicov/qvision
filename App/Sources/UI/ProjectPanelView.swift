import SwiftUI

/// The project panel: every control for the open project (v0.7: compact).
///
/// Layout:
/// - Header: QVision mark, "Home › Project" (Home leaves the project), a one-line summary,
///   Back / Forward (places) and Undo / Redo (edits).
/// - Cards: Mode & view · Navigate (fly, speed, recenter) · Objects (import, units, list).
/// - Advanced (collapsed by default, remembered): scene scale, table height, snapping, reset.
/// - Footer: Layers · Inspector · Leave.
///
/// Shown in the panel window (`ProjectPanelWindowView`) and, without hand tracking, in the main
/// window. Both are real windows, so menus are used. `.hand` keeps the old attachment framing.
struct ProjectPanelView: View {
    enum Context { case hand, window }

    private let context: Context

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("qvision.panel.advancedExpanded") private var isAdvancedExpanded = false

    private static let quickScales: [Double] = [1, 5, 10, 25, 50, 100]
    private static let quickFlySpeeds: [Float] = [1, 3, 10]

    init(context: Context = .window) {
        self.context = context
    }

    var body: some View {
        if context == .hand {
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

            if let project = model.currentProject {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsStageClosedBanner {
                            stageClosedBanner
                        }
                        if let error = model.lastError {
                            errorBanner(error)
                        }
                        modeCard
                        navigateCard
                        objectsCard(project)
                        advancedCard
                    }
                    .padding(18)
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BrandMark(size: 34)
                Breadcrumb(components: ["Home", model.currentProject?.name ?? "Project"],
                           prominent: true,
                           onHome: model.isTransitioning ? nil : { model.requestLeave() })
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                historyControls
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var summaryText: String {
        guard let project = model.currentProject else { return "" }
        let count = project.items.count
        var parts = [count == 1 ? "1 object" : "\(count) objects", model.interactionMode.title]
        if project.scenePercent < 100 {
            parts.append("1:\(DisplayFormat.scaleDenominator(percent: project.scenePercent))")
        }
        return parts.joined(separator: " · ")
    }

    /// Back / Forward (places) | Undo / Redo (edits).
    private var historyControls: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(title: "Back to the previous place", systemImage: "chevron.backward") {
                model.goBack()
            }
            .disabled(!model.canGoBack)

            ToolbarIconButton(title: "Forward to the next place", systemImage: "chevron.forward") {
                model.goForward()
            }
            .disabled(!model.canGoForward)

            Divider()
                .frame(height: 26)
                .padding(.horizontal, 4)

            ToolbarIconButton(title: "Undo", systemImage: "arrow.uturn.backward") {
                model.undo()
            }
            .disabled(!model.canUndo)

            ToolbarIconButton(title: "Redo", systemImage: "arrow.uturn.forward") {
                model.redo()
            }
            .disabled(!model.canRedo)
        }
        .padding(.horizontal, 6)
        .background(.thinMaterial, in: Capsule())
    }

    // MARK: - Mode & view

    private var modeCard: some View {
        PanelCard {
            labeledRow("Mode") {
                Picker("Mode", selection: modeBinding) {
                    ForEach(InteractionMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text(model.interactionMode.hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isFlyModeEnabled && model.interactionMode != .view {
                Label("Fly mode is on: models are locked until you turn it off.", systemImage: "airplane")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.interactionMode == .inspect && !model.isInspectorWindowOpen {
                Button {
                    openWindow(id: AppModel.inspectorWindowID)
                } label: {
                    Label("Open Inspector", systemImage: "info.circle")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
            }

            Divider().padding(.vertical, 2)

            labeledRow("View") {
                Picker("View", selection: viewModeBinding) {
                    ForEach(ViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if model.viewMode == .full {
                labeledRow("Sky") {
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
    }

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            content()
        }
    }

    // MARK: - Navigate

    private var navigateCard: some View {
        PanelCard {
            HStack(spacing: 12) {
                Toggle(isOn: flyBinding) {
                    Label("Fly mode", systemImage: "airplane")
                        .font(.headline)
                }
                .frame(minHeight: 44)
            }

            if model.isFlyModeEnabled {
                Text("Clench both fists, then push to move (farther = faster), twist to turn. Open a hand to stop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warning = handTrackingWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Text("Speed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Slider(value: flySpeedBinding, in: AppModel.flySpeedRange, step: 0.25)
                    .accessibilityLabel("Fly speed")
                    .accessibilityValue(DisplayFormat.multiplier(model.flySpeed))
                Text(DisplayFormat.multiplier(model.flySpeed))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 56, alignment: .trailing)
            }

            HStack(spacing: 8) {
                ForEach(Self.quickFlySpeeds, id: \.self) { value in
                    let isCurrent = abs(model.flySpeed - value) < 0.01
                    Button {
                        model.flySpeed = value
                    } label: {
                        Text(DisplayFormat.multiplier(value))
                            .font(.callout.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .tint(isCurrent ? Color.accentColor : nil)
                    .accessibilityLabel("Fly speed \(DisplayFormat.multiplier(value))")
                }

                Button {
                    model.recenter()
                } label: {
                    Label("Recenter", systemImage: "scope")
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .help("Back to where the project started. Back returns here.")
            }
        }
    }

    private var handTrackingWarning: String? {
        switch model.hands.status {
        case .denied:
            return "Hand tracking is not allowed. Enable it for QVision in Settings › Privacy & Security to use Fly mode and the palm button."
        case .unsupported:
            return "Hand tracking isn't available on this device (for example in the Simulator), so Fly mode won't respond."
        case .failed(let message):
            return "Hand tracking stopped: \(message)"
        default:
            return nil
        }
    }

    // MARK: - Objects

    private func objectsCard(_ project: Project) -> some View {
        PanelCard {
            SectionTitle("Objects", systemImage: "cube.transparent") {
                InfoPill(text: "\(project.items.count)")
            }

            HStack(spacing: 10) {
                Button {
                    requestImport()
                } label: {
                    Label("Import models", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.addTestCube() }
                } label: {
                    Label("Test cube", systemImage: "cube")
                        .lineLimit(1)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
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

            ForEach(model.importNotes) { note in
                importNoteBanner(note, in: project)
            }

            if let selectedID = model.selectedItemID,
               let item = project.items.first(where: { $0.id == selectedID }) {
                selectedItemStrip(item)
            }

            if project.items.isEmpty {
                Text("No objects yet. Import a USDZ, USD, Reality or OBJ file, or add a test cube.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(project.items) { item in
                        objectRow(item, in: project)
                    }
                }
            }
        }
    }

    /// L2: "Detected centimetres → scaled ×0.01 (now 12.4 × 8.1 × 7.9 m)" + a Units fix.
    private func importNoteBanner(_ note: AppModel.ImportNote, in project: Project) -> some View {
        let item = project.items.first { $0.id == note.itemID }

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "ruler")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Imported “\(note.itemName)”")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(note.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let item {
                    unitsMenu(item, compact: true)
                }
            }
            Spacer(minLength: 4)
            Button {
                model.dismissImportNote(note.id)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func selectedItemStrip(_ item: ProjectItem) -> some View {
        let locked = model.isItemLocked(item.id)
        let unit = model.unit(of: item)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: item.primitive == .cube ? "cube.fill" : "cube.transparent.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let size = model.size(of: item, in: unit) {
                        Text(DisplayFormat.dimensions(size))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if locked {
                    InfoPill(text: "Locked", systemImage: "lock.fill")
                }
                Button {
                    model.select(nil)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Deselect")
            }

            HStack(spacing: 8) {
                unitsMenu(item, compact: false)

                Button {
                    model.dropItemToFloor(item.id)
                } label: {
                    Label("Floor", systemImage: "arrow.down.to.line")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(locked)
                .help("Drop to the floor")

                Button(role: .destructive) {
                    model.removeItem(item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .font(.callout)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Units fix menu (m, cm, mm, in, ft). Each choice shows the size it would give.
    private func unitsMenu(_ item: ProjectItem, compact: Bool) -> some View {
        let current = model.unit(of: item)
        let locked = model.isItemLocked(item.id)

        return Menu {
            Section("File units") {
                unitButtons(item, current: current)
            }
        } label: {
            Label(compact ? "Units: \(current.symbol)" : current.symbol, systemImage: "ruler")
                .lineLimit(1)
                .frame(maxWidth: compact ? nil : .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .disabled(locked || model.isLoading)
        .help("The units the file was made in")
        .accessibilityLabel("Units, currently \(current.title)")
    }

    @ViewBuilder
    private func unitButtons(_ item: ProjectItem, current: ModelUnit) -> some View {
        ForEach(ModelUnit.allCases) { unit in
            Button {
                model.setItemUnit(item.id, unit)
            } label: {
                let title = unitTitle(item, unit)
                if unit == current {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
    }

    private func unitTitle(_ item: ProjectItem, _ unit: ModelUnit) -> String {
        guard let size = model.size(of: item, in: unit) else { return unit.title }
        return "\(unit.title): \(DisplayFormat.dimensions(size))"
    }

    private func objectRow(_ item: ProjectItem, in project: Project) -> some View {
        let isSelected = model.selectedItemID == item.id
        let layer = project.layer(item.layerID)
        let dimmed = item.isHidden || !(layer?.isVisible ?? true)

        return HStack(spacing: 4) {
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
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if project.layers.count > 1 {
                        Text(layer?.name ?? "No layer")
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(dimmed ? 0.5 : 1)

            Button {
                model.setItemHidden(item.id, !item.isHidden)
            } label: {
                Image(systemName: item.isHidden ? "eye.slash" : "eye")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .accessibilityLabel(item.isHidden ? "Show object" : "Hide object")

            Menu {
                itemMenuActions(item, layers: project.layers)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 40, height: 40)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel("More actions")
        }
        .padding(.trailing, 2)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func itemMenuActions(_ item: ProjectItem, layers: [Layer]) -> some View {
        let locked = model.isItemLocked(item.id)

        Button {
            Task { await model.duplicateItem(item.id) }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .disabled(model.isLoading)

        Menu {
            unitButtons(item, current: model.unit(of: item))
        } label: {
            Label("Units", systemImage: "ruler")
        }
        .disabled(locked)

        if layers.count > 1 {
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
        }

        Button {
            model.dropItemToFloor(item.id)
        } label: {
            Label("Drop to Floor", systemImage: "arrow.down.circle")
        }
        .disabled(locked)

        Button(role: .destructive) {
            model.removeItem(item.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// The file picker is presented by RootView in the main window (reliable there), which is
    /// opened for it if needed and handed back to the panel window afterwards.
    private func requestImport() {
        model.isImportPickerRequested = true
        if !model.isMainWindowOpen {
            openWindow(id: AppModel.mainWindowID)
        }
    }

    // MARK: - Advanced

    private var advancedCard: some View {
        let percent = model.sceneScalePercent

        return DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                // Scene scale
                HStack(alignment: .firstTextBaseline) {
                    Text("Scene scale 1:\(DisplayFormat.scaleDenominator(percent: percent))")
                        .font(.headline.monospacedDigit())
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
                                .frame(maxWidth: .infinity, minHeight: 34)
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

                Text(percent >= 100
                     ? "100 % is real size. Scale the whole scene down to view it like a model."
                     : "The whole scene shrinks in place. Table height lifts it to 75 cm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle(isOn: snapBinding) {
                    Label("Snap to floor while dragging", systemImage: "arrow.down.to.line")
                }

                Button {
                    model.resetScene()
                } label: {
                    Label("Reset scene", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoading)
                .help("Every object back to where it was first placed. Undo brings them back.")
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Label("Advanced", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer(minLength: 8)
                Text("Scale 1:\(DisplayFormat.scaleDenominator(percent: percent)) · Snap \(model.snapToFloor ? "on" : "off")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .qvCard(padding: 16, cornerRadius: 20)
    }

    // MARK: - Banners

    private var showsStageClosedBanner: Bool {
        model.currentProject != nil && model.stageState == .closed && !model.isTransitioning
    }

    private var stageClosedBanner: some View {
        HStack(spacing: 12) {
            Label("The 3D stage is closed.", systemImage: "cube.transparent")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Open Stage") {
                model.requestStageSync()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                toggleLayersWindow()
            } label: {
                Label(model.isLayersWindowOpen ? "Hide Layers" : "Layers", systemImage: "square.3.layers.3d")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .disabled(model.currentProject == nil)

            Button {
                toggleInspectorWindow()
            } label: {
                Label(model.isInspectorWindowOpen ? "Hide Inspector" : "Inspector", systemImage: "info.circle")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .disabled(model.currentProject == nil)

            Button(role: .destructive) {
                model.requestLeave()
            } label: {
                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(model.isTransitioning || model.currentProject == nil)
            .help("Save and return to Home")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func toggleLayersWindow() {
        if model.isLayersWindowOpen {
            dismissWindow(id: AppModel.layersWindowID)
        } else {
            openWindow(id: AppModel.layersWindowID)
        }
    }

    private func toggleInspectorWindow() {
        if model.isInspectorWindowOpen {
            dismissWindow(id: AppModel.inspectorWindowID)
        } else {
            openWindow(id: AppModel.inspectorWindowID)
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

/// A compact card grouping one part of the project panel.
private struct PanelCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .qvCard(padding: 16, cornerRadius: 20)
    }
}
