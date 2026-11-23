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
    @State private var currentRequest = UUID()
    @State private var loading = false
    @State private var issue: String?

    private struct Request: Equatable {
        let selection: AVQSelection?
        let visibility: AVQVisibility
        let batched: Bool
    }
    private var request: Request { .init(selection: selection, visibility: visibility, batched: useBatchedContext) }
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
            // v0.11.2: the list takes the full width (the article detail column is gone); the
            // selected row stays highlighted and scrolls into view when a model tap chooses it.
            if loading || issue != nil {
                HStack(spacing: 8) {
                    if loading {
                        ProgressView().controlSize(.small)
                        Text("Preparing preview").font(.caption)
                    }
                    if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(available) { item in
                            row(item)
                                .id(item.articleId)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .onChange(of: selection?.articleId) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding()
        .task(id: request) { await refresh(request) }
        .onDisappear { viewer.normalView() }
    }

    private func row(_ item: AVQArticle) -> some View {
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

    private func refresh(_ request: Request) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        currentRequest = token
        issue = nil
        guard let s = request.selection else { viewer.normalView(); loading = false; return }
        loading = true
        defer { if currentRequest == token { loading = false } }
        do {
            viewer.setContextOpacity(Float(opacity))
            try await viewer.show(s, visibility: request.visibility, useBatchedContext: request.batched)
        } catch is CancellationError {
            return
        } catch {
            if currentRequest == token { issue = error.localizedDescription }
        }
    }
}
