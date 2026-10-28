import Foundation
import AppKit
import CoreServices

// MARK: - Formatting

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    /// RAM uses binary units, so 36 GB of memory reads as "36 GB".
    static func memory(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .memory)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func ago(_ date: Date?) -> String {
        guard let date else { return "Never opened" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    static func uptime(_ t: TimeInterval) -> String {
        let days = Int(t) / 86_400
        let hours = (Int(t) % 86_400) / 3600
        let mins = (Int(t) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}

// MARK: - Disk usage

enum FileSizer {
    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Mount points whose contents are already counted elsewhere (APFS firmlinks, other volumes).
    static let skipPaths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/private/var/vm"]

    static func allocated(_ v: URLResourceValues?) -> Int64 {
        guard let v else { return 0 }
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    /// Bytes on disk for a file or a whole folder tree. Never follows symlinks.
    /// Cooperatively stops when the surrounding Task is cancelled.
    static func size(of url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: keys)
        if v?.isSymbolicLink == true { return 0 }
        guard v?.isDirectory == true else { return allocated(v) }

        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var n = 0
        for case let u as URL in e {
            n += 1
            if n & 1023 == 0 && Task.isCancelled { break }
            let rv = try? u.resourceValues(forKeys: keys)
            if rv?.isSymbolicLink == true { continue }
            if rv?.isDirectory == true {
                if skipPaths.contains(u.path) { e.skipDescendants() }
                continue
            }
            total += allocated(rv)
        }
        return total
    }
}

extension FileSizer {
    /// Total size plus a per-child breakdown, in one pass over the tree.
    /// Lets Space Lens draw a folder and its sub-folders without scanning twice.
    static func breakdown(of url: URL, keep: Int = 24) -> (total: Int64, children: [LensChild]) {
        let v = try? url.resourceValues(forKeys: keys)
        if v?.isSymbolicLink == true { return (0, []) }
        guard v?.isDirectory == true else { return (allocated(v), []) }
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return (0, []) }

        let base = url.path
        let prefixLen = base == "/" ? 1 : base.count + 1
        var total: Int64 = 0
        var sizes: [String: Int64] = [:]
        var dirs = Set<String>()
        var n = 0
        for case let u as URL in e {
            n += 1
            if n & 1023 == 0 && Task.isCancelled { break }
            let rv = try? u.resourceValues(forKeys: keys)
            if rv?.isSymbolicLink == true { continue }
            let path = u.path
            guard path.count > prefixLen else { continue }
            let rel = path.dropFirst(prefixLen)
            let first = String(rel.prefix { $0 != "/" })
            let nested = rel.count > first.count
            if rv?.isDirectory == true {
                if skipPaths.contains(path) { e.skipDescendants(); continue }
                if !nested { dirs.insert(first) }
                continue
            }
            if nested { dirs.insert(first) }
            let s = allocated(rv)
            total += s
            sizes[first, default: 0] += s
        }
        let kids = sizes
            .filter { $0.value > 0 && $0.key != ".DS_Store" }
            .map { LensChild(name: $0.key, size: $0.value, isDirectory: dirs.contains($0.key)) }
            .sorted { $0.size > $1.size }
        return (total, Array(kids.prefix(keep)))
    }
}

// MARK: - Removal

enum Cleaner {
    struct Job: Sendable {
        let url: URL
        let size: Int64
        let permanent: Bool
    }

    /// Something that couldn't be (fully) removed, with what's left of it and why.
    struct Failure: Sendable, Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let remaining: Int64
        let reason: String
        let permanent: Bool
    }

    struct Result: Sendable {
        var freed: Int64 = 0
        var removed = 0
        var trashed: Int64 = 0
        var failures: [Failure] = []

        var cleaned: Int64 { freed + trashed }
        var leftover: Int64 { failures.reduce(0) { $0 + $1.remaining } }
    }

    /// Moves items to the Trash (recoverable) or deletes them when `permanent`.
    /// If macOS refuses, permanent items are unlocked and removed piece by piece,
    /// and only the bytes that really disappeared are counted.
    static func remove(_ jobs: [Job], source: String = "Cleanup") -> Result {
        var r = Result()
        var log: [CleanRecord] = []
        let fm = FileManager.default
        func record(_ job: Job, _ outcome: String, _ size: Int64) {
            log.append(CleanRecord(date: Date(), source: source, path: job.url.path, size: size, outcome: outcome))
        }
        for job in jobs {
            guard exists(job.url) else { continue }
            if let reason = SafetyGuard.check(job.url, permanent: job.permanent) {
                r.failures.append(Failure(url: job.url, remaining: job.size, reason: reason, permanent: false))
                record(job, "Skipped: \(reason)", 0)
                continue
            }
            do {
                if job.permanent, case let keep = keptFolders(in: job.url), !keep.isEmpty {
                    removeKeeping(job.url, keep: keep)
                    let remaining = FileSizer.size(of: job.url)
                    r.freed += max(0, job.size - remaining)
                    record(job, "Deleted (kept IDE Local History)", max(0, job.size - remaining))
                } else if job.permanent {
                    try fm.removeItem(at: job.url)
                    r.freed += job.size
                    record(job, "Deleted", job.size)
                } else {
                    try fm.trashItem(at: job.url, resultingItemURL: nil)
                    r.trashed += job.size
                    record(job, "Moved to Trash", job.size)
                }
                r.removed += 1
            } catch {
                if job.permanent { forceRemove(job.url) }
                guard exists(job.url) else {
                    r.freed += job.size
                    r.removed += 1
                    record(job, "Deleted", job.size)
                    continue
                }
                let remaining = FileSizer.size(of: job.url)
                if job.permanent { r.freed += max(0, job.size - remaining) }
                let reason = describe(error)
                r.failures.append(Failure(url: job.url, remaining: remaining, reason: reason, permanent: job.permanent))
                record(job, "Skipped: \(reason)", max(0, job.size - remaining))
            }
        }
        CleanLog.append(log)
        return r
    }

    /// Folders that live inside caches but hold the user's own work: JetBrains and
    /// Android Studio keep Local History (snapshots of unsaved edits) in their cache folder.
    static let keepInside: Set<String> = ["LocalHistory"]

    /// Kept folders within a few levels of `url`. Empty for files and ordinary caches.
    static func keptFolders(in url: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            if keepInside.contains(u.lastPathComponent) { out.append(u); e.skipDescendants() }
            else if e.level >= 3 { e.skipDescendants() }
        }
        return out
    }

    /// Deletes everything inside `url` except the kept folders (and the folders leading to them).
    static func removeKeeping(_ url: URL, keep: [URL]) {
        let fm = FileManager.default
        let kept = keep.map { $0.standardizedFileURL.path }
        func walk(_ dir: URL) {
            let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
            for k in kids {
                let p = k.standardizedFileURL.path
                if kept.contains(p) { continue }
                if kept.contains(where: { $0.hasPrefix(p + "/") }) { walk(k); continue }
                if (try? fm.removeItem(at: k)) == nil { forceRemove(k) }
            }
        }
        walk(url)
    }

    /// Deletes what can be deleted inside `url`, deepest items first, clearing the
    /// "Locked" flag and restoring owner write permission along the way.
    static func forceRemove(_ url: URL) {
        let fm = FileManager.default
        var all: [URL] = []
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) {
            for case let u as URL in e { all.append(u) }
        }
        for u in all.reversed() {
            unlock(u)
            try? fm.removeItem(at: u)
        }
        unlock(url)
        try? fm.removeItem(at: url)
    }

    private static func unlock(_ u: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: u.path) else { return }
        var fix: [FileAttributeKey: Any] = [:]
        if (attrs[.immutable] as? Bool) == true { fix[.immutable] = false }
        if let p = (attrs[.posixPermissions] as? NSNumber)?.intValue {
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let wanted = p | (isDir ? 0o700 : 0o600)
            if wanted != p { fix[.posixPermissions] = wanted }
        }
        if !fix.isEmpty { try? fm.setAttributes(fix, ofItemAtPath: u.path) }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix: Int = (underlying?.domain == NSPOSIXErrorDomain) ? (underlying?.code ?? 0) : 0
        if posix == Int(EBUSY) { return "In use by another app" }
        if posix == Int(EPERM) || posix == Int(EACCES)
            || ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
            return "macOS blocked the delete (locked or protected)"
        }
        return ns.localizedDescription
    }

    /// Last resort for leftovers: unlock and delete with the user's admin password.
    static func adminRemove(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return true }
        // Only ever touch things inside the user's own home folder.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        guard urls.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(home) && $0.pathComponents.count > 4 && SafetyGuard.check($0, permanent: true) == nil }) else { return false }
        CleanLog.log("Admin removal requested for \(urls.count) item(s): " + urls.map(\.path).joined(separator: ", "))
        let cmd = urls.map { "/usr/bin/chflags -R nouchg \(Shell.quote($0.path)) ; /bin/rm -rf \(Shell.quote($0.path))" }.joined(separator: " ; ")
        return Shell.run(cmd, admin: true).ok
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || isBrokenLink(url)
    }

    private static func isBrokenLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Asks Finder to delete an item. Finder handles the admin password prompt
    /// for root-owned apps that FileManager can't move.
    static func finderTrash(_ url: URL) -> Bool {
        guard SafetyGuard.check(url, permanent: false) == nil else { return false }
        CleanLog.log("Finder trash: \(url.path)")
        let path = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Shell.osascript("tell application \"Finder\" to delete (POSIX file \"\(path)\" as alias)").ok
    }

    static func emptyTrashViaFinder() -> Bool {
        Shell.osascript("tell application \"Finder\" to empty trash").ok
    }
}

// MARK: - Shell

enum Shell {
    /// Single-quotes a string for zsh, so paths and labels can't break out of the command.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a zsh command. With `admin`, macOS shows its standard password prompt.
    @discardableResult
    static func run(_ command: String, admin: Bool = false) -> (ok: Bool, output: String) {
        if admin {
            let esc = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return osascript(
                "do shell script \"\(esc)\" with prompt \"Breeze needs your password to run maintenance tasks.\" with administrator privileges"
            )
        }
        return exec("/bin/zsh", ["-c", command])
    }

    @discardableResult
    static func osascript(_ source: String) -> (ok: Bool, output: String) {
        exec("/usr/bin/osascript", ["-e", source])
    }

    static func exec(_ tool: String, _ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Permissions & system helpers

enum Permissions {
    /// The TCC database is only readable by processes with Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let path = "/Library/Application Support/com.apple.TCC/TCC.db"
        if let fh = FileHandle(forReadingAtPath: path) {
            try? fh.close()
            return true
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Spotlight {
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

enum Finder {
    static func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let i = cache.object(forKey: key) { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(i, forKey: key)
        return i
    }
}

enum SysInfo {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Lifetime stats

/// Running total of space Breeze has freed, shown on the home screen.
enum Lifetime {
    static let key = "lifetimeCleanedBytes"

    static var total: Int64 { Int64(UserDefaults.standard.double(forKey: key)) }

    static func record(_ r: Cleaner.Result) { add(r.freed + r.trashed) }

    static func add(_ bytes: Int64) {
        guard bytes > 0 else { return }
        let d = UserDefaults.standard
        d.set(Double(total + bytes), forKey: key)
    }
}
