import SwiftUI

enum OrganizeMode: String, CaseIterable, Identifiable {
    case type = "By Type", date = "By Month"
    var id: String { rawValue }
    var icon: String { self == .type ? "square.grid.2x2" : "calendar" }
}

struct FileGroup: Identifiable, Hashable {
    var id: String { folder }
    let folder: String
    let icon: String
    let hue: Double
    var files: [URL]
    var size: Int64
}

struct MoveRecord: Codable, Hashable {
    let from: String
    let to: String
}

enum Organizer {
    struct Kind { let folder: String; let icon: String; let hue: Double; let exts: Set<String> }

    static let kinds: [Kind] = [
        Kind(folder: "Images", icon: "photo", hue: 0.33, exts: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "raw", "cr2", "nef", "arw", "dng", "avif", "ico"]),
        Kind(folder: "Videos", icon: "film", hue: 0.62, exts: ["mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg"]),
        Kind(folder: "Audio", icon: "waveform", hue: 0.92, exts: ["mp3", "wav", "aiff", "aif", "flac", "m4a", "aac", "ogg", "caf", "opus"]),
        Kind(folder: "PDFs", icon: "doc.richtext", hue: 0.0, exts: ["pdf"]),
        Kind(folder: "Documents", icon: "doc.text", hue: 0.58, exts: ["doc", "docx", "pages", "txt", "rtf", "md", "odt", "epub", "key", "ppt", "pptx", "numbers", "xls", "xlsx", "csv", "tsv"]),
        Kind(folder: "Archives", icon: "doc.zipper", hue: 0.1, exts: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"]),
        Kind(folder: "Installers", icon: "opticaldiscdrive", hue: 0.75, exts: ["dmg", "pkg", "mpkg", "iso", "xip", "app"]),
        Kind(folder: "Code", icon: "chevron.left.forwardslash.chevron.right", hue: 0.47, exts: ["swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "m", "json", "yml", "yaml", "toml", "xml", "html", "css", "sh", "sql", "ipynb", "dart"]),
        Kind(folder: "Design", icon: "paintpalette", hue: 0.82, exts: ["psd", "ai", "fig", "sketch", "xd", "blend", "fbx", "obj", "usdz", "glb", "gltf", "afdesign", "afphoto"]),
        Kind(folder: "Fonts", icon: "textformat", hue: 0.15, exts: ["ttf", "otf", "woff", "woff2"]),
    ]

    static let other = Kind(folder: "Other", icon: "doc", hue: 0.6, exts: [])
    static let skip: Set<String> = [".DS_Store", ".localized"]
    static let partial: Set<String> = ["crdownload", "download", "part", "partial"]

    static func kind(for url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        return kinds.first { $0.exts.contains(ext) } ?? other
    }

    /// Loose files in the folder (sub-folders are left alone, except .app bundles).
    static func looseFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.filter { u in
            guard !skip.contains(u.lastPathComponent), !partial.contains(u.pathExtension.lowercased()) else { return false }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { return false }
            if v?.isDirectory == true { return u.pathExtension.lowercased() == "app" }
            return true
        }
    }

    static func plan(_ folder: URL, mode: OrganizeMode) -> [FileGroup] {
        let files = looseFiles(in: folder)
        var groups: [String: FileGroup] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM MMMM"
        for f in files {
            let size = FileSizer.size(of: f)
            switch mode {
            case .type:
                let k = kind(for: f)
                groups[k.folder, default: FileGroup(folder: k.folder, icon: k.icon, hue: k.hue, files: [], size: 0)].files.append(f)
                groups[k.folder]?.size += size
            case .date:
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let name = fmt.string(from: d)
                let month = Calendar.current.component(.month, from: d)
                groups[name, default: FileGroup(folder: name, icon: "calendar", hue: Double(month) / 12.0, files: [], size: 0)].files.append(f)
                groups[name]?.size += size
            }
        }
        let list = Array(groups.values)
        switch mode {
        case .type: return list.sorted { $0.files.count > $1.files.count }
        case .date: return list.sorted { $0.folder > $1.folder }
        }
    }

    /// Moves every file into its group's sub-folder. Never overwrites: clashing names get " 2", " 3"…
    static func apply(_ groups: [FileGroup], in folder: URL) -> (moved: [MoveRecord], failed: Int) {
        let fm = FileManager.default
        var log: [MoveRecord] = []
        var failed = 0
        for g in groups {
            let dest = folder.appendingPathComponent(g.folder, isDirectory: true)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for f in g.files {
                let target = uniqueURL(dest.appendingPathComponent(f.lastPathComponent))
                do {
                    try fm.moveItem(at: f, to: target)
                    log.append(MoveRecord(from: f.path, to: target.path))
                } catch {
                    failed += 1
                }
            }
        }
        return (log, failed)
    }

    /// Puts every file back where it was and removes the folders Organizer created if they're now empty.
    static func undo(_ log: [MoveRecord]) -> Int {
        let fm = FileManager.default
        var restored = 0
        var touched = Set<String>()
        for r in log.reversed() {
            let to = URL(fileURLWithPath: r.to)
            let from = uniqueURL(URL(fileURLWithPath: r.from))
            if (try? fm.moveItem(at: to, to: from)) != nil {
                restored += 1
                touched.insert(to.deletingLastPathComponent().path)
            }
        }
        for dir in touched {
            let rest = (try? fm.contentsOfDirectory(atPath: dir))?.filter { $0 != ".DS_Store" } ?? ["?"]
            if rest.isEmpty { try? fm.removeItem(atPath: dir) }
        }
        return restored
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

@MainActor
@Observable
final class OrganizerModel {
    var folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    var mode: OrganizeMode = .type
    var groups: [FileGroup] = []
    var excluded: Set<String> = []
    var phase: Phase = .idle
    var movedCount = 0
    var failedCount = 0
    var undoneCount: Int?
    private var lastLog: [MoveRecord] = []

    var canUndo: Bool { !lastLog.isEmpty }
    var active: [FileGroup] { groups.filter { !excluded.contains($0.folder) } }
    var fileCount: Int { active.reduce(0) { $0 + $1.files.count } }
    var totalSize: Int64 { active.reduce(0) { $0 + $1.size } }

    var folderName: String {
        folder.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : folder.lastPathComponent
    }

    func preview() async {
        phase = .scanning
        SoundFX.shared.play(.scanStart)
        excluded = []
        undoneCount = nil
        let f = folder, m = mode
        let started = Date()
        groups = await Task.detached(priority: .userInitiated) { Organizer.plan(f, mode: m) }.value
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 0.9 { try? await Task.sleep(for: .seconds(0.9 - elapsed)) }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { phase = .results }
        SoundFX.shared.play(.scanDone)
    }

    func toggle(_ g: FileGroup) {
        if excluded.contains(g.folder) { excluded.remove(g.folder) } else { excluded.insert(g.folder) }
        SoundFX.shared.play(.tap)
    }

    func organize() async {
        let chosen = active
        guard !chosen.isEmpty else { return }
        phase = .cleaning
        let f = folder
        let result = await Task.detached { Organizer.apply(chosen, in: f) }.value
        try? await Task.sleep(for: .seconds(0.6))
        lastLog = result.moved
        movedCount = result.moved.count
        failedCount = result.failed
        withAnimation(.spring(response: 0.5)) { phase = .done }
        SoundFX.shared.play(.clean)
    }

    func undo() async {
        let log = lastLog
        let n = await Task.detached { Organizer.undo(log) }.value
        lastLog = []
        undoneCount = n
        SoundFX.shared.play(.drill)
    }

    func reset() {
        withAnimation { phase = .idle }
        groups = []
    }
}
