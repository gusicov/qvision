import SwiftUI

/// A compact optional panel for the existing project window. The host owns the selection
/// binding so model taps, search results and the 3D view share the same article and part.
@available(visionOS 2.0, *)
@MainActor
struct ArchViewerArticlePanel: View {
    let viewer: ArchViewerQuantities
    @Binding var selection: AVQSelection?
    var visibility = AVQVisibility()
    var useBatchedContext = false
    /// QVision: the host owns the building opacity (its slider sits in the window header and
    /// calls `setContextOpacity` itself); the panel applies it before each `show`.
    var opacity = 0.20
    @State private var search = ""
    @State private var zone = ""
    @State private var partNumber = ""
    @State private var scopeParts: [AVQPart] = []
    @State private var currentRequest = UUID()
    @State private var loading = false
    @State private var issue: String?
    @State private var thinTrimLocators = 0
    @State private var levels: [String] = []

    private struct Request: Equatable {
        let selection: AVQSelection?
        let visibility: AVQVisibility
        let batched: Bool
    }
    private var request: Request { .init(selection: selection, visibility: visibility, batched: useBatchedContext) }
    private var article: AVQArticle? { viewer.package.articles.first { $0.articleId == selection?.articleId } }
    private var unfilteredLabel: String {
        viewer.package.articles.first?.sourceBuilding == nil ? "All zones" : "All buildings"
    }
    private func listPosition(_ item: AVQArticle) -> String {
        if let page = item.page, let position = item.position { return "\(page)/\(position)" }
        return String(item.row)
    }
    private var available: [AVQArticle] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewer.package.articles.filter { item in
            (zone.isEmpty || zone == item.zone) && (q.isEmpty ||
                [item.title, item.zone, item.code ?? "", item.sourceBuilding ?? "", item.reference, String(item.row)].contains { value in
                    value.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                })
        }
    }
    private var selectedIndex: Int? {
        guard let id = selection?.partId else { return nil }
        return scopeParts.firstIndex { $0.partId == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search article, code or source row", text: $search)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button(unfilteredLabel) { zone = "" }
                    ForEach(Set(viewer.package.articles.map(\.zone)).sorted(), id: \.self) { item in
                        Button(item) { zone = item }
                    }
                } label: { Text(zone.isEmpty ? unfilteredLabel : zone).lineLimit(1) }
                Button("Normal view") { selection = nil }
                    .disabled(selection == nil)
            }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(available) { item in
                            Button {
                                selection = .init(articleId: item.articleId)
                            } label: {
                                HStack(spacing: 8) {
                                    Text([item.sourceBuilding, item.code].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption.monospacedDigit()).frame(minWidth: 49, alignment: .leading)
                                    Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(listPosition(item)).font(.caption.monospacedDigit())
                                    Text(item.displayQuantity.map { $0 + " " + item.displayUnit } ?? "—")
                                        .font(.caption.monospacedDigit()).frame(minWidth: 78, alignment: .trailing)
                                }
                                .padding(.vertical, 7).padding(.horizontal, 6)
                                .background(item.articleId == selection?.articleId ? Color.accentColor.opacity(0.24) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minWidth: 325, maxWidth: .infinity)
                Divider()
                ScrollView {
                    if let article { detail(article) }
                    else { Text("Select an article").foregroundStyle(.secondary) }
                }
                .frame(minWidth: 265, maxWidth: 380, alignment: .leading)
            }
        }
        .padding()
        .task(id: request) { await refresh(request) }
        .onDisappear { viewer.normalView() }
    }

    @ViewBuilder private func detail(_ a: AVQArticle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(a.title).font(.headline).textSelection(.enabled)
            Text(a.reference.hasPrefix(a.zone) ? a.reference : a.zone + " · " + a.reference).font(.caption).foregroundStyle(.secondary)
            if let display = a.displayQuantity {
                Text(display + " " + a.displayUnit).font(.title2.monospacedDigit())
            } else { Text(a.sourceStatus == "excluded_from_architecture" ? "Outside architectural scope" : "No published quantity").font(.title3) }
            Text("Workbook unit · " + a.sourceUnit).font(.caption).foregroundStyle(.secondary)
            Text(a.status).font(.caption)
            if levels.count > 1 {
                Menu {
                    Button("All levels") { selection?.partId = nil; selection?.level = nil }
                    ForEach(levels, id: \.self) { level in
                        Button(level) { selection?.partId = nil; selection?.level = level }
                    }
                } label: { Text(selection?.level ?? "All levels") }
            }
            if let link = a.sharedWithArticleId,
               let linked = viewer.package.articles.first(where: { $0.articleId == link }) {
                Button("Shared with " + linked.reference) { selection = .init(articleId: link) }
            }
            if !a.reviews.isEmpty {
                Menu {
                    Button("Article geometry") { selection = .init(articleId: a.id) }
                    ForEach(a.reviews) { review in
                        Button(review.label + " · " + review.displayQuantity + " " + review.unit) {
                            selection = .init(articleId: a.id, reviewId: review.id)
                        }
                    }
                } label: { Text(a.reviews.first { $0.id == selection?.reviewId }?.label ?? "Article geometry") }
                if let review = a.reviews.first(where: { $0.id == selection?.reviewId }) {
                    Text("Review · " + review.displayQuantity + " " + review.unit).font(.subheadline.monospacedDigit())
                }
            }
            if !scopeParts.isEmpty {
                Divider()
                Text(selectedIndex.map { "Element \($0 + 1) of \(scopeParts.count)" } ?? "All \(scopeParts.count) visible elements")
                    .font(.caption.monospacedDigit())
                HStack {
                    Button("All") { selection?.partId = nil }
                    Button { choose((selectedIndex ?? scopeParts.count) - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(selectedIndex == 0)
                        .accessibilityLabel("Previous part")
                    Button { choose((selectedIndex ?? -1) + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(selectedIndex == scopeParts.count - 1)
                        .accessibilityLabel("Next part")
                }
                HStack {
                    TextField("Part number", text: $partNumber).textFieldStyle(.roundedBorder)
                        .onSubmit { jump() }
                    Button("Go") { jump() }
                        .disabled(!(Int(partNumber).map { (1...scopeParts.count).contains($0) } ?? false))
                }
                if let index = selectedIndex {
                    let part = scopeParts[index]
                    Text(part.nativeSelection).font(.caption).textSelection(.enabled)
                    Text([part.section, part.level, part.facade, part.evidence].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let amount = part.basis {
                        Text("Registered element basis · " + amount.formatted(.number.precision(.fractionLength(0...5))) + " " + (part.basisUnit ?? ""))
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("The register gives this location without an individual quantity.").font(.caption)
                    }
                    if part.role == "geometricSupport" || part.role == "areaEvidenceOnly" {
                        Text("Supporting geometry").font(.caption)
                    }
                }
            }
            if loading { ProgressView("Preparing preview") }
            if thinTrimLocators > 0 { Text("The marker locates a trim below display precision.").font(.caption).foregroundStyle(.secondary) }
            if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
            if !a.measurementNote.isEmpty { Text(a.measurementNote).font(.caption).textSelection(.enabled) }
            if !a.workbookRule.isEmpty && a.workbookRule != a.measurementNote {
                DisclosureGroup("Source notes") { Text(a.workbookRule).font(.caption).textSelection(.enabled) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choose(_ index: Int) {
        guard scopeParts.indices.contains(index) else { return }
        selection?.partId = scopeParts[index].partId
    }
    private func jump() {
        guard let n = Int(partNumber), n > 0 else { return }
        choose(n - 1)
    }
    private func refresh(_ request: Request) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        currentRequest = token
        issue = nil
        thinTrimLocators = 0
        partNumber = ""
        scopeParts = []
        levels = []
        guard let s = request.selection else { viewer.normalView(); loading = false; return }
        loading = true
        defer { if currentRequest == token { loading = false } }
        do {
            var full = s
            full.partId = nil
            var everyLevel = full
            everyLevel.level = nil
            let eligible = try viewer.package.displayParts(for: everyLevel, using: request.visibility)
            levels = Set(eligible.map(\.level).filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            scopeParts = eligible.filter { full.level == nil || $0.level == full.level }
            viewer.setContextOpacity(Float(opacity))
            try await viewer.show(s, visibility: request.visibility, useBatchedContext: request.batched)
            if currentRequest == token { thinTrimLocators = viewer.thinTrimLocatorCount }
        } catch is CancellationError {
            return
        } catch {
            if currentRequest == token { issue = error.localizedDescription }
        }
    }
}
