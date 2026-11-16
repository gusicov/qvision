import SwiftUI

// Shared look of every QVision screen (v0.7 L5): the brand mark, the "you are here"
// breadcrumb, card surfaces and small controls. visionOS-native: system materials, system
// type styles, hover effects; no custom fonts or images.

enum Brand {
    static let name = "QVision"
    static let tagline = "Your 3D models at real size, in your space."

    static let accentStart = Color(red: 0.24, green: 0.76, blue: 0.96)
    static let accentEnd = Color(red: 0.45, green: 0.38, blue: 0.98)

    static var gradient: LinearGradient {
        LinearGradient(colors: [accentStart, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Corner radius of the content cards on every screen.
    static let cardRadius: CGFloat = 24
}

/// The QVision mark: a gradient tile with a cube glyph.
struct BrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Brand.gradient)
            Image(systemName: "cube.transparent")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Mark + wordmark + tagline, with an optional trailing action (Home, Server).
struct BrandHeader<Trailing: View>: View {
    private let trailing: Trailing

    init(@ViewBuilder trailing: () -> Trailing) {
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            BrandMark(size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(Brand.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                Text(Brand.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 16)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension BrandHeader where Trailing == EmptyView {
    init() {
        self.init { EmptyView() }
    }
}

/// "Home › Project › Layers". The last component is where you are (bold). If `onHome` is set,
/// the first component is a button.
struct Breadcrumb: View {
    let components: [String]
    var prominent: Bool = false
    var onHome: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                let isLast = index == components.count - 1
                if index == 0, !isLast, let onHome {
                    Button(action: onHome) {
                        Label(name, systemImage: "house")
                            .font(font(isLast: false))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(.hoverEffect, Capsule())
                    .hoverEffect()
                    .accessibilityLabel("Back to Home")
                } else {
                    Text(name)
                        .font(font(isLast: isLast))
                        .foregroundStyle(isLast ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You are in " + components.joined(separator: ", "))
    }

    private func font(isLast: Bool) -> Font {
        if prominent {
            return isLast ? .title2.weight(.bold) : .title3
        }
        return isLast ? .headline : .subheadline
    }
}

/// Section title used inside screens ("Servers", "Settings", "Objects").
struct SectionTitle<Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    private let trailing: Trailing

    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.title3.weight(.semibold))
            } else {
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }
}

extension View {
    /// The standard content card: regular material, continuous corners.
    func qvCard(padding: CGFloat = 20, cornerRadius: CGFloat = Brand.cardRadius) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Registers this scene's open/dismiss actions with AppModel so the app flow (open / leave
    /// a project, close-the-last-window) can run even after the window that started it closed.
    func installsSceneActions() -> some View {
        modifier(SceneActionsInstaller())
    }
}

private struct SceneActionsInstaller: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    func body(content: Content) -> some View {
        content.onAppear {
            model.installSceneActions(AppModel.SceneActions(
                openWindow: openWindow,
                dismissWindow: dismissWindow,
                openImmersiveSpace: openImmersiveSpace,
                dismissImmersiveSpace: dismissImmersiveSpace
            ))
        }
    }
}

/// Initial tile used as a project thumbnail (no thumbnails are stored yet). Its hue is
/// derived from the project id, so every project keeps its colour.
struct ProjectMonogram: View {
    let project: Project
    var height: CGFloat = 120

    var body: some View {
        let hue = Self.hue(for: project.id)
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                             Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(Self.initials(of: project.name))
                .font(.system(size: height * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 12)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    static func hue(for id: UUID) -> Double {
        let bytes = id.uuid
        return Double((Int(bytes.0) << 8 | Int(bytes.1)) % 360) / 360
    }

    /// "Office Tower" -> "OT", "chair" -> "C".
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "Q" : letters.joined()
    }
}

/// Round icon button used in toolbars (Undo, Redo, Back, Forward).
struct ToolbarIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A small pill: "12 objects", "Streaming".
struct InfoPill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color? = nil

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }
}

// MARK: - v0.9 G: shared pieces for every Home tab

extension View {
    /// Label of a primary action (Open, Download, Connect, New Project): headline text, at least
    /// 60 pt tall. `expands`: take the full width of the container.
    func primaryActionLabel(expands: Bool = true) -> some View {
        self
            .font(.headline)
            .lineLimit(1)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: 60)
            .padding(.horizontal, expands ? 0 : 10)
    }
}

/// The empty state used on every screen: what is missing and what to do next.
struct EmptyStateCard: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(Brand.gradient)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .qvCard()
    }
}
