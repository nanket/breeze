import SwiftUI
import AppKit

struct AppInfo: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleName: String
    let bundleID: String?
    let version: String?
    var size: Int64?
    let lastUsed: Date?

    var isUnused: Bool {
        guard let lastUsed else { return true }
        return Date().timeIntervalSince(lastUsed) > 182 * 86_400
    }
}

struct Leftover: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let group: String
    let size: Int64
    var selected = true
}

enum AppSort: String, CaseIterable, Identifiable {
    case size = "Size", name = "Name", lastUsed = "Last Used"
    var id: String { rawValue }
}

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "All Apps", unused = "Unused", large = "Large"
    var id: String { rawValue }
}

enum AppScanner {
    static func listApps() -> [AppInfo] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var bundles: [URL] = []
        for root in roots {
            guard let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for k in kids {
                if k.pathExtension == "app" {
                    bundles.append(k)
                } else if let sub = try? fm.contentsOfDirectory(at: k, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    bundles += sub.filter { $0.pathExtension == "app" }
                }
            }
        }

        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return bundles.compactMap { url -> AppInfo? in
            let b = Bundle(url: url)
            let bid = b?.bundleIdentifier
            if let bid, bid.hasPrefix("com.apple.") || bid == me { return nil }
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { return nil }
            let info = b?.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let version = info["CFBundleShortVersionString"] as? String
            return AppInfo(
                url: url, name: url.deletingPathExtension().lastPathComponent, bundleName: name,
                bundleID: bid, version: version, size: nil, lastUsed: Spotlight.lastUsed(url)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Finds support files the app left in ~/Library, matched by bundle ID (and by exact app name
    /// in folders where apps commonly use their display name).
    /// `others` are the bundle IDs of the other installed apps, so uninstalling
    /// com.google.Chrome doesn't also catch com.google.Chrome.canary's files.
    static func leftovers(for app: AppInfo, others: [String] = []) -> [Leftover] {
        let fm = FileManager.default
        let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let bid = app.bundleID?.lowercased() ?? ""
        let siblings = others.map { $0.lowercased() }.filter { $0 != bid && $0.hasPrefix(bid + ".") }
        let names = Set([app.name, app.bundleName].map { $0.lowercased() }.filter { $0.count > 2 })
        let places: [(String, String, Bool)] = [
            ("Application Support", "Application Support", true),
            ("Caches", "Caches", true),
            ("Logs", "Logs", true),
            ("Preferences", "Preferences", false),
            ("Preferences/ByHost", "Preferences", false),
            ("Saved Application State", "Saved State", false),
            ("Containers", "Containers", false),
            ("Group Containers", "Group Containers", false),
            ("Application Scripts", "Scripts", false),
            ("HTTPStorages", "Web Data", false),
            ("WebKit", "Web Data", false),
            ("Cookies", "Web Data", false),
            ("LaunchAgents", "Launch Agents", false),
        ]

        var out: [Leftover] = []
        for (sub, group, byName) in places {
            let dir = lib.appendingPathComponent(sub)
            guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) else { continue }
            for k in kids {
                let n = k.lastPathComponent.lowercased()
                let stem = (n as NSString).deletingPathExtension
                var hit = false
                if !bid.isEmpty {
                    hit = n == bid || stem == bid || n.hasPrefix(bid + ".") || n.hasSuffix("." + bid)
                        || (sub == "LaunchAgents" && n.contains(bid))
                    if hit, siblings.contains(where: { n == $0 || stem == $0 || n.hasPrefix($0 + ".") || n.contains($0) }) { hit = false }
                }
                if !hit && byName && names.contains(n) { hit = true }
                if hit {
                    out.append(Leftover(url: k, group: group, size: FileSizer.size(of: k)))
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

@MainActor
@Observable
final class UninstallerModel {
    var apps: [AppInfo] = []
    var loaded = false
    var loading = false
    var search = ""
    var sort: AppSort = .size
    var filter: AppFilter = .all
    var selectedID: URL?
    var leftovers: [Leftover] = []
    var leftoversLoading = false
    var keepApp = false
    var working = false
    var toast: String?
    private var leftoverTask: Task<Void, Never>?

    var selected: AppInfo? { apps.first { $0.id == selectedID } }
    var unusedCount: Int { apps.filter(\.isUnused).count }
    var totalSize: Int64 { apps.reduce(0) { $0 + ($1.size ?? 0) } }

    var visible: [AppInfo] {
        var list = apps
        switch filter {
        case .all: break
        case .unused: list = list.filter(\.isUnused)
        case .large: list = list.filter { ($0.size ?? 0) > 500 * 1_048_576 }
        }
        if !search.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: list.sort { ($0.size ?? -1) > ($1.size ?? -1) }
        case .lastUsed: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        return list
    }

    var removalSize: Int64 {
        (keepApp ? 0 : (selected?.size ?? 0)) + leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        apps = await Task.detached(priority: .userInitiated) { AppScanner.listApps() }.value
        loaded = true
        if selectedID == nil { selectedID = apps.first?.id }
        if let s = selected { select(s) }
        let urls = apps.map(\.url)
        await withTaskGroup(of: (URL, Int64).self) { group in
            var it = urls.makeIterator()
            for _ in 0..<6 {
                guard let u = it.next() else { break }
                group.addTask { (u, FileSizer.size(of: u)) }
            }
            while let r = await group.next() {
                if let i = apps.firstIndex(where: { $0.url == r.0 }) { apps[i].size = r.1 }
                if let n = it.next() { group.addTask { (n, FileSizer.size(of: n)) } }
            }
        }
        loading = false
    }

    func select(_ app: AppInfo) {
        selectedID = app.id
        leftovers = []
        leftoversLoading = true
        leftoverTask?.cancel()
        let others = apps.compactMap(\.bundleID)
        leftoverTask = Task {
            let found = await Task.detached(priority: .userInitiated) { AppScanner.leftovers(for: app, others: others) }.value
            guard !Task.isCancelled, selectedID == app.id else { return }
            leftovers = found
            leftoversLoading = false
        }
    }

    func toggleLeftover(_ id: URL) {
        if let i = leftovers.firstIndex(where: { $0.id == id }) { leftovers[i].selected.toggle() }
        SoundFX.shared.play(.tap)
    }

    func uninstall() async {
        guard let app = selected, !leftoversLoading else { return }
        working = true
        defer { working = false }
        // Snapshot what to remove now: the selection can change while we wait for the app to quit.
        let keepApp = keepApp
        let picked = leftovers.filter(\.selected)

        // Quit the app first if it's running (for Reset too, so it can't rewrite its data).
        if let bid = app.bundleID {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            running.forEach { $0.terminate() }
            if !running.isEmpty { try? await Task.sleep(for: .seconds(1.5)) }
        }

        var jobs = picked.map { Cleaner.Job(url: $0.url, size: $0.size, permanent: false) }
        if !keepApp { jobs.insert(.init(url: app.url, size: app.size ?? 0, permanent: false), at: 0) }

        var result = await Task.detached { [jobs] in Cleaner.remove(jobs, source: "Uninstaller") }.value

        // Root-owned apps: fall back to Finder, which asks for the admin password.
        if !keepApp, FileManager.default.fileExists(atPath: app.url.path) {
            let ok = await Task.detached { Cleaner.finderTrash(app.url) }.value
            if ok {
                result.failures.removeAll { $0.url == app.url }
                result.trashed += app.size ?? 0
            }
        }

        Lifetime.record(result)
        let moved = Fmt.bytes(result.trashed)
        SoundFX.shared.play(result.failures.isEmpty ? .clean : .warn)
        if result.failures.isEmpty {
            toast = keepApp ? "Reset \(app.name): \(moved) moved to Trash" : "Uninstalled \(app.name): \(moved) moved to Trash"
        } else {
            toast = "Finished with \(result.failures.count) item(s) that couldn't be removed"
        }

        if !keepApp && !FileManager.default.fileExists(atPath: app.url.path) {
            apps.removeAll { $0.id == app.id }
            selectedID = visible.first?.id
            if let s = selected { select(s) } else { leftovers = [] }
        } else {
            select(app)
        }
    }
}
