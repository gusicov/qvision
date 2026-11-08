import SwiftUI

/// Root of the movable Inspector window (`WindowGroup(id: AppModel.inspectorWindowID)`).
/// Shows `model.inspection`: what the user tapped in Inspect mode, plus the model's part tree.
struct InspectorWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Inspector")
        }
        .onAppear {
            model.isInspectorWindowOpen = true
        }
        .onDisappear {
            model.isInspectorWindowOpen = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.currentProject == nil {
            NoProjectView(windowID: AppModel.inspectorWindowID, systemImage: "info.circle")
        } else if model.interactionMode != .inspect {
            VStack(spacing: 20) {
                ContentUnavailableView(
                    "Inspect mode is off",
                    systemImage: "info.circle",
                    description: Text("In Inspect mode nothing moves: tap a model to see its size, statistics and internal parts.")
                )
                Button {
                    model.interactionMode = .inspect
                } label: {
                    Label("Switch to Inspect", systemImage: "info.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let info = model.inspection {
            InspectionList(info: info)
        } else {
            ContentUnavailableView(
                "Tap a model to inspect it",
                systemImage: "hand.tap",
                description: Text("Tap any part of a model on the stage. Its details and its part tree appear here.")
            )
        }
    }
}

// MARK: - Inspection content

private struct InspectionList: View {
    let info: InspectionInfo

    @Environment(AppModel.self) private var model

    /// A model can have thousands of parts; the List is lazy, and we cap it anyway.
    private static let maxParts = 2000

    var body: some View {
        let selectedPartID = model.selectedPartID
        let selectedPart = selectedPartID.flatMap { id in info.parts.first { $0.id == id } }
        let shownParts = info.parts.prefix(Self.maxParts)
        let hiddenCount = max(0, info.parts.count - Self.maxParts)

        ScrollViewReader { proxy in
            List {
                Section {
                    summaryCard
                }

                Section("Statistics") {
                    LabeledContent("Triangles", value: DisplayFormat.count(info.triangleCount))
                    LabeledContent("Vertices", value: DisplayFormat.count(info.vertexCount))
                    LabeledContent("Meshes", value: "\(info.meshCount)")
                    LabeledContent("Materials", value: "\(info.materialCount)")
                    LabeledContent("Animations", value: "\(info.animationCount)")
                }

                if let part = selectedPart {
                    Section("Selected part") {
                        LabeledContent("Name", value: part.name.isEmpty ? "(unnamed)" : part.name)
                        Text(part.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        LabeledContent("Size (W × D × H)", value: DisplayFormat.dimensions(part.size))
                        LabeledContent("Triangles", value: DisplayFormat.count(part.triangleCount))
                        LabeledContent("Vertices", value: DisplayFormat.count(part.vertexCount))
                        LabeledContent("Materials", value: "\(part.materialCount)")
                    }
                }

                Section {
                    if info.parts.isEmpty {
                        Text("This model has no internal parts.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shownParts) { part in
                            PartRow(part: part, itemID: info.itemID, isSelected: part.id == selectedPartID)
                        }
                        if hiddenCount > 0 {
                            Text("+\(hiddenCount) more")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Parts (\(info.parts.count))")
                }
            }
            .onChange(of: selectedPartID) { _, newID in
                guard let newID = newID else { return }
                withAnimation {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var summaryCard: some View {
        let percent = model.sceneScalePercent

        return VStack(alignment: .leading, spacing: 8) {
            Text(info.itemName)
                .font(.title2.weight(.semibold))
                .lineLimit(2)

            Text(fileLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(DisplayFormat.dimensions(info.size))
                .font(.title3.monospacedDigit())
                .padding(.top, 4)
            Text("Real size, width × depth × height")
                .font(.caption)
                .foregroundStyle(.secondary)

            if percent < 100 {
                let scaled = info.size * Float(percent / 100)
                Text("At 1:\(DisplayFormat.scaleDenominator(percent: percent)): \(DisplayFormat.dimensions(scaled))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var fileLine: String {
        var parts: [String] = []
        if let file = info.fileName {
            parts.append(file)
        } else {
            parts.append("Built-in primitive")
        }
        if let bytes = info.fileSizeBytes {
            parts.append("\(DisplayFormat.megabytes(bytes)) MB")
        }
        return parts.joined(separator: " · ")
    }
}

/// One node of the part tree, indented by depth.
private struct PartRow: View {
    let part: PartInfo
    let itemID: UUID
    let isSelected: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.selectPart(itemID: itemID, partID: isSelected ? nil : part.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: part.isMesh ? "cube.fill" : "folder")
                        .foregroundStyle(part.isMesh ? Color.accentColor : Color.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.name.isEmpty ? "(unnamed)" : part.name)
                            .lineLimit(1)
                        Text("\(DisplayFormat.count(part.triangleCount)) tris · \(DisplayFormat.dimensions(part.size))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.leading, CGFloat(min(part.depth, 12)) * 14)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(part.isHidden ? 0.45 : 1)

            Button {
                model.setPartHidden(itemID: itemID, partID: part.id, hidden: !part.isHidden)
            } label: {
                Image(systemName: part.isHidden ? "eye.slash" : "eye")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .accessibilityLabel(part.isHidden ? "Show part" : "Hide part")
        }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.3) : nil)
    }
}
