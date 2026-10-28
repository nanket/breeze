import SwiftUI

/// A kind of rebuildable project folder, and how to get it back.
struct ArtifactKind: Hashable, Sendable {
    let id: String
    let title: String
    let icon: String
    let hue: Double
    let restore: String
}

struct DevArtifact: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let project: URL
    let kind: ArtifactKind
    var size: Int64
    let lastTouched: Date?
    var selected: Bool

    var isStale: Bool {
        guard let lastTouched else { return true }
        return Date().timeIntervalSince(lastTouched) > 30 * 86_400
    }
}

enum DevScanner {
    static let node = ArtifactKind(id: "node", title: "node_modules", icon: "shippingbox.fill", hue: 0.33, restore: "npm install")
    static let unity = ArtifactKind(id: "unity", title: "Unity Library", icon: "cube.fill", hue: 0.0, restore: "Unity rebuilds it when you open the project")
    static let pods = ArtifactKind(id: "pods", title: "CocoaPods", icon: "leaf.fill", hue: 0.03, restore: "pod install")
    static let gradle = ArtifactKind(id: "gradle", title: "Gradle build", icon: "hammer.fill", hue: 0.55, restore: "./gradlew build")
    static let flutter = ArtifactKind(id: "flutter", title: "Flutter build", icon: "bird.fill", hue: 0.58, restore: "flutter pub get && flutter build")
    static let dartTool = ArtifactKind(id: "dart", title: ".dart_tool", icon: "bird", hue: 0.6, restore: "flutter pub get")
    static let venv = ArtifactKind(id: "venv", title: "Python venv", icon: "terminal.fill", hue: 0.15, restore: "python -m venv .venv && pip install -r requirements.txt")
    static let rust = ArtifactKind(id: "rust", title: "Rust target", icon: "gearshape.2.fill", hue: 0.07, restore: "cargo build")
    static let swiftpm = ArtifactKind(id: "swiftpm", title: "SwiftPM .build", icon: "swift", hue: 0.04, restore: "swift build")
    static let next = ArtifactKind(id: "next", title: "Next.js cache", icon: "n.circle.fill", hue: 0.75, restore: "next build")
    static let gradleCache = ArtifactKind(id: "gradlecache", title: "Project .gradle", icon: "hammer", hue: 0.52, restore: "Rebuilt on the next Gradle run")

    static let all: [ArtifactKind] = [node, unity, pods, gradle, flutter, dartTool, venv, rust, swiftpm, next, gradleCache]

    /// Folders never worth walking into.
    static let skipNames: Set<String> = [".git", ".svn", ".hg", ".Trash", ".npm", ".cache", ".cocoapods", ".gradle-home", "Photos Library.photoslibrary"]

    static func classify(_ dir: URL, name: String, fm: FileManager) -> ArtifactKind? {
        let parent = dir.deletingLastPathComponent()
        func has(_ f: String) -> Bool { fm.fileExists(atPath: parent.appendingPathComponent(f).path) }
        switch name {
        case "node_modules": return has("package.json") ? node : nil
        case "Library": return has("Assets") && has("ProjectSettings") ? unity : nil
        case "Pods": return has("Podfile") ? pods : nil
        case ".dart_tool": return has("pubspec.yaml") ? dartTool : nil
        case "build":
            if has("pubspec.yaml") { return flutter }
            if has("build.gradle") || has("build.gradle.kts") || has("settings.gradle") || has("settings.gradle.kts") { return gradle }
            return nil
        case ".gradle": return has("settings.gradle") || has("settings.gradle.kts") || has("build.gradle") || has("build.gradle.kts") ? gradleCache : nil
        case ".venv", "venv", "env": return fm.fileExists(atPath: dir.appendingPathComponent("pyvenv.cfg").path) ? venv : nil
        case "target": return has("Cargo.toml") ? rust : nil
        case ".build": return has("Package.swift") ? swiftpm : nil
        case ".next": return has("package.json") ? next : nil
        default: return nil
        }
    }

    /// Walks the home folder (minus ~/Library) looking for project build folders.
    static func scan(progress: @escaping @Sendable (String) -> Void) -> [DevArtifact] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var found: [(URL, ArtifactKind)] = []
        let tops = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: keys, options: [])) ?? []
        var n = 0
        for top in tops {
            let name = top.lastPathComponent
            if name == "Library" || skipNames.contains(name) { continue }
            // Hidden folders at the top of home are tool caches, already covered by System Junk.
            if name.hasPrefix(".") { continue }
            guard (try? top.resourceValues(forKeys: Set(keys)))?.isDirectory == true else { continue }
            guard let e = fm.enumerator(at: top, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                if Task.isCancelled { return [] }
                if e.level > 9 { e.skipDescendants(); continue }
                let v = try? u.resourceValues(forKeys: Set(keys))
                guard v?.isDirectory == true, v?.isSymbolicLink != true else { continue }
                let dname = u.lastPathComponent
                if skipNames.contains(dname) { e.skipDescendants(); continue }
                n += 1
                if n % 300 == 0 { progress(Fmt.shortPath(u)) }
                if let kind = classify(u, name: dname, fm: fm) {
                    found.append((u, kind))
                    e.skipDescendants()
                } else if dname == "node_modules" {
                    e.skipDescendants()   // nested deps without a package.json beside them
                }
            }
        }
        return found.map { url, kind in
            let project = url.deletingLastPathComponent()
            progress(Fmt.shortPath(url))
            let touched = lastTouched(project, ignoring: url.lastPathComponent)
            let a = DevArtifact(url: url, project: project, kind: kind, size: FileSizer.size(of: url), lastTouched: touched, selected: false)
            var b = a
            // A venv can hold packages installed by hand, so it's never pre-selected.
            b.selected = a.isStale && kind != venv
            return b
        }
        .filter { $0.size > 1_048_576 }
        .sorted { $0.size > $1.size }
    }

    /// Build folders skipped when measuring a project's activity.
    static let buildNames: Set<String> = ["node_modules", "Pods", "build", "target", "venv", "env", "Library", "DerivedData", "dist", "out"]

    /// Most recent change anywhere in the project's own files (not its build folders),
    /// including git activity. Stops after 20,000 files so huge projects stay fast.
    static func lastTouched(_ project: URL, ignoring: String) -> Date? {
        let fm = FileManager.default
        var latest: Date?
        func note(_ d: Date?) { if let d, d > (latest ?? .distantPast) { latest = d } }
        for f in [".git/index", ".git/HEAD", ".git/logs/HEAD", ".git/FETCH_HEAD"] {
            note((try? fm.attributesOfItem(atPath: project.appendingPathComponent(f).path))?[.modificationDate] as? Date)
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let e = fm.enumerator(at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { return latest }
        var seen = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                let name = u.lastPathComponent
                if name == ignoring || buildNames.contains(name) || e.level > 8 { e.skipDescendants(); continue }
            }
            note(v?.contentModificationDate)
            seen += 1
            if seen >= 20_000 { break }
        }
        return latest
    }
}

@MainActor
@Observable
final class DevCleanupModel {
    var phase: Phase = .idle
    var items: [DevArtifact] = []
    var kindFilter: String?
    var currentPath = ""
    var lastResult: Cleaner.Result?
    private var task: Task<[DevArtifact], Never>?

    var visible: [DevArtifact] { items.filter { kindFilter == nil || $0.kind.id == kindFilter } }
    var selected: [DevArtifact] { items.filter(\.selected) }
    var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var staleSize: Int64 { items.filter(\.isStale).reduce(0) { $0 + $1.size } }
    var kinds: [ArtifactKind] { DevScanner.all.filter { k in items.contains { $0.kind == k } } }

    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        SoundFX.shared.play(.scanStart)
        currentPath = ""
        kindFilter = nil
        let t = Task.detached(priority: .userInitiated) { [weak self] in
            DevScanner.scan { p in Task { @MainActor in self?.currentPath = p } }
        }
        task = t
        items = await t.value
        withAnimation(.spring(response: 0.5)) { phase = .results }
        SoundFX.shared.play(.scanDone)
    }

    func stop() { task?.cancel() }

    func toggle(_ id: URL) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].selected.toggle() }
        SoundFX.shared.play(.tap)
    }

    func selectStale() {
        for i in items.indices { items[i].selected = items[i].isStale }
        SoundFX.shared.play(.tap)
    }

    func clean() async {
        let safe = UserDefaults.standard.bool(forKey: "safeMode")
        // Build folders come back with one command, so they're deleted. A venv may not, so it goes to the Trash.
        let jobs = selected.map { Cleaner.Job(url: $0.url, size: $0.size, permanent: !safe && $0.kind != DevScanner.venv) }
        guard !jobs.isEmpty else { return }
        phase = .cleaning
        let result = await Task.detached { Cleaner.remove(jobs, source: "Dev Cleanup") }.value
        try? await Task.sleep(for: .seconds(0.8))
        lastResult = result
        Lifetime.record(result)
        withAnimation { items.removeAll { $0.selected && !FileManager.default.fileExists(atPath: $0.url.path) } }
        phase = .done
        SoundFX.shared.play(result.failures.isEmpty ? .clean : .warn)
    }
}
