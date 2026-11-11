import Foundation

/// Decides which backend this run uses. Demo and live never mix within a run.
nonisolated struct AppConfig: Sendable {
    enum Environment: Equatable, Sendable {
        case demo
        case live(url: URL, anonKey: String)
    }

    let environment: Environment

    var isDemo: Bool { environment == .demo }

    /// Reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `Secrets.plist` in the app bundle
    /// (git-ignored: copy `Config/Secrets.example.plist` to `Crushly/Resources/Secrets.plist`).
    /// Missing or placeholder values → demo. The `-CrushlyDemo` launch argument forces demo.
    /// Only the anon key belongs in the app; the service-role key must never be bundled.
    static func load(bundle: Bundle = .main, arguments: [String] = ProcessInfo.processInfo.arguments) -> AppConfig {
        if arguments.contains("-CrushlyDemo") { return AppConfig(environment: .demo) }
        var values: [String: Any] = [:]
        if let url = bundle.url(forResource: "Secrets", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            values = plist
        }
        let urlString = (values["SUPABASE_URL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (values["SUPABASE_ANON_KEY"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost",
              !key.isEmpty, !key.contains("YOUR_") else {
            return AppConfig(environment: .demo)
        }
        return AppConfig(environment: .live(url: url, anonKey: key))
    }
}
