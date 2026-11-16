import SwiftUI
import RealityKit
import simd

// v0.9 D1: ONE palm menu for Projects, Rendered and Server. Turn the left palm toward your face:
// the menu floats just above the palm, always in the same place, with the same look and the same
// order: Home/Exit · Viewpoints (Rendered) or Panel (Projects) · Speed. Each mode shows only
// what applies. Secondary content (viewpoint list, speed presets) expands inside the menu, so
// nothing depends on popovers inside a RealityView attachment.

/// Attachment entity + timing of the palm menu, read by the per-frame update of each space.
final class PalmMenuState {
    var menu: Entity?
    var clock: Float = 0
    var lastPalmSeen: Float = 0
}

enum PalmMenuPlacement {
    static let attachmentID = "qvPalmMenu"

    /// Off the palm, toward the face (m), and slightly up so the hand doesn't cover it.
    private static let lift: Float = 0.07
    private static let rise: Float = 0.04
    /// Stays tappable this long after the palm turns away (s): time to reach it with the other hand.
    private static let grace: Float = 0.8

    /// Call once when the attachment entity is available.
    @MainActor
    static func install(_ entity: Entity, in state: PalmMenuState) {
        entity.components.set(BillboardComponent())
        entity.isEnabled = false
        state.menu = entity
    }

    /// Call every frame. `suppressed`: hide it now (for example while flying with both fists).
    @MainActor
    static func update(state: PalmMenuState, hands: HandTrackingService, pose: simd_float4x4?,
                       deltaTime: Float, suppressed: Bool) {
        state.clock += deltaTime
        guard let menu = state.menu else { return }
        let left = hands.left
        if !suppressed, left.isTracked, left.palmFacingUser, !left.isFist, let pose {
            let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            var towardHead = head - left.palmCenter
            let length = simd_length(towardHead)
            towardHead = length > 0.001 ? towardHead / length : SIMD3<Float>(0, 1, 0)
            menu.setPosition(left.palmCenter + towardHead * lift + SIMD3<Float>(0, rise, 0), relativeTo: nil)
            if !menu.isEnabled { menu.isEnabled = true }
            state.lastPalmSeen = state.clock
        } else if menu.isEnabled, suppressed || state.clock - state.lastPalmSeen > grace {
            menu.isEnabled = false
        }
    }
}

/// The shared container: glass, rounded, fixed paddings. `primary` is the always-visible row,
/// `expanded` the optional section under it.
struct PalmMenuChrome<Primary: View, Expanded: View>: View {
    private let primary: Primary
    private let expanded: Expanded

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder expanded: () -> Expanded) {
        self.primary = primary()
        self.expanded = expanded()
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                primary
            }
            expanded
        }
        .buttonBorderShape(.capsule)
        .padding(12)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

/// One button of the primary row: icon + title, same size everywhere.
struct PalmMenuButton: View {
    let title: String
    let systemImage: String
    var isDestructive = false
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                .frame(minHeight: 44)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .tint(isDestructive ? Color.red : (isOn ? Color.accentColor : nil))
    }
}

/// The three speed presets (Walk 1× · Fast 3× · Fly 10×), shared by every mode (D3).
struct SpeedPresetRow: View {
    let speed: Float
    let onSelect: (Float) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<FlyController.speedPresets.count, id: \.self) { index in
                let preset = FlyController.speedPresets[index]
                let isCurrent = abs(speed - preset.value) < 0.01
                Button {
                    onSelect(preset.value)
                } label: {
                    VStack(spacing: 2) {
                        Label(preset.name, systemImage: preset.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(DisplayFormat.multiplier(preset.value))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .tint(isCurrent ? Color.accentColor : nil)
                .accessibilityLabel("\(preset.name) speed, \(DisplayFormat.multiplier(preset.value))")
            }
        }
    }
}
