import SwiftUI

/// Root of the project panel window: a real visionOS window, so it gets the system
/// move bar underneath (grab it to place the panel anywhere). Opened/closed by the
/// palm button; placed next to the user as a utility panel.
///
/// L6: closing this window while no other QVision window is open leaves the project (saved)
/// and closes the stage, so the app ends cleanly. Hiding it with the palm button doesn't.
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
        .installsSceneActions()
        .onAppear { model.panelWindowDidAppear() }
        .onDisappear { model.panelWindowDidDisappear() }
    }
}
