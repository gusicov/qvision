import SwiftUI

/// The main window while a rendered scene is open: Home › Rendered › <scene>. Shows loading
/// progress (with Cancel) and errors (with Retry and Back to Home), then the controls:
/// Viewpoints, Speed, Exit. Once the scene is shown and hand tracking runs, RootView closes this
/// window and the palm menu takes over; without hand tracking this window stays as the panel.
struct RenderedSessionView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingDetails = false

    var body: some View {
        let viewer = model.rendered
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader()
                .padding(.horizontal, 36)
                .padding(.top, 30)

            HStack(spacing: 12) {
                Breadcrumb(components: ["Home", "Rendered", model.currentRenderedScene?.title ?? "Scene"],
                           onHome: { model.requestLeaveRendered() })
                Spacer(minLength: 8)
                phasePill(viewer.phase)
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusCard(viewer)
                    if viewer.isReady {
                        if viewer.isEnvironment {
                            roomsCard(viewer)
                        } else {
                            viewpointsCard(viewer)
                            speedCard(viewer)
                        }
                        detailsCard(viewer)
                    }
                    exitButton(viewer)
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func phasePill(_ phase: RenderedViewer.Phase) -> some View {
        switch phase {
        case .idle, .loading:
            InfoPill(text: "Loading", systemImage: "hourglass")
        case .ready:
            InfoPill(text: "Showing", systemImage: "sparkles", tint: .green)
        case .failed:
            InfoPill(text: "Failed", systemImage: "exclamationmark.triangle.fill", tint: .red)
        }
    }

    @ViewBuilder
    private func statusCard(_ viewer: RenderedViewer) -> some View {
        switch viewer.phase {
        case .idle:
            HStack(spacing: 16) {
                ProgressView()
                Text("Opening the rendered view…")
                    .font(.headline)
            }
            .qvCard()

        case .loading(let message, let fraction):
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text("Large scenes take a little while. Everything stays on this Vision Pro.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .qvCard()

        case .ready:
            VStack(alignment: .leading, spacing: 10) {
                Label(viewer.resumedLastPosition ? "You're back where you left off" : "You're in the scene",
                      systemImage: "figure.stand")
                    .font(.headline)
                if viewer.resumedLastPosition {
                    Button {
                        viewer.resetToStart()
                    } label: {
                        Label("Go to the start instead", systemImage: "arrow.uturn.backward")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                Text(viewer.isEnvironment
                     ? "Look around and take a few steps: this room is made to be seen from where you stand. Turn your left palm toward you for Exit and the other rooms."
                     : "Clench both fists and move them to fly; turn them like a steering wheel to rotate. Turn your left palm toward you for Exit, Viewpoints and Speed.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if model.hands.status != .running {
                    Text(handsHint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .qvCard()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                if let scene = model.currentRenderedScene {
                    Button {
                        viewer.begin(scene)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .primaryActionLabel()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .qvCard()
        }
    }

    private var handsHint: String {
        switch model.hands.status {
        case .denied:
            return "Hand tracking is off for QVision (Settings › Privacy & Security › Hand Structure & Movements), so use this window."
        case .unsupported:
            return "Hand tracking isn't available, so use this window."
        default:
            return "Waiting for hand tracking…"
        }
    }

    /// E3: the other rooms of the Environment's group.
    private func roomsCard(_ viewer: RenderedViewer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(viewer.environmentGroup ?? "Rooms", systemImage: "door.left.hand.open")
            RoomList()
        }
        .qvCard()
    }

    private func viewpointsCard(_ viewer: RenderedViewer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Viewpoints", systemImage: "mappin.and.ellipse")
            ViewpointList(viewer: viewer)
            if viewer.viewpoints.count <= 1 {
                Text("This scene has only its start position. Add a “viewpoints” list to the bake config to get named places here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .qvCard()
    }

    private func speedCard(_ viewer: RenderedViewer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Fly speed", systemImage: "hare") {
                Text(DisplayFormat.multiplier(viewer.speed))
                    .font(.headline.monospacedDigit())
            }
            SpeedPresetRow(speed: viewer.speed) { viewer.speed = $0 }
            Slider(value: speedBinding(viewer), in: 1...10, step: 1) {
                Text("Fly speed")
            } minimumValueLabel: {
                Text("1×")
            } maximumValueLabel: {
                Text("10×")
            }
        }
        .qvCard()
    }

    /// D5: scene facts, including the "HD shading: N · M baked" line.
    private func detailsCard(_ viewer: RenderedViewer) -> some View {
        DisclosureGroup(isExpanded: $isShowingDetails) {
            VStack(alignment: .leading, spacing: 8) {
                if let size = viewer.sceneSize {
                    detailRow("Size", "\(DisplayFormat.dimensions(size)) · real scale")
                }
                if let shading = viewer.shadingSummary {
                    detailRow("Shading", shading)
                }
                if let scene = model.currentRenderedScene {
                    detailRow("On this Vision Pro", RenderedFiles.byteText(scene.sizeBytes))
                }
                detailRow("Sky", viewer.hasOwnSky ? "From the scene" : "QVision daylight dome")
            }
            .padding(.top, 10)
        } label: {
            Label("Details", systemImage: "info.circle")
                .font(.headline)
        }
        .qvCard()
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    /// Always there: Cancel while loading, Back to Home after a failure, Exit otherwise (B4).
    private func exitButton(_ viewer: RenderedViewer) -> some View {
        let title: String
        switch viewer.phase {
        case .idle, .loading: title = "Cancel"
        case .failed: title = "Back to Home"
        case .ready: title = "Exit scene"
        }
        return Button(role: .destructive) {
            model.requestLeaveRendered()
        } label: {
            Label(title, systemImage: "house")
                .primaryActionLabel()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(model.isTransitioning)
    }

    private func speedBinding(_ viewer: RenderedViewer) -> Binding<Double> {
        Binding(
            get: { Double(viewer.speed) },
            set: { viewer.speed = Float($0) }
        )
    }
}
