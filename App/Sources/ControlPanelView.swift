import SwiftUI

struct ControlPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            List {
                stageSection
                librarySection
                onStageSection
            }
            .navigationTitle("QVision")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import model", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: AppModel.supportedTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.importFiles(urls) }
            }
            .alert("Problem", isPresented: errorBinding) {
                Button("OK") { model.lastError = nil }
            } message: {
                Text(model.lastError ?? "")
            }
            .overlay {
                if model.isLoading { ProgressView("Loading model…").padding().glassBackgroundEffect() }
            }
        }
    }

    // MARK: Sections

    private var stageSection: some View {
        Section("Stage") {
            Button {
                Task { await toggleStage() }
            } label: {
                Label(model.stageState == .open ? "Close stage" : "Open stage",
                      systemImage: model.stageState == .open ? "xmark.circle" : "cube.transparent")
            }
            .disabled(model.stageState == .transitioning)

            Toggle("Demo cube", isOn: Binding(
                get: { model.cubeVisible },
                set: { model.setCubeVisible($0) }))

            Toggle("Place at real-world scale (1:1)", isOn: Binding(
                get: { model.realWorldScale },
                set: { model.realWorldScale = $0 }))

            Button {
                model.resetScene()
            } label: {
                Label("Reset scene", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private var librarySection: some View {
        Section {
            if model.library.isEmpty {
                Text("No models yet. Tap Import and pick a .usdz / .reality file (e.g. from iCloud Drive).")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.library) { file in
                HStack {
                    VStack(alignment: .leading) {
                        Text(file.name)
                        Text(file.ext.uppercased()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Place") {
                        Task {
                            if model.stageState != .open { await toggleStage() }
                            await model.place(file)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .contextMenu {
                    Button("Delete file", role: .destructive) { model.deleteFromLibrary(file) }
                }
            }
        } header: {
            HStack {
                Text("Library")
                Spacer()
                Button("Refresh") { model.refreshLibrary() }.font(.caption)
            }
        }
    }

    private var onStageSection: some View {
        Section("On stage") {
            if model.placed.isEmpty {
                Text("Nothing placed yet.").foregroundStyle(.secondary)
            }
            ForEach(model.placed) { item in
                HStack {
                    Text(item.file.name)
                        .fontWeight(item.id == model.selectedID ? .bold : .regular)
                    Spacer()
                    Button(role: .destructive) {
                        model.removeFromStage(item.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            if !model.placed.isEmpty {
                Button("Clear stage", role: .destructive) { model.clearStage() }
            }
        }
    }

    // MARK: Helpers

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }

    private func toggleStage() async {
        switch model.stageState {
        case .open:
            model.stageState = .transitioning
            await dismissImmersiveSpace()
            model.stageState = .closed
        case .closed:
            model.stageState = .transitioning
            switch await openImmersiveSpace(id: AppModel.stageSpaceID) {
            case .opened: model.stageState = .open
            default: model.stageState = .closed
            }
        case .transitioning:
            break
        }
    }
}
