import SwiftUI

/// Home › All Projects: branded header, "you are here" breadcrumb, project cards, empty state.
struct ProjectsHomeView: View {
    @Environment(AppModel.self) private var model

    @State private var isCreating = false
    @State private var newProjectName = ""

    @State private var isRenaming = false
    @State private var renameTargetID: UUID?
    @State private var renameText = ""

    @State private var isConfirmingDelete = false
    @State private var deleteTarget: Project?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 20)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader {
                Button {
                    startCreating()
                } label: {
                    Label("New Project", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isTransitioning)
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)

            HStack(spacing: 12) {
                Breadcrumb(components: ["Home", "All Projects"])
                Spacer(minLength: 8)
                if !model.projects.isEmpty {
                    InfoPill(text: projectCountText)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .padding(.bottom, 16)

            ContinueCard()
                .padding(.horizontal, 36)
                .padding(.bottom, 20)

            if model.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(model.projects) { project in
                            projectCard(project)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("New Project", isPresented: $isCreating) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                createAndOpen()
            }
        } message: {
            Text("Give your project a name.")
        }
        .alert("Rename Project", isPresented: $isRenaming) {
            TextField("Project name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let id = renameTargetID {
                    model.renameProject(id, to: renameText)
                }
                renameTargetID = nil
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { project in
            Button("Delete", role: .destructive) {
                model.deleteProject(project.id)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { _ in
            Text("The project and its imported models will be removed from this device. This can't be undone.")
        }
    }

    private var projectCountText: String {
        model.projects.count == 1 ? "1 project" : "\(model.projects.count) projects"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            BrandMark(size: 96)
            VStack(spacing: 8) {
                Text("Create your first project")
                    .font(.title.weight(.semibold))
                Text("A project holds your models, their layers and where you placed them. Open it to see everything at real size, in your room or fully immersive.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button {
                startCreating()
            } label: {
                Label("New Project", systemImage: "plus")
                    .primaryActionLabel(expands: false)
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                ForEach(["USDZ", "USD", "Reality", "OBJ"], id: \.self) { format in
                    InfoPill(text: format)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Supported formats: USDZ, USD, Reality, OBJ")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 36)
        .padding(.bottom, 36)
    }

    // MARK: - Cards

    private func projectCard(_ project: Project) -> some View {
        let isOpening = model.openingProjectID == project.id

        return ZStack(alignment: .topTrailing) {
            Button {
                model.requestOpenProject(project.id)
            } label: {
                ProjectCardContent(project: project, isOpening: isOpening)
            }
            .buttonStyle(.plain)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 28, style: .continuous))
            .hoverEffect()
            .disabled(model.isTransitioning)
            .accessibilityLabel("Open \(project.name)")
            .contextMenu {
                cardActions(project)
            }

            Menu {
                cardActions(project)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonBorderShape(.circle)
            .padding(20)
            .accessibilityLabel("Actions for \(project.name)")
        }
    }

    @ViewBuilder
    private func cardActions(_ project: Project) -> some View {
        Button {
            renameTargetID = project.id
            renameText = project.name
            isRenaming = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            model.duplicateProject(project.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        Button(role: .destructive) {
            deleteTarget = project
            isConfirmingDelete = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var deleteDialogTitle: String {
        if let name = deleteTarget?.name {
            return "Delete “\(name)”?"
        }
        return "Delete project?"
    }

    private func startCreating() {
        newProjectName = "Project \(model.projects.count + 1)"
        isCreating = true
    }

    private func createAndOpen() {
        let project = model.createProject(named: newProjectName)
        model.requestOpenProject(project.id)
    }
}

/// Visual content of one project card: monogram tile, name, date, counts.
private struct ProjectCardContent: View {
    let project: Project
    let isOpening: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProjectMonogram(project: project, height: 118)
                .overlay(alignment: .bottomLeading) {
                    Label(project.viewMode.title, systemImage: project.viewMode.systemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.25), in: Capsule())
                        .padding(10)
                }
                .overlay {
                    if isOpening {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.black.opacity(0.35))
                            ProgressView()
                                .controlSize(.large)
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                Text(isOpening ? "Opening…" : "Edited \(Self.relativeFormatter.localizedString(for: project.modifiedAt, relativeTo: Date()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 14) {
                Label(objectCountText, systemImage: "cube")
                Label(layerCountText, systemImage: "square.3.layers.3d")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var objectCountText: String {
        let count = project.items.count
        return count == 1 ? "1 object" : "\(count) objects"
    }

    private var layerCountText: String {
        let count = project.layers.count
        return count == 1 ? "1 layer" : "\(count) layers"
    }
}
