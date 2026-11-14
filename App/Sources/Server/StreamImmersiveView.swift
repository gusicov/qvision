// This software contains source code provided by NVIDIA Corporation.
// Adapted from NVIDIA's CloudXR generic viewer sample (MIT):
// github.com/NVIDIA/cloudxr-apple-generic-viewer (visionOS/ImmersiveView.swift, ViewerApp).

import SwiftUI
import RealityKit
import UIKit
import CloudXRKit

/// Content of `ImmersiveSpace(id: ServerSessionController.streamSpaceID)`: the CloudXR stream.
///
/// - The session entity carries `CloudXRSessionComponent`; CloudXRKit's systems
///   (`CloudXRKit.registerSystems()`, done in QVisionApp) render the remote frames.
/// - An invisible "gesture wall" 20 m ahead catches taps so the triple-tap escape hatch works.
/// - Never leaves the user in a black space: if the stream ends while this space is still open,
///   the main window comes back and the space dismisses itself (ServerHomeView normally does it
///   first; this is the fallback when the Server tab isn't on screen).
struct StreamImmersiveView: View {
    @Environment(ServerSessionController.self) private var server
    /// Optional: only available if the orchestrator also injects AppModel into this space.
    @Environment(AppModel.self) private var appModel: AppModel?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase

    @State private var sessionEntity = Entity()

    var body: some View {
        RealityView { content in
            sessionEntity.name = "CloudXRSession"
            if let session = server.streamSession {
                sessionEntity.components[CloudXRSessionComponent.self] = .init(session: session)
            }
            content.add(sessionEntity)
            content.add(Self.makeInvisibleGestureWall())
        } update: { _ in
            // Reading `phase` re-runs this on every phase change: attach the session if the
            // space opened before it existed (it normally exists already).
            _ = server.phase
            if !sessionEntity.components.has(CloudXRSessionComponent.self),
               let session = server.streamSession {
                sessionEntity.components[CloudXRSessionComponent.self] = .init(session: session)
            }
        }
        .onTapGesture(count: 3) {
            // Escape hatch (as in the sample): bring the main window back.
            openMainWindowIfClosed()
        }
        .onAppear {
            server.isStreamSpaceOpen = true
            if !server.wantsStreamSpace {
                // Opened (or restored) with no stream to show: don't sit in a black space.
                scheduleFallbackDismiss()
            }
        }
        .onDisappear {
            server.isStreamSpaceOpen = false
            if server.wantsStreamSpace {
                // The user (or the system) closed the space while streaming: end the stream and
                // bring the window back so they can reconnect.
                server.disconnect()
                Task { @MainActor in
                    openMainWindowIfClosed()
                }
            }
        }
        .onChange(of: server.wantsStreamSpace) { _, wants in
            guard !wants else { return }
            // Stream ended / failed: make sure the window with the status is visible.
            openMainWindowIfClosed()
            scheduleFallbackDismiss()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Headset off / app in background: pause; back: resume (sample's iOS branch).
            switch newPhase {
            case .background:
                server.pauseForBackground()
            case .active:
                server.resumeIfPaused()
            default:
                break
            }
        }
    }

    /// ServerHomeView dismisses the space when the stream ends; if it didn't (Server tab not on
    /// screen, main window closed), do it here after a short grace period.
    private func scheduleFallbackDismiss() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !server.wantsStreamSpace, server.isStreamSpaceOpen else { return }
            await dismissImmersiveSpace()
            server.isStreamSpaceOpen = false
        }
    }

    private func openMainWindowIfClosed() {
        if let appModel {
            if !appModel.isMainWindowOpen {
                openWindow(id: AppModel.mainWindowID)
            }
            return
        }
        // Without AppModel here: in Server mode the main window is the only regular window, so
        // "no foreground window scene" means it's closed.
        let hasVisibleWindow = UIApplication.shared.connectedScenes.contains { scene in
            scene.session.role == .windowApplication
                && (scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive)
        }
        if !hasVisibleWindow {
            openWindow(id: AppModel.mainWindowID)
        }
    }

    /// An invisible plane covering the view, 20 m away, that accepts gestures without getting in
    /// the way of UI (same as the sample).
    private static func makeInvisibleGestureWall() -> Entity {
        let plane = Entity()
        plane.name = "GestureWall"
        plane.components.set(InputTargetComponent())
        var collision = CollisionComponent(shapes: [.generateBox(width: 40, height: 40, depth: 0.01)])
        collision.mode = .trigger
        plane.components.set(collision)
        plane.position.z = -20
        return plane
    }
}
