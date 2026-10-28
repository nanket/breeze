import SwiftUI

struct JunkItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let label: String
    let size: Int64
    var selected: Bool
    /// When set, Breeze runs this tool (argv) instead of deleting `url` itself,
    /// e.g. `xcrun simctl delete <udid>` so Xcode's bookkeeping stays consistent.
    var removal: [String]? = nil
}

struct JunkCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let permanent: Bool
    var items: [JunkItem]
    var denied: Bool

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.reduce(0) { $0 + ($1.selected ? $1.size : 0) } }
    var selectedCount: Int { items.reduce(0) { $0 + ($1.selected ? 1 : 0) } }

    var checkState: CheckState {
        let n = selectedCount
        if n == 0 { return .off }
        return n == items.count ? .on : .mixed
    }
}

struct JunkRule: Sendable {
    struct Named: Sendable { let label: String; let path: String }

    enum Source: Sendable {
        /// Every child of the folder is its own removable item.
        case children(String)
        /// Specific folders, each removed as a whole.
        case paths([Named])
        /// Files with matching extensions directly inside the folder.
        case files(String, Set<String>)
        /// Simulators whose iOS version is gone, and big simulators you can erase.
        case simulators
        /// Whole simulator runtimes (iOS 17, watchOS 10…), several GB each.
        case simRuntimes
    }

    let id: String
    let title: String
    let detail: String
    let icon: String
    let sources: [Source]
    let defaultOn: Bool
    let permanent: Bool
    var exclude: Set<String> = []
}

enum JunkScanner {
    static let devCacheNames: Set<String> = [
        "Homebrew", "CocoaPods", "pip", "Yarn", "node-gyp", "go-build", "JetBrains",
        "org.swift.swiftpm", "ms-playwright", "org.carthage.CarthageKit",
    ]

    /// Caches that macOS services actively depend on; skipped to stay safe.
    static let protectedCaches: Set<String> = [
        "com.apple.HomeKit", "CloudKit", "com.apple.bird", "FamilyCircle", "com.apple.akd",
        "com.apple.Safari.SafeBrowsing", "com.apple.containermanagerd", "com.apple.ap.adprivacyd",
        "com.apple.homed", "com.apple.iCloudHelper", "com.apple.nsurlsessiond",
        "familycircled", "com.apple.amsengagementd", "com.apple.appstoreagent", "com.apple.commerce",
        "com.apple.passd", "com.apple.parsecd", "com.apple.siri.media-indexer", "GeoServices",
        Bundle.main.bundleIdentifier ?? "app.breeze.cleaner", ".localized", ".DS_Store",
    ]

    static var rules: [JunkRule] {
        [
            JunkRule(
                id: "cache", title: "User Cache Files",
                detail: "Temporary data apps keep to load faster. Apps quietly rebuild whatever they still need.",
                icon: "archivebox", sources: [.children("~/Library/Caches")],
                defaultOn: true, permanent: true,
                exclude: devCacheNames.union(protectedCaches)
            ),
            JunkRule(
                id: "logs", title: "User Log Files",
                detail: "Activity logs written by apps and background services.",
                icon: "doc.text", sources: [.children("~/Library/Logs")],
                defaultOn: true, permanent: true, exclude: ["DiagnosticReports", ".localized", AppConfig.appName]
            ),
            JunkRule(
                id: "crash", title: "Crash Reports",
                detail: "Diagnostic reports from apps that quit unexpectedly.",
                icon: "exclamationmark.triangle", sources: [.children("~/Library/Logs/DiagnosticReports")],
                defaultOn: true, permanent: true
            ),
            JunkRule(
                id: "xcode", title: "Xcode Junk",
                detail: "DerivedData, device support files, SwiftUI preview and simulator caches. Xcode regenerates them on the next build.",
                icon: "hammer",
                sources: [
                    .children("~/Library/Developer/Xcode/DerivedData"),
                    .children("~/Library/Developer/Xcode/iOS DeviceSupport"),
                    .children("~/Library/Developer/Xcode/watchOS DeviceSupport"),
                    .children("~/Library/Developer/Xcode/macOS DeviceSupport"),
                    .children("~/Library/Developer/CoreSimulator/Caches"),
                    .paths([
                        .init(label: "Documentation Cache", path: "~/Library/Developer/Xcode/DocumentationCache"),
                        .init(label: "SwiftUI Preview simulators", path: "~/Library/Developer/Xcode/UserData/Previews"),
                        .init(label: "iOS Device Logs", path: "~/Library/Developer/Xcode/iOS Device Logs"),
                        .init(label: "Playground simulators", path: "~/Library/Developer/XCPGDevices"),
                    ]),
                ],
                defaultOn: true, permanent: true
            ),
            JunkRule(
                id: "simulators", title: "Old Simulators",
                detail: "Simulators for iOS versions you no longer have are pre-selected. Large simulators you still use can be erased back to a clean state. Removed with Xcode's own simctl tool.",
                icon: "ipad.and.iphone", sources: [.simulators],
                defaultOn: true, permanent: true
            ),
            JunkRule(
                id: "runtimes", title: "Simulator Runtimes",
                detail: "Complete iOS, watchOS, tvOS and visionOS simulator systems, often 5–10 GB each. Older ones you haven't used in 90 days are pre-selected. Xcode can download any of them again from Settings → Components.",
                icon: "square.stack.3d.down.right", sources: [.simRuntimes],
                defaultOn: false, permanent: true
            ),
            JunkRule(
                id: "dev", title: "Developer Caches",
                detail: "Package-manager and editor caches. They're downloaded again the next time a project needs them.",
                icon: "shippingbox",
                sources: [.paths([
                    .init(label: "npm cache", path: "~/.npm/_cacache"),
                    .init(label: "Gradle caches", path: "~/.gradle/caches"),
                    .init(label: "Homebrew downloads", path: "~/Library/Caches/Homebrew"),
                    .init(label: "CocoaPods cache", path: "~/Library/Caches/CocoaPods"),
                    .init(label: "pip cache", path: "~/Library/Caches/pip"),
                    .init(label: "Yarn cache", path: "~/Library/Caches/Yarn"),
                    .init(label: "node-gyp headers", path: "~/Library/Caches/node-gyp"),
                    .init(label: "Go build cache", path: "~/Library/Caches/go-build"),
                    .init(label: "JetBrains caches", path: "~/Library/Caches/JetBrains"),
                    .init(label: "SwiftPM cache", path: "~/Library/Caches/org.swift.swiftpm"),
                    .init(label: "Playwright browsers", path: "~/Library/Caches/ms-playwright"),
                    .init(label: "Dart analysis cache", path: "~/.dartServer/.analysis-driver"),
                    .init(label: "Android SDK cache", path: "~/.android/cache"),
                    .init(label: "Unity cache", path: "~/Library/Unity/cache"),
                    .init(label: "VS Code cache", path: "~/Library/Application Support/Code/Cache"),
                    .init(label: "VS Code cached data", path: "~/Library/Application Support/Code/CachedData"),
                    .init(label: "VS Code extension downloads", path: "~/Library/Application Support/Code/CachedExtensionVSIXs"),
                    .init(label: "Cursor cache", path: "~/Library/Application Support/Cursor/Cache"),
                    .init(label: "Cursor cached data", path: "~/Library/Application Support/Cursor/CachedData"),
                    .init(label: "Gradle wrapper downloads", path: "~/.gradle/wrapper/dists"),
                    .init(label: "pnpm store", path: "~/Library/pnpm/store"),
                    .init(label: "Bun cache", path: "~/.bun/install/cache"),
                    .init(label: "Cargo download cache", path: "~/.cargo/registry/cache"),
                    .init(label: "Dart & Flutter package cache", path: "~/.pub-cache/hosted"),
                    .init(label: "Carthage cache", path: "~/Library/Caches/org.carthage.CarthageKit"),
                    .init(label: "Expo native modules cache", path: "~/.expo/native-modules-cache"),
                    .init(label: "Expo schema cache", path: "~/.expo/schema-cache"),
                    .init(label: "Expo versions cache", path: "~/.expo/versions-cache"),
                ])],
                defaultOn: true, permanent: true
            ),
            JunkRule(
                id: "installers", title: "Old Installers",
                detail: "Disk images and installer packages sitting in Downloads. Ones older than two weeks are pre-selected. Moved to the Trash, so you can still get them back.",
                icon: "opticaldiscdrive",
                sources: [.files("~/Downloads", ["dmg", "pkg", "mpkg", "xip", "iso"])],
                defaultOn: true, permanent: false
            ),
            JunkRule(
                id: "mail", title: "Mail Attachments",
                detail: "Local copies of attachments you opened in Mail. The originals stay on your mail server.",
                icon: "paperclip",
                sources: [.children("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads")],
                defaultOn: false, permanent: false
            ),
            JunkRule(
                id: "archives", title: "Xcode Archives",
                detail: "Archived app builds. Only needed to re-symbolicate crash logs from old releases.",
                icon: "archivebox.fill", sources: [.children("~/Library/Developer/Xcode/Archives")],
                defaultOn: false, permanent: false
            ),
            JunkRule(
                id: "ios", title: "iOS Device Backups",
                detail: "Local iPhone and iPad backups. Remove only if your devices back up to iCloud.",
                icon: "iphone", sources: [.children("~/Library/Application Support/MobileSync/Backup")],
                defaultOn: false, permanent: false
            ),
            JunkRule(
                id: "trash", title: "Trash",
                detail: "Everything already in your Trash. Emptying it is permanent.",
                icon: "trash", sources: [.children("~/.Trash")],
                defaultOn: false, permanent: true, exclude: [".DS_Store", ".localized"]
            ),
        ]
    }

    static func scan(progress: @escaping @Sendable (String) -> Void) async -> [JunkCategory] {
        await withTaskGroup(of: (Int, JunkCategory).self) { group in
            for (i, rule) in rules.enumerated() {
                group.addTask { (i, scan(rule: rule, progress: progress)) }
            }
            var out: [(Int, JunkCategory)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func scan(rule: JunkRule, progress: @escaping @Sendable (String) -> Void) -> JunkCategory {
        let fm = FileManager.default
        var items: [JunkItem] = []
        var denied = false

        func add(_ url: URL, label: String, selected: Bool? = nil) {
            progress(Fmt.shortPath(url))
            let s = FileSizer.size(of: url)
            if s > 0 { items.append(JunkItem(url: url, label: label, size: s, selected: selected ?? rule.defaultOn)) }
        }

        for source in rule.sources {
            switch source {
            case .children(let p):
                let dir = URL(fileURLWithPath: p.expandingTilde)
                guard fm.fileExists(atPath: dir.path) else { continue }
                do {
                    let kids = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
                    let excluded = Set(rule.exclude.map { $0.lowercased() })
                    for k in kids where !excluded.contains(k.lastPathComponent.lowercased()) {
                        add(k, label: k.lastPathComponent)
                    }
                } catch {
                    denied = true
                }
            case .paths(let named):
                for n in named {
                    let url = URL(fileURLWithPath: n.path.expandingTilde)
                    if fm.fileExists(atPath: url.path) { add(url, label: n.label) }
                }
            case .simulators:
                items += Simulators.devices()
            case .simRuntimes:
                items += Simulators.runtimes()
            case .files(let p, let exts):
                let dir = URL(fileURLWithPath: p.expandingTilde)
                guard fm.fileExists(atPath: dir.path) else { continue }
                do {
                    let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
                    let kids = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                    // A download from this week may still be needed, so only older ones start ticked.
                    let recent = Date().addingTimeInterval(-14 * 86_400)
                    for k in kids where exts.contains(k.pathExtension.lowercased()) {
                        let v = try? k.resourceValues(forKeys: Set(keys))
                        let added = v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
                        add(k, label: k.lastPathComponent, selected: rule.defaultOn && added < recent)
                    }
                } catch {
                    denied = true
                }
            }
        }

        items.sort { $0.size > $1.size }
        return JunkCategory(
            id: rule.id, title: rule.title, detail: rule.detail, icon: rule.icon,
            permanent: rule.permanent, items: items, denied: denied
        )
    }
}

/// Reads Xcode's simulator inventory through `xcrun simctl`, so removal goes through Xcode's own tool.
enum Simulators {
    static var hasXcodeSimulators: Bool {
        FileManager.default.fileExists(atPath: "~/Library/Developer/CoreSimulator/Devices".expandingTilde)
            && FileManager.default.fileExists(atPath: "/usr/bin/xcrun")
    }

    private static func json(_ args: [String]) -> Any? {
        guard hasXcodeSimulators else { return nil }
        let r = Shell.exec("/usr/bin/xcrun", ["simctl"] + args)
        guard r.ok, let start = r.output.firstIndex(of: "{") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8))
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-2" → "iOS 17.2"
    static func runtimeName(_ key: String) -> String {
        guard let last = key.split(separator: ".").last else { return key }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return String(last) }
        return "\(os) " + parts.dropFirst().joined(separator: ".")
    }

    static func devices() -> [JunkItem] {
        guard let root = json(["list", "devices", "--json"]) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [JunkItem] = []
        for (runtime, devices) in byRuntime {
            for d in devices {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String,
                      let dataPath = d["dataPath"] as? String else { continue }
                let folder = URL(fileURLWithPath: dataPath).deletingLastPathComponent()
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                let available = d["isAvailable"] as? Bool ?? true
                let size = FileSizer.size(of: folder)
                let os = runtimeName(runtime)
                if !available {
                    out.append(JunkItem(url: folder, label: "\(name) · \(os) (no longer installed)", size: size,
                                        selected: true, removal: ["/usr/bin/xcrun", "simctl", "delete", udid]))
                } else if size > 300_000_000 {
                    // Still usable: offer to erase its apps and data, keeping the simulator itself.
                    out.append(JunkItem(url: URL(fileURLWithPath: dataPath), label: "\(name) · \(os) (erase apps & data)", size: size,
                                        selected: false, removal: ["/usr/bin/xcrun", "simctl", "erase", udid]))
                }
            }
        }
        return out
    }

    static func runtimes() -> [JunkItem] {
        guard let root = json(["runtime", "list", "-j"]) as? [String: [String: Any]] else { return [] }
        struct RT { let id: String; let platform: String; let version: String; let size: Int64; let path: String; let lastUsed: Date? }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var list: [RT] = []
        for (_, r) in root {
            guard (r["deletable"] as? Bool) ?? true,
                  let id = r["identifier"] as? String,
                  let version = r["version"] as? String else { continue }
            let platformID = r["platformIdentifier"] as? String ?? ""
            let platform = platformID.contains("iphone") ? "iOS"
                : platformID.contains("watch") ? "watchOS"
                : platformID.contains("appletv") ? "tvOS"
                : platformID.contains("xr") ? "visionOS" : "Simulator"
            let size = (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            let lastUsed = (r["lastUsedAt"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            list.append(RT(id: id, platform: platform, version: version, size: size,
                           path: r["path"] as? String ?? "/Library/Developer/CoreSimulator/Volumes/\(id)", lastUsed: lastUsed))
        }
        var newest: [String: String] = [:]
        for rt in list where newest[rt.platform].map({ rt.version.compare($0, options: .numeric) == .orderedDescending }) ?? true {
            newest[rt.platform] = rt.version
        }
        let stale = Date().addingTimeInterval(-90 * 86_400)
        return list.map { rt in
            let isNewest = newest[rt.platform] == rt.version
            let unused = (rt.lastUsed ?? .distantPast) < stale
            let note = isNewest ? "newest" : (rt.lastUsed.map { "last used \(Fmt.ago($0))" } ?? "never used")
            return JunkItem(url: URL(fileURLWithPath: rt.path), label: "\(rt.platform) \(rt.version) simulator (\(note))",
                            size: rt.size, selected: !isNewest && unused,
                            removal: ["/usr/bin/xcrun", "simctl", "runtime", "delete", rt.id])
        }
    }

    /// Runs each item's simctl command. Returns what was freed and what failed.
    static func remove(_ items: [JunkItem]) -> Cleaner.Result {
        var r = Cleaner.Result()
        var records: [CleanRecord] = []
        for item in items {
            guard let cmd = item.removal, let tool = cmd.first else { continue }
            let res = Shell.exec(tool, Array(cmd.dropFirst()))
            if res.ok {
                r.freed += item.size
                r.removed += 1
                records.append(CleanRecord(date: Date(), source: "System Junk", path: item.label, size: item.size, outcome: "Deleted"))
            } else {
                let reason = res.output.contains("Booted") || res.output.contains("state: Booted")
                    ? "This simulator is running. Shut it down in Xcode and try again."
                    : res.output.split(separator: "\n").first.map(String.init) ?? "simctl couldn't remove it."
                r.failures.append(.init(url: item.url, remaining: item.size, reason: reason, permanent: true))
                records.append(CleanRecord(date: Date(), source: "System Junk", path: item.label, size: item.size, outcome: "Skipped: \(reason)"))
            }
        }
        CleanLog.append(records)
        return r
    }
}

@MainActor
@Observable
final class JunkModel {
    var phase: Phase = .idle
    var categories: [JunkCategory] = []
    var focusedID: String?
    var currentPath = ""
    var lastResult: Cleaner.Result?

    var totalFound: Int64 { categories.reduce(0) { $0 + $1.totalSize } }
    var totalSelected: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }
    var selectedCount: Int { categories.reduce(0) { $0 + $1.selectedCount } }

    var focused: JunkCategory? {
        categories.first { $0.id == focusedID } ?? categories.first
    }

    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        SoundFX.shared.play(.scanStart)
        currentPath = ""
        let started = Date()
        let cats = await JunkScanner.scan { [weak self] p in
            Task { @MainActor in self?.currentPath = p }
        }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 1.4 { try? await Task.sleep(for: .seconds(1.4 - elapsed)) }
        // Show categories with findings first, keep empty-but-denied ones so the user knows why.
        categories = cats.filter { !$0.items.isEmpty || $0.denied }
        focusedID = categories.first(where: { !$0.items.isEmpty })?.id ?? categories.first?.id
        phase = .results
        SoundFX.shared.play(.scanDone)
    }

    func clean() async {
        let safe = UserDefaults.standard.bool(forKey: "safeMode")
        var jobs: [Cleaner.Job] = []
        var commands: [JunkItem] = []
        for c in categories {
            let permanent = c.id == "trash" ? true : (c.permanent && !safe)
            for i in c.items where i.selected {
                if i.removal != nil { commands.append(i) } else { jobs.append(.init(url: i.url, size: i.size, permanent: permanent)) }
            }
        }
        guard !jobs.isEmpty || !commands.isEmpty else { return }
        phase = .cleaning
        let started = Date()
        var result = await Task.detached(priority: .userInitiated) { [jobs] in Cleaner.remove(jobs, source: "System Junk") }.value
        if !commands.isEmpty {
            let sim = await Task.detached(priority: .userInitiated) { [commands] in Simulators.remove(commands) }.value
            result.freed += sim.freed
            result.removed += sim.removed
            result.failures += sim.failures
            let done = Set(commands.map(\.url)).subtracting(sim.failures.map(\.url))
            for c in categories.indices { categories[c].items.removeAll { done.contains($0.url) } }
        }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 1.2 { try? await Task.sleep(for: .seconds(1.2 - elapsed)) }
        lastResult = result
        Lifetime.record(result)
        for c in categories.indices {
            categories[c].items.removeAll { $0.selected && !FileManager.default.fileExists(atPath: $0.url.path) }
        }
        phase = .done
        SoundFX.shared.play(result.failures.isEmpty ? .clean : .warn)
    }

    var removingLeftovers = false

    /// Deletes whatever macOS refused, using the admin password prompt.
    func removeLeftovers() async {
        guard var r = lastResult, !r.failures.isEmpty else { return }
        removingLeftovers = true
        // Only items that were meant to be deleted get the admin delete. Items meant for the
        // Trash go through Finder, which asks for the password itself and keeps them recoverable.
        // Simulator items are removed with simctl; never force-delete them with admin rights.
        let urls = r.failures.filter(\.permanent).map(\.url).filter { !$0.path.contains("/CoreSimulator/") }
        let toTrash = r.failures.filter { !$0.permanent }.map(\.url)
        guard !urls.isEmpty || !toTrash.isEmpty else { removingLeftovers = false; return }
        _ = await Task.detached {
            _ = Cleaner.adminRemove(urls)
            for u in toTrash { _ = Cleaner.finderTrash(u) }
        }.value
        var still: [Cleaner.Failure] = []
        for f in r.failures {
            if FileManager.default.fileExists(atPath: f.url.path) {
                still.append(f)
            } else {
                r.freed += f.remaining
                r.removed += 1
                Lifetime.add(f.remaining)
            }
        }
        r.failures = still
        lastResult = r
        SoundFX.shared.play(still.isEmpty ? .clean : .warn)
        for c in categories.indices {
            categories[c].items.removeAll { $0.selected && !FileManager.default.fileExists(atPath: $0.url.path) }
        }
        removingLeftovers = false
    }

    func reset() {
        phase = .idle
        categories = []
        lastResult = nil
    }

    func toggleCategory(_ id: String) {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { return }
        let newValue = categories[i].checkState != .on
        for j in categories[i].items.indices { categories[i].items[j].selected = newValue }
        SoundFX.shared.play(.tap)
    }

    func toggleItem(category id: String, item: URL) {
        guard let i = categories.firstIndex(where: { $0.id == id }),
              let j = categories[i].items.firstIndex(where: { $0.url == item }) else { return }
        categories[i].items[j].selected.toggle()
        SoundFX.shared.play(.tap)
    }
}
