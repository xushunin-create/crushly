import SwiftUI
import UIKit

/// Profile photo with graceful fallbacks:
/// `avatar:<sf-symbol>|<color>` → generated illustration (demo people), `demo/...` → in-memory demo upload,
/// anything else → signed URL from storage.
struct Avatar: View {
    let path: String?
    var name: String = ""
    var size: CGFloat = 64
    var shape: AvatarShape = .circle

    enum AvatarShape { case circle, rounded }

    @Environment(AppState.self) private var state
    @State private var image: UIImage?
    @State private var remoteURL: URL?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(clip)
            .accessibilityHidden(true)
            .task(id: path) { await load() }
    }

    private var clip: AnyShape {
        shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        if let path, path.hasPrefix("avatar:") {
            generated(path)
        } else if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let remoteURL {
            AsyncImage(url: remoteURL) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.Palette.crushSoft
            Text(name.prefix(1).uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .serif))
                .foregroundStyle(Theme.Palette.crush)
        }
    }

    private func generated(_ path: String) -> some View {
        let parts = path.dropFirst("avatar:".count).split(separator: "|").map(String.init)
        let color = Avatar.color(named: parts.count > 1 ? parts[1] : "pink")
        return ZStack {
            LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.14)).frame(width: size * 0.9).offset(x: size * 0.28, y: -size * 0.3)
            Image(systemName: parts.first ?? "heart.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    static func color(named name: String) -> Color {
        switch name {
        case "purple": Color(red: 0.49, green: 0.28, blue: 0.80)
        case "blue": Color(red: 0.16, green: 0.42, blue: 0.85)
        case "orange": Color(red: 0.93, green: 0.45, blue: 0.13)
        case "mint": Color(red: 0.10, green: 0.62, blue: 0.48)
        case "amber": Color(red: 0.85, green: 0.58, blue: 0.08)
        case "plum": Theme.Palette.plum
        case "teal": Color(red: 0.05, green: 0.55, blue: 0.62)
        default: Theme.Palette.crush
        }
    }

    private func load() async {
        image = nil
        remoteURL = nil
        guard let path, !path.hasPrefix("avatar:") else { return }
        if let data = state.demo?.demoPhotoData(for: path) {
            image = UIImage(data: data)
        } else {
            remoteURL = await state.backend.photoURL(for: path)
        }
    }
}

/// Brand mark: a heart inside a pulse ring.
struct HeartMark: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().stroke(Theme.Palette.crush.opacity(0.25), lineWidth: size * 0.05).frame(width: size * 1.4, height: size * 1.4)
            Image(systemName: "heart.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Theme.Palette.crush)
        }
        .accessibilityHidden(true)
    }
}
