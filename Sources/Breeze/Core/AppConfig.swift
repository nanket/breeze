import Foundation

/// Everything you need to change before shipping lives here.
enum AppConfig {
    static let appName = "Breeze"

    /// Where customers write to you. Used by "Contact Support" and crash reports.
    static let supportEmail = "aniketvnagapure@gmail.com"

    /// Marketing site and hosted legal pages.
    static let websiteURL = URL(string: "https://nanket.github.io/breeze/")!
    static let privacyURL = URL(string: "https://nanket.github.io/breeze/privacy.html")!
    static let termsURL = URL(string: "https://nanket.github.io/breeze/terms.html")!

    /// Source code and the pay-what-you-want tip page.
    static let sourceURL = URL(string: "https://github.com/nanket/breeze")!
    static let tipURL = URL(string: "https://aniketpure.gumroad.com/l/breeze")!

    /// JSON describing the latest release (see docs/appcast.json). Host it on GitHub Pages or your site.
    static let updateFeedURL = URL(string: "https://nanket.github.io/breeze/appcast.json")!

    /// True while placeholders above are still in place, so the app never pings example.com.
    static var isConfigured: Bool { !updateFeedURL.host!.contains("example.com") }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1 }

    static var supportFolder: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var logFolder: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(appName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
