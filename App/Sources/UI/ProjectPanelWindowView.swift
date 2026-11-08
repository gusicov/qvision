import SwiftUI

/// Root of the project panel window: a real visionOS window, so it gets the system
/// move bar underneath (grab it to place the panel anywhere). Opened/closed by the
/// palm button; placed next to the user as a utility panel.
struct ProjectPanelWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.currentProject != nil {
                ProjectPanelView(context: .window)
            } else {
                NoProjectView(windowID: AppModel.panelWindowID, systemImage: "slider.horizontal.3")
            }
        }
        .onAppear { model.isProjectPanelVisible = true }
        .onDisappear { model.isProjectPanelVisible = false }
    }
}
