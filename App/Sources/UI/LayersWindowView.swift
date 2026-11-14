import SwiftUI

/// Root of the movable Layers window (`WindowGroup(id: AppModel.layersWindowID)`),
/// opened / closed from the project panel's footer.
struct LayersWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let project = model.currentProject {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Breadcrumb(components: ["Home", project.name, "Layers"])
                            LayersPanelView(compact: false)
                        }
                        .padding(20)
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            UndoRedoButtons()
                        }
                    }
                } else {
                    NoProjectView(windowID: AppModel.layersWindowID, systemImage: "square.3.layers.3d")
                }
            }
            .navigationTitle("Layers")
        }
        .installsSceneActions()
        .onAppear {
            model.isLayersWindowOpen = true
        }
        .onDisappear {
            model.isLayersWindowOpen = false
        }
    }
}

/// Undo / Redo for secondary windows (layer ops, part visibility).
struct UndoRedoButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ToolbarIconButton(title: "Undo", systemImage: "arrow.uturn.backward") {
            model.undo()
        }
        .disabled(!model.canUndo)

        ToolbarIconButton(title: "Redo", systemImage: "arrow.uturn.forward") {
            model.redo()
        }
        .disabled(!model.canRedo)
    }
}

/// Shown by the panel / Layers / Inspector windows when no project is open (for example a
/// window the system brought back on launch). L6: it closes itself and opens Home after a
/// moment, unless a project flow is running; the button does the same right away.
struct NoProjectView: View {
    let windowID: String
    let systemImage: String

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 20) {
            BrandMark(size: 56)
            ContentUnavailableView(
                "No project is open",
                systemImage: systemImage,
                description: Text("Projects open from Home.")
            )
            Button {
                goHome()
            } label: {
                Label("Go to Home", systemImage: "house")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled,
                  model.currentProject == nil,
                  !model.isTransitioning else { return }
            goHome()
        }
    }

    private func goHome() {
        if !model.isMainWindowOpen {
            openWindow(id: AppModel.mainWindowID)
        }
        if windowID == AppModel.panelWindowID {
            model.notePanelHideRequested()
        }
        dismissWindow(id: windowID)
    }
}
