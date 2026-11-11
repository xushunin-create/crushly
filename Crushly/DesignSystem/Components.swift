import SwiftUI

// MARK: - Buttons

struct CrushButtonStyle: ButtonStyle {
    /// `onInk` is the outline style for dark (ink) cards.
    enum Kind { case primary, secondary, onInk, ink, quiet, destructive }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typeface.button)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, Theme.Space.l)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: kind == .secondary || kind == .onInk ? 1.5 : 0))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary, .ink, .onInk: .white
        case .secondary, .quiet: Theme.Palette.ink
        case .destructive: Theme.Palette.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.Palette.crush
        case .ink: Theme.Palette.ink
        case .secondary: .clear
        case .onInk: .white.opacity(0.08)
        case .quiet: Theme.Palette.ink.opacity(0.06)
        case .destructive: Theme.Palette.danger.opacity(0.09)
        }
    }

    private var border: Color {
        switch kind {
        case .secondary: Theme.Palette.ink.opacity(0.85)
        case .onInk: .white.opacity(0.7)
        default: .clear
        }
    }
}

extension ButtonStyle where Self == CrushButtonStyle {
    static var crush: CrushButtonStyle { CrushButtonStyle(kind: .primary) }
    static func crush(_ kind: CrushButtonStyle.Kind) -> CrushButtonStyle { CrushButtonStyle(kind: kind) }
}

/// Button that shows a spinner while its async action runs and ignores repeated taps.
struct AsyncButton<Label: View>: View {
    var role: ButtonRole?
    let action: () async -> Void
    @ViewBuilder let label: () -> Label
    @State private var running = false

    var body: some View {
        Button(role: role) {
            guard !running else { return }
            running = true
            Task {
                await action()
                running = false
            }
        } label: {
            ZStack {
                label().opacity(running ? 0 : 1)
                if running { ProgressView().tint(.white) }
            }
        }
        .disabled(running)
    }
}

// MARK: - Headers and labels

struct SectionHeader: View {
    let eyebrow: String
    let title: String
    var trailing: AnyView?

    init(eyebrow: String, title: String, trailing: AnyView? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased())
                    .font(Theme.Typeface.eyebrow)
                    .kerning(1.5)
                    .foregroundStyle(Theme.Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text(title)
                    .font(Theme.Typeface.title)
                    .foregroundStyle(Theme.Palette.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.m)
            trailing
        }
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Typeface.eyebrow)
            .tracking(1.6)
            .foregroundStyle(Theme.Palette.inkSoft)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Tag: View {
    let text: String
    var tint: Color = Theme.Palette.ink
    var fill: Color = Theme.Palette.surface

    var body: some View {
        Text(text)
            .font(Theme.Typeface.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(Theme.Palette.hairline))
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color
    var fill: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Typeface.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill, in: Capsule())
    }
}

/// Persistent marker shown whenever the app runs against the demo backend.
struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.system(.caption2, design: .monospaced).weight(.black))
            .tracking(1.5)
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.Palette.live, in: Capsule())
            .accessibilityLabel("Demo mode. Data is fictional.")
    }
}

// MARK: - Empty and error states

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.Palette.crush)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typeface.title2)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.Typeface.callout)
                .foregroundStyle(Theme.Palette.inkSoft)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.crush(.secondary))
                    .padding(.top, Theme.Space.s)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .padding(.horizontal, Theme.Space.l)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.circle.fill")
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Typeface.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: Theme.minTap, height: Theme.minTap)
            }
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.white)
        .padding(.leading, Theme.Space.l)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.Palette.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .padding(.horizontal, Theme.Space.gutter)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Sheets

/// Apply to the root of every sheet: it closes itself when a Heart Sync reveal needs the screen.
struct ClosesForReveal: ViewModifier {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .onAppear { state.modalAppeared() }
            .onDisappear { state.modalDisappeared() }
            .onChange(of: state.dismissModalsToken) { _, _ in dismiss() }
    }
}

extension View {
    func closesForReveal() -> some View { modifier(ClosesForReveal()) }
}

// MARK: - Flow layout for tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
