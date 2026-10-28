import SwiftUI
import AppKit

enum PrivacyKind: String, CaseIterable, Sendable {
    case cache = "Cache"
    case history = "Browsing history"
    case cookies = "Cookies & site data"
    case recents = "Recent items"
    case shellHistory = "Terminal history"

    var icon: String {
        switch self {
        case .cache: "archivebox"
        case .history: "clock.arrow.circlepath"
        case .cookies: "birthday.cake"
        case .recents: "doc.badge.clock"
        case .shellHistory: "terminal"
        }
    }

    var note: String {
        switch self {
        case .cache: "Rebuilt automatically as you browse."
        case .history: "Every page you've visited and what you've typed in the address bar."
        case .cookies: "You'll be signed out of websites."
        case .recents: "Recently opened documents, apps and servers in menus."
        case .shellHistory: "Commands you've typed in Terminal."
        }
    }

    var defaultOn: Bool { self == .cache }
}

struct PrivacyItem: Identifiable, Hashable, Sendable {
    var id: String { "\(source)|\(kind.rawValue)" }
    let source: String
    let kind: PrivacyKind
    let paths: [URL]
    let size: Int64
    var selected: Bool
}

struct PrivacySource: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let bundleID: String?
    var items: [PrivacyItem]
    var note: String?
}

enum PrivacyScanner {
    struct Chromium { let name: String; let bundleID: String; let support: String; let caches: String }

    static let chromium: [Chromium] = [
        Chromium(name: "Google Chrome", bundleID: "com.google.Chrome", support: "Google/Chrome", caches: "Google/Chrome"),
        Chromium(name: "Brave", bundleID: "com.brave.Browser", support: "BraveSoftware/Brave-Browser", caches: "BraveSoftware/Brave-Browser"),
        Chromium(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", support: "Microsoft Edge", caches: "Microsoft Edge"),
        Chromium(name: "Arc", bundleID: "company.thebrowser.Browser", support: "Arc/User Data", caches: "Arc/User Data"),
        Chromium(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", support: "Vivaldi", caches: "Vivaldi"),
    ]

    static func scan() -> [PrivacySource] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library")
        var out: [PrivacySource] = []

        func existing(_ urls: [URL]) -> [URL] { urls.filter { fm.fileExists(atPath: $0.path) } }
        func item(_ source: String, _ kind: PrivacyKind, _ urls: [URL]) -> PrivacyItem? {
            let e = existing(urls)
            let size = e.reduce(Int64(0)) { $0 + FileSizer.size(of: $1) }
            guard !e.isEmpty, size > 0 else { return nil }
            return PrivacyItem(source: source, kind: kind, paths: e, size: size, selected: kind.defaultOn)
        }

        // Safari
        let safari = [
            item("Safari", .cache, [lib.appendingPathComponent("Caches/com.apple.Safari"),
                                    lib.appendingPathComponent("Containers/com.apple.Safari/Data/Library/Caches")]),
            item("Safari", .history, ["History.db", "History.db-wal", "History.db-shm", "History.db-lock"].map { lib.appendingPathComponent("Safari/\($0)") }),
            item("Safari", .cookies, [lib.appendingPathComponent("Cookies/Cookies.binarycookies"),
                                      lib.appendingPathComponent("Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")]),
        ].compactMap { $0 }
        if !safari.isEmpty { out.append(PrivacySource(name: "Safari", bundleID: "com.apple.Safari", items: safari, note: nil)) }

        // Chromium family: every profile folder ("Default", "Profile 1", …).
        for b in chromium {
            let base = lib.appendingPathComponent("Application Support/\(b.support)")
            guard fm.fileExists(atPath: base.path) else { continue }
            let profiles = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .map { base.appendingPathComponent($0) }
            var cache: [URL] = [lib.appendingPathComponent("Caches/\(b.caches)")]
            var history: [URL] = []
            var cookies: [URL] = []
            for p in profiles {
                cache += ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"].map { p.appendingPathComponent($0) }
                history += ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal"].map { p.appendingPathComponent($0) }
                cookies += ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"].map { p.appendingPathComponent($0) }
            }
            let items = [item(b.name, .cache, cache), item(b.name, .history, history), item(b.name, .cookies, cookies)].compactMap { $0 }
            if !items.isEmpty { out.append(PrivacySource(name: b.name, bundleID: b.bundleID, items: items, note: nil)) }
        }

        // Firefox: history shares a database with bookmarks, so Breeze leaves it alone.
        let ffProfiles = lib.appendingPathComponent("Application Support/Firefox/Profiles")
        if let names = try? fm.contentsOfDirectory(atPath: ffProfiles.path), !names.isEmpty {
            let cache = [lib.appendingPathComponent("Caches/Firefox")]
            let cookies = names.flatMap { n in ["cookies.sqlite", "cookies.sqlite-wal"].map { ffProfiles.appendingPathComponent("\(n)/\($0)") } }
            let items = [item("Firefox", .cache, cache), item("Firefox", .cookies, cookies)].compactMap { $0 }
            if !items.isEmpty {
                out.append(PrivacySource(name: "Firefox", bundleID: "org.mozilla.firefox", items: items,
                                         note: "Firefox keeps history and bookmarks in one file, so Breeze doesn't touch history."))
            }
        }

        // macOS
        var system: [PrivacyItem] = []
        let sfl = lib.appendingPathComponent("Application Support/com.apple.sharedfilelist")
        let recentFiles = ((try? fm.contentsOfDirectory(at: sfl, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.contains("Recent") }
        let appRecents = sfl.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
        if let r = item("macOS", .recents, recentFiles + [appRecents]) { system.append(r) }
        if let r = item("macOS", .shellHistory, [".zsh_history", ".bash_history"].map { home.appendingPathComponent($0) }) { system.append(r) }
        if !system.isEmpty { out.append(PrivacySource(name: "macOS", bundleID: nil, items: system, note: nil)) }
        return out
    }
}

@MainActor
@Observable
final class PrivacyModel {
    var phase: Phase = .idle
    var sources: [PrivacySource] = []
    var running: Set<String> = []
    var lastResult: Cleaner.Result?

    var selectedSize: Int64 { sources.flatMap(\.items).filter(\.selected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { sources.flatMap(\.items).filter(\.selected).count }
    /// Browsers that must be quit before their selected items can be cleaned.
    var blocking: [PrivacySource] {
        sources.filter { s in s.items.contains(where: \.selected) && s.bundleID.map { running.contains($0) } == true }
    }

    func scan() async {
        phase = .scanning
        SoundFX.shared.play(.scanStart)
        sources = await Task.detached(priority: .userInitiated) { PrivacyScanner.scan() }.value
        refreshRunning()
        withAnimation(.spring(response: 0.5)) { phase = .results }
        SoundFX.shared.play(.scanDone)
    }

    func refreshRunning() {
        running = Set(sources.compactMap(\.bundleID).filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
    }

    func toggle(_ item: PrivacyItem) {
        guard let s = sources.firstIndex(where: { $0.name == item.source }),
              let i = sources[s].items.firstIndex(where: { $0.id == item.id }) else { return }
        sources[s].items[i].selected.toggle()
        SoundFX.shared.play(.tap)
    }

    func quit(_ source: PrivacySource) async {
        guard let bid = source.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bid).forEach { $0.terminate() }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            refreshRunning()
            if !running.contains(bid) { break }
        }
    }

    func clean() async {
        refreshRunning()
        guard blocking.isEmpty else { return }
        let safe = UserDefaults.standard.bool(forKey: "safeMode")
        var jobs: [Cleaner.Job] = []
        for s in sources {
            for i in s.items where i.selected {
                // Each path's share of the item size is measured fresh; logging wants real numbers.
                for p in i.paths { jobs.append(.init(url: p, size: FileSizer.size(of: p), permanent: !safe)) }
            }
        }
        guard !jobs.isEmpty else { return }
        phase = .cleaning
        let result = await Task.detached { [jobs] in Cleaner.remove(jobs, source: "Privacy") }.value
        try? await Task.sleep(for: .seconds(0.7))
        lastResult = result
        Lifetime.record(result)
        phase = .done
        SoundFX.shared.play(result.failures.isEmpty ? .clean : .warn)
    }
}
