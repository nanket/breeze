import SwiftUI

enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case all = "All", video = "Videos", archive = "Archives", diskImage = "Disk Images",
         audio = "Audio", image = "Images", document = "Documents", other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .video: "film"
        case .archive: "doc.zipper"
        case .diskImage: "opticaldiscdrive"
        case .audio: "waveform"
        case .image: "photo"
        case .document: "doc.richtext"
        case .other: "doc"
        }
    }

    static func of(_ ext: String) -> FileKind {
        switch ext.lowercased() {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mpg", "mpeg", "wmv", "flv", "prores", "braw": .video
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "jar", "aar", "apk", "ipa", "unitypackage": .archive
        case "dmg", "iso", "img", "pkg", "mpkg", "xip", "vmdk", "qcow2", "vdi", "sparseimage", "sparsebundle": .diskImage
        case "mp3", "wav", "aiff", "aif", "flac", "m4a", "aac", "ogg", "caf", "logicx": .audio
        case "jpg", "jpeg", "png", "heic", "tiff", "tif", "psd", "raw", "cr2", "nef", "arw", "dng", "exr", "hdr", "blend", "fbx", "obj", "usdz": .image
        case "pdf", "doc", "docx", "ppt", "pptx", "key", "pages", "numbers", "xls", "xlsx", "csv", "epub", "txt", "json", "sql", "db", "sqlite": .document
        default: .other
        }
    }
}

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age", sixMonths = "6+ months", year = "1+ year", twoYears = "2+ years"
    var id: String { rawValue }

    func matches(_ date: Date?) -> Bool {
        guard self != .any else { return true }
        guard let date else { return true }
        let days: Double = switch self {
        case .any: 0
        case .sixMonths: 182
        case .year: 365
        case .twoYears: 730
        }
        return Date().timeIntervalSince(date) > days * 86_400
    }
}

struct LargeFile: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let lastUsed: Date?
    let kind: FileKind
    var selected = false
}

enum LargeFileScanner {
    static let skipTop: Set<String> = ["Library", "Applications"]

    static func scan(minSize: Int64, progress: @escaping @Sendable (String, Int) -> Void) -> [LargeFile] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
        ]
        let keySet = Set(keys)
        var found: [(URL, Int64, Date?)] = []
        var count = 0

        func consider(_ u: URL) {
            guard let v = try? u.resourceValues(forKeys: keySet),
                  v.isRegularFile == true, v.isSymbolicLink != true else { return }
            let s = FileSizer.allocated(v)
            if s >= minSize { found.append((u, s, v.contentModificationDate)) }
        }

        guard let top = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }

        for entry in top where !skipTop.contains(entry.lastPathComponent) {
            if Task.isCancelled { break }
            let v = try? entry.resourceValues(forKeys: keySet)
            if v?.isRegularFile == true { consider(entry); continue }
            guard let e = fm.enumerator(
                at: entry, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let u as URL in e {
                count += 1
                if count % 400 == 0 {
                    if Task.isCancelled { break }
                    progress(Fmt.shortPath(u), count)
                }
                consider(u)
            }
        }

        return found
            .sorted { $0.1 > $1.1 }
            .map { url, size, modified in
                let used = Spotlight.lastUsed(url) ?? modified
                return LargeFile(url: url, size: size, lastUsed: used, kind: .of(url.pathExtension))
            }
    }
}

@MainActor
@Observable
final class LargeFilesModel {
    static let sizeOptions: [Int64] = [50, 100, 250, 500, 1024].map { Int64($0) * 1_048_576 }

    var phase: Phase = .idle
    var files: [LargeFile] = []
    var minSize: Int64 = 100 * 1_048_576
    var kind: FileKind = .all
    var age: AgeFilter = .any
    var scanned = 0
    var currentPath = ""
    var lastResult: Cleaner.Result?
    private var task: Task<[LargeFile], Never>?

    var visible: [LargeFile] {
        files.filter { (kind == .all || $0.kind == kind) && age.matches($0.lastUsed) }
    }

    var selected: [LargeFile] { files.filter(\.selected) }
    var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    func count(of k: FileKind) -> Int {
        k == .all ? files.count : files.reduce(0) { $0 + ($1.kind == k ? 1 : 0) }
    }

    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        SoundFX.shared.play(.scanStart)
        scanned = 0
        currentPath = ""
        let min = minSize
        let t = Task.detached(priority: .userInitiated) { [weak self] in
            LargeFileScanner.scan(minSize: min) { path, n in
                Task { @MainActor in
                    self?.currentPath = path
                    self?.scanned = n
                }
            }
        }
        task = t
        let result = await t.value
        files = result
        phase = .results
        SoundFX.shared.play(.scanDone)
    }

    func stop() { task?.cancel() }

    func toggle(_ id: URL) {
        if let i = files.firstIndex(where: { $0.id == id }) { files[i].selected.toggle() }
        SoundFX.shared.play(.tap)
    }

    var visibleCheckState: CheckState {
        let v = visible
        let n = v.filter(\.selected).count
        if n == 0 { return .off }
        return n == v.count ? .on : .mixed
    }

    func toggleAllVisible() {
        let ids = Set(visible.map(\.id))
        let newValue = visibleCheckState != .on
        for i in files.indices where ids.contains(files[i].id) { files[i].selected = newValue }
        SoundFX.shared.play(.tap)
    }

    func trashSelected() async {
        let jobs = selected.map { Cleaner.Job(url: $0.url, size: $0.size, permanent: false) }
        guard !jobs.isEmpty else { return }
        phase = .cleaning
        let result = await Task.detached { Cleaner.remove(jobs, source: "Large Files") }.value
        try? await Task.sleep(for: .seconds(0.8))
        lastResult = result
        Lifetime.record(result)
        SoundFX.shared.play(result.failures.isEmpty ? .clean : .warn)
        files.removeAll { $0.selected && !FileManager.default.fileExists(atPath: $0.url.path) }
        phase = .done
    }
}
