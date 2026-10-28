import SwiftUI
import AppKit

struct AppUpdate: Identifiable, Hashable, Sendable {
    enum Channel: String, Sendable { case sparkle = "Developer", appStore = "App Store", homebrew = "Homebrew" }
    var id: String { "\(channel.rawValue)|\(name)" }
    let name: String
    let appURL: URL?
    let installed: String
    let latest: String
    let channel: Channel
    let downloadURL: URL?
    let caskName: String?
    var status: Status = .idle

    enum Status: Hashable, Sendable { case idle, updating, done, failed(String) }
}

/// Minimal Sparkle appcast reader: finds the newest item's version strings and download URL.
final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item { var short: String?; var build: String?; var url: String? }
    private(set) var items: [Item] = []
    private var current: Item?
    private var text = ""

    static func parse(_ data: Data) -> [Item] {
        let p = AppcastParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.shouldProcessNamespaces = false
        x.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = Item() }
        if name == "enclosure", var c = current {
            c.url = attributes["url"]
            if c.short == nil { c.short = attributes["sparkle:shortVersionString"] }
            if c.build == nil { c.build = attributes["sparkle:version"] }
            current = c
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:shortVersionString": if !t.isEmpty { current?.short = t }
        case "sparkle:version": if !t.isEmpty { current?.build = t }
        case "item": if let c = current { items.append(c) }; current = nil
        default: break
        }
    }
}

enum UpdateScanner {
    static func newer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Apps that ship Sparkle feeds: compare the newest appcast item with what's installed.
    static func sparkle(_ apps: [AppInfo]) async -> [AppUpdate] {
        await withTaskGroup(of: AppUpdate?.self) { group in
            for app in apps {
                group.addTask {
                    guard let info = Bundle(url: app.url)?.infoDictionary,
                          let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
                          feed.scheme == "https" else { return nil }
                    var req = URLRequest(url: feed, timeoutInterval: 12)
                    req.setValue("Breeze/\(AppConfig.version) (update check)", forHTTPHeaderField: "User-Agent")
                    guard let response = try? await URLSession.shared.data(for: req) else { return nil }
                    let items = AppcastParser.parse(response.0)
                    let installedShort = info["CFBundleShortVersionString"] as? String ?? "0"
                    let installedBuild = info["CFBundleVersion"] as? String ?? "0"
                    // Newest item by build number (falls back to short version).
                    guard let best = items.max(by: { ($0.build ?? $0.short ?? "0").compare($1.build ?? $1.short ?? "0", options: .numeric) == .orderedAscending }) else { return nil }
                    let isNewer: Bool = {
                        if let b = best.build, !b.isEmpty { return newer(b, than: installedBuild) }
                        return newer(best.short ?? "0", than: installedShort)
                    }()
                    guard isNewer else { return nil }
                    return AppUpdate(name: app.name, appURL: app.url, installed: installedShort,
                                     latest: best.short ?? best.build ?? "?", channel: .sparkle,
                                     downloadURL: best.url.flatMap(URL.init(string:)), caskName: nil)
                }
            }
            var out: [AppUpdate] = []
            for await u in group { if let u { out.append(u) } }
            return out
        }
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Outdated Homebrew casks (GUI apps installed with brew).
    static func homebrew() -> [AppUpdate] {
        guard let brew = brewPath else { return [] }
        let out = Shell.run("HOMEBREW_NO_AUTO_UPDATE=1 '\(brew)' outdated --cask --greedy --json=v2 2>/dev/null").output
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            let installed = (c["installed_versions"] as? [String])?.first ?? "?"
            let current = c["current_version"] as? String ?? "?"
            return AppUpdate(name: name, appURL: nil, installed: installed, latest: current, channel: .homebrew, downloadURL: nil, caskName: name)
        }
    }

    static func appStoreApps(_ apps: [AppInfo]) -> [AppInfo] {
        apps.filter { FileManager.default.fileExists(atPath: $0.url.appendingPathComponent("Contents/_MASReceipt/receipt").path) }
    }
}

@MainActor
@Observable
final class AppUpdatesModel {
    var phase: Phase = .idle
    var updates: [AppUpdate] = []
    var appStoreCount = 0
    var checkedCount = 0
    var hasBrew = UpdateScanner.brewPath != nil

    func scan(apps: UninstallerModel) async {
        phase = .scanning
        SoundFX.shared.play(.scanStart)
        if !apps.loaded { await SoundFX.shared.quietly { await apps.load() } }
        let list = apps.apps
        checkedCount = list.count
        appStoreCount = UpdateScanner.appStoreApps(list).count
        async let sparkle = UpdateScanner.sparkle(list)
        async let brew = Task.detached { UpdateScanner.homebrew() }.value
        let (s, b) = await (sparkle, brew)
        // Prefer the Homebrew entry when both know about the same app.
        let brewNames = Set(b.map { $0.name.lowercased() })
        updates = (b + s.filter { !brewNames.contains($0.name.lowercased()) }).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        withAnimation(.spring(response: 0.5)) { phase = .results }
        SoundFX.shared.play(.scanDone)
    }

    func update(_ u: AppUpdate) async {
        guard let i = updates.firstIndex(where: { $0.id == u.id }) else { return }
        switch u.channel {
        case .homebrew:
            guard let brew = UpdateScanner.brewPath, let cask = u.caskName else { return }
            updates[i].status = .updating
            let r = await Task.detached { Shell.run("HOMEBREW_NO_AUTO_UPDATE=1 '\(brew)' upgrade --cask '\(cask)' 2>&1") }.value
            if let j = updates.firstIndex(where: { $0.id == u.id }) {
                updates[j].status = r.ok ? .done : .failed(r.output.contains("sudo") ? "Needs your password. Run it in Terminal." : "Homebrew couldn't update it")
            }
            SoundFX.shared.play(r.ok ? .clean : .warn)
            CleanLog.log("brew upgrade --cask \(cask): \(r.ok ? "ok" : "failed")")
        case .sparkle:
            // Let the app's own updater install it: opening the app triggers its update check.
            if let url = u.appURL { NSWorkspace.shared.open(url) }
            updates[i].status = .done
        case .appStore:
            openAppStore()
        }
    }

    func download(_ u: AppUpdate) {
        if let url = u.downloadURL { NSWorkspace.shared.open(url) }
    }

    func openAppStore() {
        if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
    }
}
