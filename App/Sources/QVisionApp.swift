import SwiftUI
import RealityKit
import CloudXRKit

@main
struct QVisionApp: App {
    @State private var model = AppModel()
    /// Server mode: NVIDIA CloudXR streaming (Unreal on a PC / the office server).
    @State private var server = ServerSessionController()
    /// Rendered mode (v0.8): baked scenes on this Vision Pro + the QVision Library on the PC.
    @State private var library = RenderedLibrary()

    init() {
        StageComponents.register()
        CloudXRKit.registerSystems()
    }

    // `SwiftUI.` prefix: RealityKit also has a type named `Scene`.
    var body: some SwiftUI.Scene {
        // Home (All Projects + Server). Closed while a project is open and the panel window is
        // in use; the only window that may be restored at launch.
        WindowGroup(id: AppModel.mainWindowID) {
            RootView()
                .environment(model)
                .environment(server)
                .environment(library)
        }
        .defaultSize(width: 760, height: 820)

        // Project panel: a real window (system move bar underneath), opened/closed from the
        // palm button. Placed as a utility panel: close to the user, slightly below eye level.
        // Never restored: it only makes sense with an open project (L6).
        WindowGroup(id: AppModel.panelWindowID) {
            ProjectPanelWindowView()
                .environment(model)
        }
        .defaultSize(width: 520, height: 780)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }
        // Note: .restorationBehavior(.disabled) needs visionOS 26; on 2.x restored windows
        // without a project close themselves and reopen Home (see ProjectPanelWindowView / RootView).

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
                .installsSceneActions()
                .onAppear { model.stageDidAppear() }
                .onDisappear { model.stageDidDisappear() }
                .environment(model)
        }
        .immersionStyle(selection: immersionBinding, in: .mixed, .full)

        // Server mode: the CloudXR stream (full immersion by default; "show my room" = mixed).
        ImmersiveSpace(id: ServerSessionController.streamSpaceID) {
            StreamImmersiveView()
                .environment(server)
                .environment(model)
        }
        .immersionStyle(selection: streamImmersionBinding, in: .mixed, .full)

        // Rendered mode (v0.8 R4): one baked, unlit scene at real scale, full immersion.
        ImmersiveSpace(id: AppModel.renderedSpaceID) {
            RenderedImmersiveView()
                .environment(model)
                .environment(library)
        }
        .immersionStyle(selection: .constant(FullImmersionStyle.full as any ImmersionStyle), in: .full)
    }

    private var streamImmersionBinding: Binding<any ImmersionStyle> {
        Binding(
            get: {
                server.showRoom
                    ? (MixedImmersionStyle.mixed as any ImmersionStyle)
                    : (FullImmersionStyle.full as any ImmersionStyle)
            },
            set: { newValue in
                server.showRoom = !(newValue is FullImmersionStyle)
            }
        )
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
