import SwiftUI

/// Design tokens. Every screen pulls color, type, spacing and motion from here.
enum Theme {
    // MARK: Color

    enum Palette {
        // Crushly's retro campus palette from the visual system board.
        static let paper = Color(red: 0.976, green: 0.929, blue: 0.878)       // #F9EDE0
        static let surface = Color(red: 1.0, green: 0.976, blue: 0.941)
        static let ink = Color(red: 0.478, green: 0.122, blue: 0.122)         // #7A1F1F
        static let inkSoft = Color(red: 0.36, green: 0.22, blue: 0.20)
        static let inkFaint = Color(red: 0.53, green: 0.40, blue: 0.37)
        static let crush = Color(red: 0.969, green: 0.435, blue: 0.380)       // #F76F61
        static let crushSoft = Color(red: 1.0, green: 0.714, blue: 0.780)     // #FFB6C7
        /// Coral dark enough for text and links on paper/surface (≥ 4.5:1). Use `crush` for icons and fills.
        static let crushText = Color(red: 0.70, green: 0.16, blue: 0.13)      // #B3291F
        /// Amber dark enough for text (≥ 4.5:1 on amberSoft/surface).
        static let amberText = Color(red: 0.52, green: 0.27, blue: 0.0)
        static let orange = Color(red: 1.0, green: 0.478, blue: 0.0)         // #FF7A00
        static let oxblood = Color(red: 0.478, green: 0.122, blue: 0.122)    // #7A1F1F
        static let blush = Color(red: 1.0, green: 0.714, blue: 0.780)        // #FFB6C7
        static let periwinkle = Color(red: 0.357, green: 0.420, blue: 1.0)   // #5B6BFF
        static let live = Color(red: 0.20, green: 0.70, blue: 0.34)
        static let plum = oxblood
        static let plumSoft = blush.opacity(0.34)
        static let lavender = periwinkle
        static let amber = orange
        static let amberSoft = Color(red: 1.0, green: 0.91, blue: 0.72)
        static let mint = Color(red: 0.12, green: 0.58, blue: 0.31)
        static let mintSoft = Color(red: 0.86, green: 0.95, blue: 0.84)
        static let danger = Color(red: 0.66, green: 0.08, blue: 0.10)
        static let hairline = oxblood.opacity(0.12)
        static let primaryGradient = LinearGradient(
            colors: [periwinkle, Color(red: 0.31, green: 0.22, blue: 0.96)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: Type (all styles scale with Dynamic Type)

    enum Typeface {
        /// Scales with Dynamic Type (large title, serif black).
        static let display = Font.system(.largeTitle, design: .serif).weight(.black)
        static let title = Font.system(.title, design: .serif).weight(.black)
        static let title2 = Font.system(.title2, design: .serif).weight(.bold)
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
        static let l: CGFloat = 28
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
            // The shadow belongs to the card shape only; applied to the whole view it would blur behind every
            // glyph and lower text contrast.
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .fill(fill)
                    .shadow(color: Theme.Palette.oxblood.opacity(0.08), radius: 12, y: 6)
            }
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
