import SwiftUI

/// Home › Settings (v0.9 F): version, days left on the 7-day signing, storage with
/// "Free up space", comfort and speed defaults, and a short how-to.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library

    @State private var projectsBytes: Int64?
    @State private var freeBytes: Int64?
    @State private var expiration: Date?
    @State private var isConfirmingDeleteScenes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader()
                .padding(.horizontal, 36)
                .padding(.top, 30)

            HStack(spacing: 12) {
                Breadcrumb(components: ["Home", "Settings"])
                Spacer(minLength: 8)
                InfoPill(text: "Version \(SettingsInfo.versionText)")
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    aboutSection
                    storageSection
                    comfortSection
                    howToSection
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            expiration = SettingsInfo.signingExpiration()
            await measureStorage()
        }
        .confirmationDialog(
            "Delete all rendered scenes?",
            isPresented: $isConfirmingDeleteScenes,
            titleVisibility: .visible
        ) {
            Button("Delete \(RenderedFiles.byteText(library.totalBytes))", role: .destructive) {
                library.deleteAllScenes(except: model.currentRenderedScene?.id)
                Task { await measureStorage() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The scenes stay on your PC: you can download them again from Home › Rendered.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("About", systemImage: "info.circle")
            VStack(alignment: .leading, spacing: 14) {
                row("Version", SettingsInfo.versionText)
                if let expiration {
                    Divider()
                    signingRow(expiration)
                }
            }
            .qvCard()
        }
    }

    private func signingRow(_ expiration: Date) -> some View {
        let days = SettingsInfo.daysLeft(until: expiration)
        let color: Color = days <= 1 ? .red : (days <= 2 ? .orange : .green)
        let headline: String
        if days < 0 {
            headline = "The signing has expired"
        } else if days == 0 {
            headline = "Expires today"
        } else if days == 1 {
            headline = "Expires in 1 day"
        } else {
            headline = "Expires in \(days) days"
        }
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: days <= 2 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.headline)
                Text("Signed until \(Self.dateFormatter.string(from: expiration)). Re-install with iloader on the PC before then; your projects and scenes are kept.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Storage", systemImage: "internaldrive")
            VStack(alignment: .leading, spacing: 14) {
                row("Rendered scenes (\(library.scenes.count))", RenderedFiles.byteText(library.totalBytes))
                if library.partialBytes > 0 {
                    row("Interrupted downloads", RenderedFiles.byteText(library.partialBytes))
                }
                row("Projects (\(model.projects.count))", projectsBytes.map(RenderedFiles.byteText) ?? "…")
                if let freeBytes {
                    row("Free on this Vision Pro", RenderedFiles.byteText(freeBytes))
                }

                Divider()

                Text("Free up space")
                    .font(.headline)
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        isConfirmingDeleteScenes = true
                    } label: {
                        Label("Delete rendered scenes", systemImage: "trash")
                            .primaryActionLabel()
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.scenes.isEmpty || library.isDownloading)

                    if library.partialBytes > 0 {
                        Button {
                            library.clearPartialDownloads()
                            Task { await measureStorage() }
                        } label: {
                            Label("Clear interrupted downloads", systemImage: "xmark.bin")
                                .primaryActionLabel()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("Rendered scenes can be downloaded again from your PC. To remove a single scene or project, use its ••• menu on its card.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .qvCard()
        }
    }

    // MARK: - Comfort and speed

    private var comfortSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Comfort and speed", systemImage: "figure.walk.motion")
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: Binding(get: { model.comfortVignette }, set: { model.comfortVignette = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vignette while flying fast")
                            .font(.headline)
                        Text("Softly darkens the edge of your view at high speed or while turning. Easier on the stomach.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 60)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Fly speed in Rendered")
                            .font(.headline)
                        Spacer()
                        Text(DisplayFormat.multiplier(model.rendered.speed))
                            .font(.headline.monospacedDigit())
                    }
                    SpeedPresetRow(speed: model.rendered.speed) { model.rendered.speed = $0 }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Fly speed in Projects")
                            .font(.headline)
                        Spacer()
                        Text(DisplayFormat.multiplier(model.flySpeed))
                            .font(.headline.monospacedDigit())
                    }
                    SpeedPresetRow(speed: model.flySpeed) { model.flySpeed = $0 }
                }
                Text("Each mode remembers its own speed. You can also change it in the scene from the palm menu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .qvCard()
        }
    }

    // MARK: - How to

    private var howToSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("How to", systemImage: "hand.raised")
            VStack(alignment: .leading, spacing: 14) {
                howTo("hand.raised.fingers.spread", "Palm menu",
                      "Turn your left palm toward your face. The menu is the same everywhere: Home/Exit, then Viewpoints or Panel, then Speed.")
                howTo("airplane", "Fly",
                      "Clench both fists and move them where you want to go: farther is faster. Turn them like a steering wheel to rotate. Open a hand to stop.")
                howTo("mappin.and.ellipse", "Viewpoints",
                      "In a rendered scene, pick a viewpoint from the palm menu to jump there. Start is always first.")
                howTo("house", "Leaving",
                      "Home/Exit in the palm menu saves and returns here. Closing the last window ends the app cleanly.")
            }
            .qvCard()
        }
    }

    private func howTo(_ systemImage: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Brand.gradient)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func measureStorage() async {
        library.refresh()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let documents else { return }
        let projectsFolder = documents.appendingPathComponent("Projects", isDirectory: true)
        let measured = await Task.detached(priority: .utility) { () -> (Int64, Int64?) in
            (RenderedFiles.directorySize(projectsFolder), RenderedFiles.availableCapacity(at: documents))
        }.value
        projectsBytes = measured.0
        freeBytes = measured.1
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Facts read from the app bundle.
enum SettingsInfo {
    /// "0.9.0 (11)".
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// `ExpirationDate` of the provisioning profile the app was signed with (7 days with a free
    /// Apple ID). The profile is a CMS blob with a plain XML plist inside. nil if it can't be read
    /// (the line is then hidden).
    static func signingExpiration() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plist = object as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// Whole days from now until `date` (negative once expired).
    static func daysLeft(until date: Date) -> Int {
        let seconds = date.timeIntervalSinceNow
        return Int((seconds / 86_400).rounded(.down))
    }
}
