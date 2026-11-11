import SwiftUI

/// Design tokens. Every screen pulls color, type, spacing and motion from here.
enum Theme {
    // MARK: Color

    enum Palette {
        /// Warm paper background.
        static let paper = Color(red: 0.969, green: 0.949, blue: 0.918)
        /// Raised surfaces on paper.
        static let surface = Color(red: 0.992, green: 0.982, blue: 0.962)
        /// Near-black ink used for text and dark cards.
        static let ink = Color(red: 0.11, green: 0.08, blue: 0.10)
        /// Secondary text. ≥4.5:1 on paper.
        static let inkSoft = Color(red: 0.36, green: 0.31, blue: 0.33)
        /// Tertiary text for large/bold labels only. ≥3:1 on paper.
        static let inkFaint = Color(red: 0.52, green: 0.47, blue: 0.48)
        /// Brand crush pink. White text on it is ≥4.5:1.
        static let crush = Color(red: 0.84, green: 0.12, blue: 0.32)
        static let crushSoft = Color(red: 0.98, green: 0.85, blue: 0.88)
        /// Live signal lime — only on ink backgrounds.
        static let live = Color(red: 0.78, green: 1.0, blue: 0.25)
        static let plum = Color(red: 0.36, green: 0.18, blue: 0.55)
        static let plumSoft = Color(red: 0.91, green: 0.87, blue: 0.96)
        /// Lavender for text/icons on ink backgrounds (plum itself is too dark there).
        static let lavender = Color(red: 0.80, green: 0.72, blue: 1.0)
        static let amber = Color(red: 0.62, green: 0.38, blue: 0.0)
        static let amberSoft = Color(red: 0.99, green: 0.93, blue: 0.80)
        static let mint = Color(red: 0.05, green: 0.47, blue: 0.30)
        static let mintSoft = Color(red: 0.85, green: 0.95, blue: 0.89)
        static let danger = Color(red: 0.72, green: 0.10, blue: 0.10)
        static let hairline = Color.black.opacity(0.08)
    }

    // MARK: Type (all styles scale with Dynamic Type)

    enum Typeface {
        static let display = Font.system(.largeTitle, design: .serif).weight(.bold)
        static let title = Font.system(.title, design: .serif).weight(.bold)
        static let title2 = Font.system(.title2, design: .serif).weight(.semibold)
        static let headline = Font.system(.headline, design: .rounded).weight(.bold)
        static let body = Font.system(.body, design: .rounded)
        static let callout = Font.system(.callout, design: .rounded)
        static let subheadline = Font.system(.subheadline, design: .rounded)
        static let footnote = Font.system(.footnote, design: .rounded)
        static let caption = Font.system(.caption, design: .rounded).weight(.medium)
        static let eyebrow = Font.system(.caption, design: .rounded).weight(.heavy)
        static let button = Font.system(.headline, design: .rounded).weight(.heavy)
    }

    // MARK: Layout

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let gutter: CGFloat = 20
    }

    enum Radius {
        static let s: CGFloat = 12
        static let m: CGFloat = 18
        static let l: CGFloat = 26
    }

    /// Minimum interactive size (Apple HIG: 44pt).
    static let minTap: CGFloat = 44

    // MARK: Motion

    enum Motion {
        static let snappy = Animation.spring(response: 0.35, dampingFraction: 0.8)
        static let soft = Animation.easeInOut(duration: 0.25)
        static let heartbeat = Animation.easeInOut(duration: 0.78).repeatForever(autoreverses: true)
    }
}

extension View {
    /// Standard raised card on paper.
    func crushCard(padding: CGFloat = Theme.Space.l, fill: Color = Theme.Palette.surface) -> some View {
        self
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .stroke(Theme.Palette.hairline, lineWidth: 1)
            )
    }

    /// Dark "ink" card used for status and primary moments.
    func inkCard(padding: CGFloat = Theme.Space.l) -> some View {
        self
            .padding(padding)
            .foregroundStyle(.white)
            .background(Theme.Palette.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
    }
}
