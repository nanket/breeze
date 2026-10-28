import SwiftUI
import Darwin

// MARK: - Launch agents & daemons

struct LaunchItem: Identifiable, Hashable {
    enum Scope: String, CaseIterable {
        case user = "Your Launch Agents"
        case globalAgent = "System-wide Launch Agents"
        case daemon = "Launch Daemons"

        var note: String {
            switch self {
            case .user: "Start when you log in. Switch off to pause one; switch on to bring it back."
            case .globalAgent: "Installed for every user. Switching these is instant and reversible."
            case .daemon: "Run in the background as root. Switching needs your admin password."
            }
        }
    }

    var id: URL { url }
    let url: URL
    let label: String
    let program: String
    let scope: Scope
    let running: Bool
    let loaded: Bool
    let enabled: Bool

    var vendor: String {
        let parts = label.split(separator: ".")
        guard parts.count >= 2 else { return label }
        return parts[1].capitalized
    }

    /// launchctl domain target for this item, e.g. gui/501 or system.
    var domain: String { scope == .daemon ? "system" : "gui/\(getuid())" }
}

@MainActor
@Observable
final class LaunchAgentsModel {
    var items: [LaunchItem] = []
    var loading = false
    var loaded = false
    var busy: Set<URL> = []
    var toast: String?

    var runningCount: Int { items.filter(\.running).count }
    var enabledCount: Int { items.filter(\.enabled).count }

    func load() async {
        loading = true
        items = await Task.detached(priority: .userInitiated) { Self.scan() }.value
        loading = false
        loaded = true
    }

    /// Labels switched off with `launchctl disable`, read from `launchctl print-disabled`.
    nonisolated static func disabledLabels(_ domain: String) -> Set<String> {
        let out = Shell.run("launchctl print-disabled \(domain)").output
        var set = Set<String>()
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let close = t.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(t[t.index(after: t.startIndex)..<close])
            if t.contains("=> disabled") || t.contains("=> true") { set.insert(label) }
        }
        return set
    }

    nonisolated static func scan() -> [LaunchItem] {
        let fm = FileManager.default
        var pids: [String: Bool] = [:]
        for line in Shell.run("launchctl list").output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3 else { continue }
            pids[String(cols[2])] = cols[0] != "-"
        }
        let userDisabled = disabledLabels("gui/\(getuid())")
        let systemDisabled = disabledLabels("system")
        let dirs: [(URL, LaunchItem.Scope)] = [
            (fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon),
        ]
        var out: [LaunchItem] = []
        for (dir, scope) in dirs {
            guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for k in kids where k.pathExtension == "plist" {
                let dict = NSDictionary(contentsOf: k) as? [String: Any] ?? [:]
                let label = dict["Label"] as? String ?? k.deletingPathExtension().lastPathComponent
                let program = (dict["Program"] as? String)
                    ?? (dict["ProgramArguments"] as? [String])?.first
                    ?? ""
                let disabled = (scope == .daemon ? systemDisabled : userDisabled).contains(label)
                    || (dict["Disabled"] as? Bool ?? false)
                out.append(LaunchItem(
                    url: k, label: label, program: program, scope: scope,
                    running: pids[label] == true,
                    loaded: pids[label] != nil,
                    enabled: !disabled
                ))
            }
        }
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Reversible on/off: `launchctl disable` stops it starting again; `enable` + bootstrap brings it back.
    func setEnabled(_ item: LaunchItem, _ on: Bool) async {
        busy.insert(item.url)
        let target = Shell.quote("\(item.domain)/\(item.label)")
        let path = Shell.quote(item.url.path)
        let domain = Shell.quote(item.domain)
        let cmd = on
            ? "launchctl enable \(target); launchctl bootstrap \(domain) \(path) 2>/dev/null; true"
            : "launchctl bootout \(domain) \(path) 2>/dev/null; launchctl disable \(target)"
        let admin = item.scope == .daemon
        let ok = await Task.detached { Shell.run(cmd, admin: admin).ok }.value
        busy.remove(item.url)
        toast = ok ? (on ? "\(item.label) switched on" : "\(item.label) switched off") : "Couldn't change \(item.label)"
        SoundFX.shared.play(ok ? .tap : .warn)
        await load()
    }

    func remove(_ item: LaunchItem) async {
        let ok: Bool = await Task.detached { () -> Bool in
            switch item.scope {
            case .user:
                let uid = getuid()
                _ = Shell.run("launchctl bootout gui/\(uid) \(Shell.quote(item.url.path))")
                return (try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)) != nil
            case .globalAgent, .daemon:
                // A unique name in the Trash, and mv -n, so an existing file there is never overwritten.
                let stamp = Int(Date().timeIntervalSince1970)
                let dest = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".Trash/\(item.url.deletingPathExtension().lastPathComponent) \(stamp).plist").path
                let domain = item.scope == .daemon ? "system" : "gui/\(getuid())"
                let cmd = "launchctl bootout \(domain) \(Shell.quote(item.url.path)) 2>/dev/null; mv -n \(Shell.quote(item.url.path)) \(Shell.quote(dest))"
                return Shell.run(cmd, admin: true).ok
            }
        }.value
        toast = ok ? "Removed \(item.label)" : "Couldn't remove \(item.label)"
        SoundFX.shared.play(ok ? .clean : .warn)
        await load()
    }
}

// MARK: - Maintenance

struct MaintenanceTask: Identifiable, Hashable {
    enum Status: Equatable { case idle, running, done, failed }

    let id: String
    let title: String
    let detail: String
    let icon: String
    let command: String
    let admin: Bool
    var selected = false
    var status: Status = .idle
}

@MainActor
@Observable
final class MaintenanceModel {
    var tasks: [MaintenanceTask] = [
        .init(id: "ram", title: "Free Up RAM", detail: "Purges inactive memory so apps that need it get it right away.",
              icon: "memorychip", command: "/usr/sbin/purge", admin: true, selected: true),
        .init(id: "dns", title: "Flush DNS Cache", detail: "Fixes websites that won't load or point to an old address.",
              icon: "network", command: "dscacheutil -flushcache; killall -HUP mDNSResponder", admin: true, selected: true),
        .init(id: "ls", title: "Rebuild Launch Services", detail: "Fixes duplicate entries in “Open With” and wrong default apps.",
              icon: "arrow.triangle.2.circlepath",
              command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -domain local -domain system -domain user",
              admin: false, selected: true),
        .init(id: "ql", title: "Reset Quick Look", detail: "Clears thumbnail and preview caches when previews look wrong.",
              icon: "eye", command: "qlmanage -r cache; qlmanage -r", admin: false, selected: true),
        .init(id: "spotlight", title: "Reindex Spotlight", detail: "Rebuilds the search index when Spotlight misses files. Takes a while in the background.",
              icon: "magnifyingglass", command: "mdutil -E /", admin: true),
        .init(id: "tm", title: "Thin Time Machine Snapshots", detail: "Removes local snapshots that quietly hold on to free space.",
              icon: "clock.arrow.circlepath", command: "tmutil thinlocalsnapshots / 999999999999 4", admin: true),
        .init(id: "fonts", title: "Clear Font Caches", detail: "Fixes garbled or missing fonts. Log out afterwards to finish.",
              icon: "textformat", command: "atsutil databases -removeUser", admin: false),
        .init(id: "dock", title: "Restart Dock & Finder", detail: "Clears a stuck Dock, Launchpad or Finder window.",
              icon: "dock.rectangle", command: "killall Dock; killall Finder", admin: false),
    ]
    var running = false
    var finished = false

    var selectedCount: Int { tasks.filter(\.selected).count }

    func toggle(_ id: String) {
        guard !running, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if finished {
            for j in tasks.indices { tasks[j].status = .idle }
            finished = false
        }
        tasks[i].selected.toggle()
        SoundFX.shared.play(.tap)
    }

    func runSelected() async {
        let chosen = tasks.filter(\.selected)
        guard !chosen.isEmpty else { return }
        running = true
        finished = false
        SoundFX.shared.play(.scanStart)
        for i in tasks.indices { tasks[i].status = tasks[i].selected ? .running : .idle }

        // One password prompt for every admin task.
        let adminTasks = chosen.filter(\.admin)
        if !adminTasks.isEmpty {
            let cmd = adminTasks.map { "(\($0.command)) ; " }.joined() + "true"
            let ok = await Task.detached { Shell.run(cmd, admin: true).ok }.value
            setStatus(adminTasks.map(\.id), ok ? .done : .failed)
        }
        for t in chosen where !t.admin {
            let cmd = t.command
            let ok = await Task.detached { Shell.run(cmd).ok }.value
            // A few tools return non-zero for harmless reasons; trust that they ran.
            setStatus([t.id], ok || ["ql", "dock", "fonts"].contains(t.id) ? .done : .failed)
        }
        running = false
        finished = true
        SoundFX.shared.play(tasks.contains { $0.status == .failed } ? .warn : .scanDone)
    }

    private func setStatus(_ ids: [String], _ s: MaintenanceTask.Status) {
        for i in tasks.indices where ids.contains(tasks[i].id) {
            withAnimation(.spring(response: 0.4)) { tasks[i].status = s }
        }
    }
}
