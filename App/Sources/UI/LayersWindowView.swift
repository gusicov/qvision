import SwiftUI

/// Root of the movable Layers window (`WindowGroup(id: AppModel.layersWindowID)`),
/// opened / closed from the project panel's footer.
struct LayersWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.currentProject != nil {
                    ScrollView {
                        LayersPanelView(compact: false)
                            .padding(20)
                    }
                } else {
                    NoProjectView(windowID: AppModel.layersWindowID, systemImage: "square.3.layers.3d")
                }
            }
            .navigationTitle("Layers")
        }
        .onAppear {
            model.isLayersWindowOpen = true
        }
        .onDisappear {
            model.isLayersWindowOpen = false
        }
    }
}

/// Shown by the Layers / Inspector windows when no project is open (for example when the
/// system restores one of them on launch). Offers the way back to All Projects.
struct NoProjectView: View {
    let windowID: String
    let systemImage: String

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Open a project first",
                systemImage: systemImage,
                description: Text("Choose a project in All Projects.")
            )
            Button {
                if !model.isMainWindowOpen {
                    openWindow(id: AppModel.mainWindowID)
                }
                dismissWindow(id: windowID)
            } label: {
                Label("Go to All Projects", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
