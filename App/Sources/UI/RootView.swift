import SwiftUI

/// Root of the main window.
///
/// - No project open: Home (Projects · Rendered · Server · Quantities · Settings tabs).
/// - Project open: the project panel in window form. As soon as the stage is open and hand
///   tracking runs, the panel window opens and the main window closes (once per project open).
///   If hand tracking never runs (denied / unsupported), the main window stays as the panel.
///
/// The stage ImmersiveSpace is opened / closed by AppModel's serialized app flow (open / leave);
/// RootView only presents the file picker for "Import models" (requested by the panel).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ServerSessionController.self) private var server
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var isPresentingImporter = false

    /// Everything the main-window → panel-window handoff depends on.
    private struct HandoffTrigger: Equatable {
        let projectID: UUID?
        let stageOpen: Bool
        let handsRunning: Bool
    }

    private var handoffTrigger: HandoffTrigger {
        HandoffTrigger(
            projectID: model.currentProject?.id,
            stageOpen: model.stageState == .open,
            handsRunning: model.hands.status == .running
        )
    }

    /// v0.8: rendered scene open + ready + hand tracking running -> the palm menu takes over.
    private struct RenderedHandoffTrigger: Equatable {
        let sceneID: String?
        let spaceOpen: Bool
        let ready: Bool
        let handsRunning: Bool
    }

    private var renderedHandoffTrigger: RenderedHandoffTrigger {
        RenderedHandoffTrigger(
            sceneID: model.currentRenderedScene?.id,
            spaceOpen: model.renderedState == .open,
            ready: model.rendered.isReady,
            handsRunning: model.hands.status == .running
        )
    }

    private var tabBinding: Binding<AppModel.HomeTab> {
        Binding(get: { model.homeTab }, set: { model.homeTab = $0 })
    }

    var body: some View {
        ZStack {
            if model.currentProject != nil {
                ProjectPanelView(context: .window)
            } else if model.currentRenderedScene != nil {
                RenderedSessionView()
            } else {
                TabView(selection: tabBinding) {
                    ProjectsHomeView()
                        .tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
                        .tag(AppModel.HomeTab.projects)
                    RenderedHomeView()
                        .tabItem { Label("Rendered", systemImage: "sparkles") }
                        .tag(AppModel.HomeTab.rendered)
                    ServerHomeView()
                        .tabItem { Label("Server", systemImage: "server.rack") }
                        .tag(AppModel.HomeTab.server)
                    QuantitiesHomeView()
                        .tabItem { Label("Quantities", systemImage: "ruler") }
                        .tag(AppModel.HomeTab.quantities)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppModel.HomeTab.settings)
                }
            }

            // Project opening (the import progress shows inside the panel instead).
            if model.isLoading && model.importProgress == nil && model.currentProject != nil {
                loadingOverlay
            }
        }
        .installsSceneActions()
        .onAppear {
            model.attach(server: server)
            model.mainWindowDidAppear()
        }
        .onDisappear {
            model.mainWindowDidDisappear()
        }
        .onChange(of: handoffTrigger, initial: true) { _, trigger in
            handOffToPanelWindowIfReady(trigger)
        }
        .onChange(of: renderedHandoffTrigger, initial: true) { _, trigger in
            handOffToRenderedSpaceIfReady(trigger)
        }
        .onChange(of: model.isImportPickerRequested, initial: true) { _, requested in
            guard requested else { return }
            model.isImportPickerRequested = false
            guard model.currentProject != nil else { return }
            Task { @MainActor in
                // Give a freshly opened window a moment to be on screen before presenting.
                try? await Task.sleep(nanoseconds: 300_000_000)
                isPresentingImporter = true
            }
        }
        .onChange(of: isPresentingImporter) { _, presenting in
            if !presenting {
                returnToPanelWindowAfterImport()
            }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
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
        // Inside a project, errors show inline in the project panel.
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Main window → panel window

    private func handOffToPanelWindowIfReady(_ trigger: HandoffTrigger) {
        guard let projectID = trigger.projectID,
              trigger.stageOpen,
              trigger.handsRunning,
              model.mainWindowHandedOffProjectID != projectID,
              !isPresentingImporter else { return }
        model.mainWindowHandedOffProjectID = projectID
        if !model.isProjectPanelVisible {
            openWindow(id: AppModel.panelWindowID)
        }
        model.noteMainWindowDismissRequested()
        dismissWindow(id: AppModel.mainWindowID)
    }

    /// Rendered mode: once the scene is shown and the palm menu works, close the main window
    /// (once per scene open), like the project handoff. Exit reopens it at Home › Rendered.
    private func handOffToRenderedSpaceIfReady(_ trigger: RenderedHandoffTrigger) {
        guard let sceneID = trigger.sceneID,
              trigger.spaceOpen, trigger.ready, trigger.handsRunning,
              model.currentProject == nil,
              model.renderedHandedOffSceneID != sceneID else { return }
        model.renderedHandedOffSceneID = sceneID
        Task { @MainActor in
            // Let the user see "ready" for a moment.
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard model.currentRenderedScene?.id == sceneID,
                  model.rendered.isReady,
                  model.hands.status == .running else { return }
            model.noteMainWindowDismissRequested()
            dismissWindow(id: AppModel.mainWindowID)
        }
    }

    /// The main window was (re)opened to present the file picker for the panel window. Once the
    /// picker is gone, close the window again if the panel window is usable.
    private func returnToPanelWindowAfterImport() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !isPresentingImporter,
                  model.currentProject != nil,
                  model.stageState == .open,
                  model.hands.status == .running else { return }
            model.mainWindowHandedOffProjectID = model.currentProject?.id
            if !model.isProjectPanelVisible {
                openWindow(id: AppModel.panelWindowID)
            }
            model.noteMainWindowDismissRequested()
            dismissWindow(id: AppModel.mainWindowID)
        }
    }

    // MARK: - Pieces

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil && model.currentProject == nil },
            set: { isPresented in
                if !isPresented { model.lastError = nil }
            }
        )
    }

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Opening \(model.currentProject?.name ?? "project")…")
                .font(.headline)
            // v0.9 B4: never a dead end, a big model can be abandoned.
            Button {
                model.requestLeave()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .primaryActionLabel(expands: false)
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .glassBackgroundEffect()
    }
}
