import SwiftUI

/// Abstract radar. Placement is a stable hash of (session, person) — it carries no location information.
struct RadarView: View {
    let people: [PublicProfile]
    let seed: UUID
    let onSelect: (PublicProfile) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach([0.95, 0.68, 0.42], id: \.self) { scale in
                    Circle()
                        .stroke(Theme.Palette.crush.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: scale == 0.68 ? [4, 5] : []))
                        .frame(width: size * scale, height: size * scale)
                }
                if !reduceMotion {
                    Circle()
                        .stroke(Theme.Palette.crush.opacity(sweep ? 0 : 0.35), lineWidth: 2)
                        .frame(width: size * (sweep ? 0.95 : 0.3), height: size * (sweep ? 0.95 : 0.3))
                        .animation(.easeOut(duration: 2.6).repeatForever(autoreverses: false), value: sweep)
                }
                Circle()
                    .fill(Theme.Palette.crush)
                    .frame(width: size * 0.2, height: size * 0.2)
                    .overlay(Image(systemName: "heart.fill").font(.system(size: size * 0.07)).foregroundStyle(.white))
                    .shadow(color: Theme.Palette.crush.opacity(0.35), radius: 14)
                    .accessibilityLabel("You")

                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    let point = position(for: person, index: index, count: people.count, size: size, center: center)
                    Button { onSelect(person) } label: {
                        VStack(spacing: 4) {
                            Avatar(path: person.photoPaths.first, name: person.firstName, size: 48)
                                .overlay(Circle().stroke(.white, lineWidth: 3))
                                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                            Text(person.firstName)
                                .font(Theme.Typeface.caption.weight(.bold))
                                .foregroundStyle(Theme.Palette.ink)
                                .padding(.horizontal, 6)
                                .background(Theme.Palette.paper.opacity(0.85), in: Capsule())
                        }
                        .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
                    }
                    .buttonStyle(.plain)
                    .position(point)
                    .accessibilityLabel("\(person.firstName), \(person.age). \(person.availability.title)")
                    .accessibilityHint("Opens profile")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { sweep = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People active in your space")
    }

    /// Even angular spread with a per-session rotation and jittered ring, so positions are stable for a
    /// session but meaningless across sessions and unrelated to physical location.
    private func position(for person: PublicProfile, index: Int, count: Int, size: CGFloat, center: CGPoint) -> CGPoint {
        let h = stableHash(seed.uuidString + person.id.uuidString)
        let rotation = Double(stableHash(seed.uuidString) % 360) * .pi / 180
        let angle = rotation + (Double(index) / Double(max(count, 1))) * 2 * .pi + Double(h % 30) * .pi / 180 / 3
        let ring = 0.27 + Double(h % 100) / 100 * 0.17
        return CGPoint(x: center.x + cos(angle) * size * ring, y: center.y + sin(angle) * size * ring)
    }

    private func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int(hash % 10_000)
    }
}
