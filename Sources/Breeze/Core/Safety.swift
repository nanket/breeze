import Foundation
import AppKit

/// The last line of defence: every removal passes through here, whatever module asked for it.
enum SafetyGuard {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// Folders that are never removed themselves (their contents may be).
    static let protectedFolders: Set<String> = {
        let h = home
        var s: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/usr", "/bin", "/sbin", "/etc",
            "/var", "/private", "/opt", "/opt/homebrew", "/usr/local", "/Volumes", "/cores",
        ]
        for sub in [
            "", "Library", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
            "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Keychains", "Library/Developer",
            "Library/Developer/Xcode", "Library/Mobile Documents", "Library/CloudStorage", "Library/LaunchAgents",
            "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Applications", "Public",
            ".Trash", ".ssh", ".gnupg", ".config", ".local",
        ] {
            s.insert(sub.isEmpty ? h : "\(h)/\(sub)")
        }
        return s
    }()

    /// Places Breeze never reaches into at all.
    static let forbiddenPrefixes: [String] = [
        "/System/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/bin/", "/sbin/", "/private/var/db/",
        "\(home)/Library/Keychains/", "\(home)/.ssh/", "\(home)/.gnupg/",
    ]

    /// nil if the item may be removed, otherwise the reason it may not.
    static func check(_ url: URL, permanent: Bool) -> String? {
        let p = url.standardizedFileURL.path
        guard p.hasPrefix("/"), !p.contains("/../") else { return "Unusual path" }
        if protectedFolders.contains(p) { return "Protected folder" }
        if forbiddenPrefixes.contains(where: { p.hasPrefix($0) }) { return "Protected location" }
        // Anything outside your home folder only ever goes to the Trash (apps in /Applications).
        if permanent && !p.hasPrefix(home + "/") { return "Outside your home folder" }
        // Files synced with iCloud would vanish from every device: Trash only.
        if permanent && p.hasPrefix("\(home)/Library/Mobile Documents/") { return "iCloud Drive item" }
        return nil
    }
}

// MARK: - Cleaning history

struct CleanRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let source: String
    let path: String
    let size: Int64
    let outcome: String     // "Deleted", "Moved to Trash", or "Skipped: reason"
}

/// Append-only record of everything Breeze removed, kept on this Mac only.
enum CleanLog {
    static var historyURL: URL { AppConfig.supportFolder.appendingPathComponent("history.jsonl") }
    static var textLogURL: URL { AppConfig.logFolder.appendingPathComponent("breeze.log") }
    private static let lock = NSLock()

    static func append(_ records: [CleanRecord]) {
        guard !records.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var json = Data()
        var text = ""
        let stamp = ISO8601DateFormatter()
        for r in records {
            if let d = try? enc.encode(r) {
                json.append(d)
                json.append(0x0A)
            }
            text += "\(stamp.string(from: r.date))  [\(r.source)]  \(r.outcome)  \(Fmt.bytes(r.size))  \(r.path)\n"
        }
        write(json, to: historyURL)
        write(Data(text.utf8), to: textLogURL)
    }

    static func load(limit: Int = 3000) -> [CleanRecord] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A).suffix(limit)
        return lines.compactMap { try? dec.decode(CleanRecord.self, from: Data($0)) }.reversed()
    }

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        lock.lock()
        write(Data(line.utf8), to: textLogURL)
        lock.unlock()
    }

    private static func write(_ data: Data, to url: URL) {
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Crash reports

enum CrashReports {
    private static let lastCheckKey = "crashCheckedAt"

    /// A crash report for Breeze written since we last looked, if any.
    static func newReport() -> URL? {
        let d = UserDefaults.standard
        let since = Date(timeIntervalSince1970: d.double(forKey: lastCheckKey))
        d.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        guard since.timeIntervalSince1970 > 0 else { return nil }   // first launch: nothing to compare against
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(AppConfig.appName) }
            .compactMap { u -> (URL, Date)? in
                guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > since else { return nil }
                return (u, m)
            }
            .max { $0.1 < $1.1 }?.0
    }

    static func send(_ report: URL) {
        let subject = "\(AppConfig.appName) \(AppConfig.version) crash report"
        let body = "Hi! \(AppConfig.appName) quit unexpectedly. Please attach the file \"\(report.lastPathComponent)\" (it's shown in Finder) and tell us what you were doing.\n\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        Support.compose(subject: subject, body: body)
        Finder.reveal([report])
    }
}

enum Support {
    static func compose(subject: String, body: String) {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppConfig.supportEmail
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    static func contact() {
        compose(
            subject: "\(AppConfig.appName) \(AppConfig.version) support",
            body: "\n\n—\n\(AppConfig.appName) \(AppConfig.version) (\(AppConfig.build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
    }
}
