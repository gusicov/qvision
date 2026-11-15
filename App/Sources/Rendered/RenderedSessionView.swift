import SwiftUI

/// The main window while a rendered scene is open: Home › Rendered › <scene>. Shows loading
/// progress and errors, and the controls (Start position, Speed, Exit). Once the scene is shown
/// and hand tracking runs, RootView closes this window and the palm menu takes over; without
/// hand tracking this window stays as the control panel.
struct RenderedSessionView: View {
    @Environment(AppModel.self) private var model

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
                        controlsCard(viewer)
                    }
                    exitButton
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
                Label("You're standing at the start position", systemImage: "figure.stand")
                    .font(.headline)
                if let size = viewer.sceneSize {
                    Text("Scene size \(DisplayFormat.dimensions(size)) · real scale")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let shading = viewer.shadingSummary {
                    Text(shading)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Clench both fists and move them to fly; turn them like a steering wheel to rotate. Turn your left palm toward you for Exit, Start position and Speed.")
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
            VStack(alignment: .leading, spacing: 12) {
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
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
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

    private func controlsCard(_ viewer: RenderedViewer) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                viewer.resetToStart()
            } label: {
                Label("Back to start position", systemImage: "figure.stand")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Fly speed", systemImage: "hare")
                        .font(.headline)
                    Spacer()
                    Text(DisplayFormat.multiplier(viewer.speed))
                        .font(.headline.monospacedDigit())
                }
                Slider(value: speedBinding(viewer), in: 1...10, step: 1) {
                    Text("Fly speed")
                } minimumValueLabel: {
                    Text("1×")
                } maximumValueLabel: {
                    Text("10×")
                }
            }
        }
        .qvCard()
    }

    private var exitButton: some View {
        Button(role: .destructive) {
            model.requestLeaveRendered()
        } label: {
            Label("Exit scene", systemImage: "xmark.circle.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.extraLarge)
        .disabled(model.isTransitioning)
    }

    private func speedBinding(_ viewer: RenderedViewer) -> Binding<Double> {
        Binding(
            get: { Double(viewer.speed) },
            set: { viewer.speed = Float($0) }
        )
    }
}
