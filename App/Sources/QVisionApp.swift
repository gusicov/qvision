import SwiftUI
import RealityKit

@main
struct QVisionApp: App {
    @State private var model = AppModel()

    init() {
        ManipulableComponent.registerComponent()
    }

    // `SwiftUI.` prefix: RealityKit also has a type named `Scene`.
    var body: some SwiftUI.Scene {
        // Main window: library + stage controls.
        WindowGroup(id: AppModel.panelWindowID) {
            ControlPanelView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 720)

        // The "stage": a mixed-reality immersive space where models live in your room.
        ImmersiveSpace(id: AppModel.stageSpaceID) {
            StageView()
                .environment(model)
                .onAppear { model.stageState = .open }
                .onDisappear { model.stageState = .closed }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
