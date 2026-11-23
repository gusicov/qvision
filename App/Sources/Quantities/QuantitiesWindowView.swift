import SwiftUI

/// The quantities window (v0.11 Q2): project switcher, the always-visible "Building visibility"
/// slider, building / layer toggles, scale and placement, the tapped element's articles and the
/// article panel (`ArchViewerArticlePanel`) bound to the session's selection.
struct QuantitiesWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(QuantityLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if model.currentQuantities != nil {
                content
            } else {
                noProject
            }
        }
        .installsSceneActions()
        .onAppear {
            model.quantitiesWindowDidAppear()
            library.refresh()
        }
        .onDisappear { model.quantitiesWindowDidDisappear() }
    }

    // MARK: - Content

    private var content: some View {
        let session = model.quantities
        return VStack(alignment: .leading, spacing: 0) {
            header(session)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 14)
            Divider()
            switch session.phase {
            case .ready:
                if let viewer = session.viewer {
                    VStack(alignment: .leading, spacing: 0) {
                        if let tapped = session.tapped {
                            TappedElementCard(tapped: tapped, session: session)
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                        }
                        ArchViewerArticlePanel(
                            viewer: viewer,
                            selection: Binding(get: { session.selection }, set: { session.selection = $0 }),
                            visibility: session.visibility,
                            useBatchedContext: session.hasContext,
                            opacity: session.contextOpacity
                        )
                        // Each package gets a fresh panel (IDs are scoped by packageId).
                        .id(session.packageID ?? "")
                    }
                }
            case .loading(let text):
                statusView(systemImage: nil, title: text,
                           message: "Big projects take a while: the files are checked, then the model loads.")
            case .failed(let message):
                statusView(systemImage: "exclamationmark.triangle", title: "This project couldn't be opened",
                           message: message)
            case .idle:
                statusView(systemImage: nil, title: "Opening…", message: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ session: QuantitiesSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                BrandMark(size: 40)
                projectSwitcher(session)
                Spacer(minLength: 12)
                if let progress = session.pickingProgress, session.isReady {
                    InfoPill(text: "Preparing taps \(Int((progress * 100).rounded())) %", systemImage: "hand.tap")
                }
                Button {
                    model.requestLeaveQuantities()
                } label: {
                    Label("Exit", systemImage: "house")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(model.isTransitioning)
            }

            // Prominent and always visible (the user's own request).
            HStack(spacing: 16) {
                Label("Building visibility", systemImage: "building.2")
                    .font(.headline)
                    .lineLimit(1)
                Slider(value: Binding(get: { session.contextOpacity }, set: { session.contextOpacity = $0 }),
                       in: 0...1, step: 0.05)
                    .frame(minWidth: 220)
                    .accessibilityLabel("Building visibility")
                Text(session.contextOpacity.formatted(.percent.precision(.fractionLength(0))))
                    .font(.headline.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
                Toggle("Show whole building", isOn: Binding(get: { session.showsWholeBuilding },
                                                           set: { session.showsWholeBuilding = $0 }))
                    .toggleStyle(.button)
                    .disabled(session.selection == nil && session.lastSelection == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 12) {
                layerControls(session)
                Spacer(minLength: 8)
                Picker("Scale", selection: Binding(
                    get: { session.scalePreset },
                    set: { if let preset = $0 { session.setScalePreset(preset) } }
                )) {
                    ForEach(QuantitiesSession.ScalePreset.allCases) { preset in
                        Text(preset.title).tag(Optional(preset))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
                .disabled(!session.isReady)
                Button {
                    session.recentre()
                } label: {
                    Label("Recentre", systemImage: "scope")
                }
                .disabled(!session.isReady)
            }
            Text("Drag the model to turn it · drag the Move bar in front of it to move it · pinch with both hands to scale · tap an element to see its articles.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func projectSwitcher(_ session: QuantitiesSession) -> some View {
        Menu {
            ForEach(library.packages) { package in
                Button {
                    model.requestOpenQuantities(package)
                } label: {
                    if package.packageId == model.currentQuantities?.packageId {
                        Label(package.name, systemImage: "checkmark")
                    } else {
                        Text(package.name)
                    }
                }
                .disabled(library.downloads[package.packageId] != nil)
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quantities")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(model.currentQuantities?.name ?? session.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isTransitioning || library.packages.count < 2)
        .accessibilityLabel("Switch project")
    }

    @ViewBuilder
    private func layerControls(_ session: QuantitiesSession) -> some View {
        if session.togglesAreBuildings {
            HStack(spacing: 8) {
                ForEach(session.layerToggles) { toggle in
                    Toggle(toggle.name, isOn: Binding(
                        get: { !session.isLayerHidden(toggle.layerId) },
                        set: { session.setLayerHidden(toggle.layerId, !$0) }
                    ))
                    .toggleStyle(.button)
                    .lineLimit(1)
                }
            }
        } else if !session.layerToggles.isEmpty {
            Menu {
                Button("Show all layers") { session.showAllLayers() }
                Divider()
                ForEach(session.layerToggles) { toggle in
                    Toggle(toggle.name, isOn: Binding(
                        get: { !session.isLayerHidden(toggle.layerId) },
                        set: { session.setLayerHidden(toggle.layerId, !$0) }
                    ))
                }
            } label: {
                let hidden = session.visibility.hiddenLayerIds.count
                Label(hidden == 0 ? "Layers" : "Layers · \(hidden) hidden", systemImage: "square.3.layers.3d")
            }
        }
    }

    private func statusView(systemImage: String?, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No project (restored at launch)

    private var noProject: some View {
        VStack(spacing: 20) {
            BrandMark(size: 56)
            ContentUnavailableView("No project is open", systemImage: "ruler",
                                   description: Text("Quantities open from Home › Quantities."))
            Button {
                goHome()
            } label: {
                Label("Go to Home", systemImage: "house")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, model.currentQuantities == nil, !model.isTransitioning else { return }
            goHome()
        }
    }

    private func goHome() {
        if !model.isMainWindowOpen {
            openWindow(id: AppModel.mainWindowID)
        }
        model.noteQuantitiesWindowDismissRequested()
        dismissWindow(id: AppModel.quantitiesWindowID)
    }
}

/// The articles of the element tapped on the model. Choosing one selects it.
private struct TappedElementCard: View {
    let tapped: QuantitiesSession.Tapped
    let session: QuantitiesSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(tapped.elementId ?? "Tap", systemImage: "hand.tap")
                    .font(.headline)
                    .lineLimit(1)
                    .textSelection(.enabled)
                if !tapped.detail.isEmpty {
                    Text(tapped.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    session.dismissTapped()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
            }
            if let part = tapped.part {
                HStack(spacing: 10) {
                    Text("Part · " + [part.nativeSelection, part.level, part.facade].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .lineLimit(2)
                    if tapped.otherPartsHere > 0 {
                        Text("+\(tapped.otherPartsHere) more here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Select this part") { session.selectTappedPart() }
                        .disabled(session.selection == nil || session.selection?.partId == part.partId)
                }
            }
            if let message = tapped.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !tapped.articles.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(tapped.articles) { row in
                            Button {
                                session.choose(row)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(row.role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 110, alignment: .leading)
                                        .lineLimit(1)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.title).lineLimit(1)
                                        Text(row.reference)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(row.quantity)
                                        .font(.callout.monospacedDigit())
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background(isSelected(row) ? Color.accentColor.opacity(0.24) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func isSelected(_ row: QuantitiesSession.TappedArticle) -> Bool {
        session.selection?.articleId == row.articleId && session.selection?.reviewId == row.reviewId
    }
}
