import SwiftUI

/// Home screen: "All Projects".
struct ProjectsHomeView: View {
    @Environment(AppModel.self) private var model

    @State private var isCreating = false
    @State private var newProjectName = ""

    @State private var isRenaming = false
    @State private var renameTargetID: UUID?
    @State private var renameText = ""

    @State private var isConfirmingDelete = false
    @State private var deleteTarget: Project?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 24)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 20)

            if model.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("All Projects")
                .font(.extraLargeTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 16)

            Button {
                newProjectName = "Project \(model.projects.count + 1)"
                isCreating = true
            } label: {
                Label("New Project", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack {
            Spacer()
            ContentUnavailableView {
                Label("No projects yet", systemImage: "square.stack.3d.up")
            } description: {
                Text("QVision places your 3D models (USDZ, USD, Reality, OBJ) in your room or in a fully immersive stage.")
            } actions: {
                Button("New Project") {
                    newProjectName = "Project 1"
                    isCreating = true
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
    }

    // MARK: - Cards

    private func projectCard(_ project: Project) -> some View {
        Button {
            Task { await model.openProject(project.id) }
        } label: {
            ProjectCardContent(project: project)
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 28, style: .continuous))
        .hoverEffect()
        .disabled(model.isLoading)
        .contextMenu {
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
    }

    private var deleteDialogTitle: String {
        if let name = deleteTarget?.name {
            return "Delete “\(name)”?"
        }
        return "Delete project?"
    }

    private func createAndOpen() {
        let project = model.createProject(named: newProjectName)
        Task { await model.openProject(project.id) }
    }
}

/// Visual content of one project card.
private struct ProjectCardContent: View {
    let project: Project

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.bottom, 6)

            Text(project.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text("Edited \(Self.relativeFormatter.localizedString(for: project.modifiedAt, relativeTo: Date()))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(objectCountText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var objectCountText: String {
        let count = project.items.count
        return count == 1 ? "1 object" : "\(count) objects"
    }
}
