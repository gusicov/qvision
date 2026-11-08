import SwiftUI
import RealityKit

@main
struct QVisionApp: App {
    @State private var model = AppModel()

    init() {
        StageComponents.register()
    }

    // `SwiftUI.` prefix: RealityKit also has a type named `Scene`.
    var body: some SwiftUI.Scene {
        // All Projects. Closed while a project is open (the project panel lives on the left hand).
        WindowGroup(id: AppModel.mainWindowID) {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 640, height: 780)

        // Project panel: a real window (system move bar underneath), opened/closed from the
        // palm button. Placed as a utility panel: close to the user, slightly below eye level.
        WindowGroup(id: AppModel.panelWindowID) {
            ProjectPanelWindowView()
                .environment(model)
        }
        .defaultSize(width: 540, height: 820)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }

        // Movable Layers window (system window bar), opened from the panel.
        WindowGroup(id: AppModel.layersWindowID) {
            LayersWindowView()
                .environment(model)
        }
        .defaultSize(width: 440, height: 620)

        // Movable Inspector window, opened in Inspect mode.
        WindowGroup(id: AppModel.inspectorWindowID) {
            InspectorWindowView()
                .environment(model)
        }
        .defaultSize(width: 480, height: 680)

        // The stage. Mixed = your room, Full = generated environment only.
        ImmersiveSpace(id: AppModel.stageSpaceID) {
            StageView()
                .environment(model)
                .onAppear { model.stageState = .open }
                .onDisappear { model.stageState = .closed }
        }
        .immersionStyle(selection: immersionBinding, in: .mixed, .full)
    }

    private var immersionBinding: Binding<any ImmersionStyle> {
        Binding(
            get: {
                model.viewMode == .full
                    ? (FullImmersionStyle.full as any ImmersionStyle)
                    : (MixedImmersionStyle.mixed as any ImmersionStyle)
            },
            set: { newValue in
                model.viewMode = (newValue is FullImmersionStyle) ? .full : .mixed
            }
        )
    }
}
