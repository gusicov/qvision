import SwiftUI

/// Switches between All Projects and the open project's workspace, and owns the
/// lifetime of the stage ImmersiveSpace (open while a project is open).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// True while a stage open/dismiss sequence is running (hides the "stage closed" banner).
    @State private var isSyncingStage = false

    var body: some View {
        ZStack {
            if model.currentProject == nil {
                ProjectsHomeView()
            } else {
                ProjectWorkspaceView()
            }

            if model.isLoading {
                loadingOverlay
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showsStageClosedBanner {
                stageClosedBanner
            }
        }
        .onChange(of: model.currentProject?.id) { _, _ in
            startStageSync()
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "")
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
            get: { model.lastError != nil },
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
