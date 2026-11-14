import SwiftUI

/// Root of the main window.
///
/// - No project open: Home (Projects + Server tabs).
/// - Project open: the project panel in window form. As soon as the stage is open and hand
///   tracking runs, the panel window opens and the main window closes (once per project open).
///   If hand tracking never runs (denied / unsupported), the main window stays as the panel.
///
/// The stage ImmersiveSpace is opened / closed by AppModel's serialized app flow (open / leave);
/// RootView only presents the file picker for "Import models" (requested by the panel).
struct RootView: View {
    @Environment(AppModel.self) private var model
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

    var body: some View {
        ZStack {
            if model.currentProject == nil {
                TabView {
                    ProjectsHomeView()
                        .tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
                    ServerHomeView()
                        .tabItem { Label("Server", systemImage: "server.rack") }
                }
            } else {
                ProjectPanelView(context: .window)
            }

            // Project opening (the import progress shows inside the panel instead).
            if model.isLoading && model.importProgress == nil && model.currentProject != nil {
                loadingOverlay
            }
        }
        .installsSceneActions()
        .onAppear {
            model.mainWindowDidAppear()
        }
        .onDisappear {
            model.mainWindowDidDisappear()
        }
        .onChange(of: handoffTrigger, initial: true) { _, trigger in
            handOffToPanelWindowIfReady(trigger)
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
        }
        .padding(32)
        .glassBackgroundEffect()
    }
}
