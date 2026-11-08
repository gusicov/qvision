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
        // The single main panel: All Projects -> project workspace.
        WindowGroup(id: AppModel.mainWindowID) {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 640, height: 780)

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
