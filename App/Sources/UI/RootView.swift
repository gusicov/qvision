import SwiftUI

/// Root of the main window.
///
/// - No project open: All Projects (ProjectsHomeView).
/// - Project open: the project panel in window form. As soon as the stage is open and hand
///   tracking runs, the main window closes (once per project open) and the panel lives on the
///   left hand. If hand tracking never runs (denied / unsupported), the window stays.
///
/// RootView also owns opening the stage ImmersiveSpace when a project opens, and presents the
/// file picker for "Import models" (requested by the project panel in either context).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    /// True while a stage open/dismiss sequence is running (hides the "stage closed" banner).
    @State private var isSyncingStage = false
    @State private var isPresentingImporter = false

    /// Everything the main-window → hand-panel handoff depends on.
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
                ProjectsHomeView()
            } else {
                ProjectPanelView(context: .window)
            }

            // Project opening (the import progress shows inside the panel instead).
            if model.isLoading && model.importProgress == nil {
                loadingOverlay
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showsStageClosedBanner {
                stageClosedBanner
            }
        }
        .onAppear {
            model.isMainWindowOpen = true
        }
        .onDisappear {
            model.isMainWindowOpen = false
        }
        .onChange(of: model.currentProject?.id) { _, _ in
            startStageSync()
        }
        .onChange(of: handoffTrigger, initial: true) { _, trigger in
            handOffToHandPanelIfReady(trigger)
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
                returnToHandPanelAfterImport()
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
        // Inside a project, errors show inline in the project panel (which also works on the hand).
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Main window → hand panel

    private func handOffToHandPanelIfReady(_ trigger: HandoffTrigger) {
        guard let projectID = trigger.projectID,
              trigger.stageOpen,
              trigger.handsRunning,
              model.mainWindowHandedOffProjectID != projectID,
              !isPresentingImporter else { return }
        model.mainWindowHandedOffProjectID = projectID
        dismissWindow(id: AppModel.mainWindowID)
    }

    /// The main window was (re)opened to present the file picker for the hand panel. Once the
    /// picker is gone, close the window again if the hand panel is usable.
    private func returnToHandPanelAfterImport() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !isPresentingImporter,
                  model.currentProject != nil,
                  model.stageState == .open,
                  model.hands.status == .running else { return }
            model.mainWindowHandedOffProjectID = model.currentProject?.id
            dismissWindow(id: AppModel.mainWindowID)
        }
    }

    // MARK: - Stage space lifetime

    private func startStageSync() {
        isSyncingStage = true
        Task { @MainActor in
            await syncStage()
            isSyncingStage = false
        }
    }

    /// Converges the ImmersiveSpace to "open iff a project is open". Loops so that a
    /// project opened/closed while a transition was in flight is still honoured.
    /// (Leave from the hand panel dismisses the space itself and marks `.transitioning`,
    /// so this does nothing in that case.)
    @MainActor
    private func syncStage() async {
        while true {
            let wantsStage = model.currentProject != nil
            switch (wantsStage, model.stageState) {
            case (true, .closed):
                model.stageState = .transitioning
                let result = await openImmersiveSpace(id: AppModel.stageSpaceID)
                switch result {
                case .opened:
                    model.stageState = .open
                default:
                    model.stageState = .closed
                    model.lastError = "The 3D stage couldn't be opened. Use “Open Stage” to try again."
                    return
                }

            case (false, .open):
                model.stageState = .transitioning
                await dismissImmersiveSpace()
                model.stageState = .closed

            default:
                // Already in the desired state, or another sync is mid-transition.
                return
            }
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

    private var showsStageClosedBanner: Bool {
        model.currentProject != nil && model.stageState == .closed && !isSyncingStage
    }

    private var stageClosedBanner: some View {
        HStack(spacing: 16) {
            Label("The 3D stage is closed.", systemImage: "cube.transparent")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Open Stage") {
                startStageSync()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Loading…")
                .font(.headline)
        }
        .padding(32)
        .glassBackgroundEffect()
    }
}
