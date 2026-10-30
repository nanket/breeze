import SwiftUI
import AppKit
import Darwin
import IOKit

// MARK: - Rows

/// One line in the Running list: an app with its helpers, a developer runtime, or a project's processes.
struct RunningItem: Identifiable, Hashable {
    enum Kind: String {
        case simulators, simulator, vm, container, gradle, devProcess, app, process
    }

    /// Every stop is graceful: the tool's own shutdown command, or asking the app to quit.
    enum Stop: Hashable {
        case simctl([String])                                // device UDIDs
        case colima(String)                                  // profile
        case docker(id: String, host: String, database: Bool)
        case gradle(version: String, projectDir: URL?, pid: Int32, javaHome: String?)
        case utm(String)                                     // VM UUID
        case quitApp(Int32)                                  // NSRunningApplication pid
        case terminate([Int32])                              // SIGTERM, for a project's dev servers

        var command: String {
            switch self {
            case .simctl(let ids): ids.count == 1 ? "xcrun simctl shutdown \(ids[0])" : "xcrun simctl shutdown (\(ids.count) devices)"
            case .colima(let p): "colima stop -p \(p)"
            case .docker(let id, _, let db): db ? "docker stop -t 30 \(id)" : "docker stop \(id)"
            case .gradle: "gradle --stop"
            case .utm(let id): "utmctl stop --request \(id)"
            case .quitApp: "Quit"
            case .terminate(let pids): "kill -TERM " + pids.map(String.init).joined(separator: " ")
            }
        }
    }

    let id: String
    let kind: Kind
    var name: String
    var detail: String
    var project: String?
    var projectURL: URL?
    var memory: Int64 = 0          // physical footprint, bytes
    var cpu: Double = 0            // % of one core, like Activity Monitor
    var gpu: Double = 0            // % of the GPU's time
    var started: Date?
    var processCount = 0
    var children: [RunningItem] = []
    var warning: String?
    var stop: Stop?
    var symbol = "app.dashed"
    var bundleURL: URL?
    /// Menu bar utilities and parts of macOS are meant to sit quietly, so they're never flagged idle.
    var watchIdle = true

    var uptime: TimeInterval { started.map { max(0, Date().timeIntervalSince($0)) } ?? 0 }
    /// Running for more than 6 hours at under 1 % CPU: probably forgotten.
    var isIdle: Bool { watchIdle && uptime > 6 * 3600 && cpu < 1 }
}

// MARK: - Model

@MainActor
@Observable
final class RunningModel {
    var runtimes: [RunningItem] = []
    var apps: [RunningItem] = []
    var others: [RunningItem] = []
    var gpuUtilization: Double?
    var loading = false
    var loaded = false
    var busy: Set<String> = []
    var toast: String?

    @ObservationIgnored private var previous: RunningScanner.Sample?
    @ObservationIgnored private var refreshing = false

    var idleRuntimes: [RunningItem] { runtimes.filter(\.isIdle) }
    var totalMemory: Int64 { (runtimes + apps + others).reduce(0) { $0 + $1.memory } }

    func load() async {
        guard !refreshing else { return }
        refreshing = true
        if !loaded { loading = true }
        let prev = previous
        let result = await Task.detached(priority: .userInitiated) { () -> RunningScanner.Result in
            // CPU and GPU are rates, so the first look takes two samples a second apart.
            var base = prev
            if base == nil {
                base = RunningScanner.sample()
                try? await Task.sleep(for: .seconds(1))
            }
            return RunningScanner.scan(since: base!)
        }.value
        previous = result.sample
        runtimes = result.runtimes
        apps = result.apps
        others = result.others
        gpuUtilization = result.gpuUtilization
        loading = false
        loaded = true
        refreshing = false
    }

    func stop(_ item: RunningItem) async {
        guard let stop = item.stop, !busy.contains(item.id) else { return }
        // A group and the things inside it stop together, so neither can be stopped twice at once.
        let parent = (runtimes + apps).first { $0.children.contains { $0.id == item.id } }
        let related = Set([item.id] + item.children.map(\.id) + [parent?.id].compactMap { $0 })
        busy.formUnion(related)
        let (ok, message) = await Task.detached { RunningScanner.perform(stop) }.value
        CleanLog.log("Running: stopped \(item.name) [\(item.id)] with \(stop.command) → \(ok ? "ok" : message)")
        busy.subtract(related)
        toast = ok ? "Stopped \(item.name)" : "Couldn't stop \(item.name)\(message.isEmpty ? "" : ": \(message)")"
        SoundFX.shared.play(ok ? .clean : .warn)
        // Give VMs and simulators a moment to wind down before measuring again.
        try? await Task.sleep(for: .seconds(ok ? 1.5 : 0))
        await load()
    }
}

// MARK: - Scanner

enum RunningScanner {
    struct Sample: Sendable {
        var cpu: [Int32: UInt64] = [:]     // ns of CPU time
        var gpu: [Int32: UInt64] = [:]     // ns of GPU time
        var at: UInt64 = 0                 // ns, mach clock
    }

    struct Result: Sendable {
        var runtimes: [RunningItem] = []
        var apps: [RunningItem] = []
        var others: [RunningItem] = []
        var gpuUtilization: Double?
        var sample: Sample
    }

    /// A process of the current user.
    struct Proc {
        let pid: Int32
        let ppid: Int32
        let path: String
        let name: String
        let started: Date
        let footprint: Int64
        let cpuTime: UInt64
        var cpu: Double = 0
        var gpu: Double = 0
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: Sampling

    static func sample() -> Sample {
        var s = Sample(at: nanos(mach_absolute_time()))
        for pid in allPIDs() {
            if let t = cpuTime(pid) { s.cpu[pid] = t }
        }
        s.gpu = gpuTimes().perPID
        return s
    }

    static func scan(since prev: Sample) -> Result {
        let now = nanos(mach_absolute_time())
        let wall = Double(max(1, now - prev.at))
        let gpu = gpuTimes()
        var next = Sample(gpu: gpu.perPID, at: now)

        let uid = getuid()
        var procs: [Int32: Proc] = [:]
        for pid in allPIDs() where pid > 0 {
            guard let bsd = bsdInfo(pid), bsd.pbi_uid == uid else { continue }
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let path = pidPath(pid)
            let t = nanos(ri.ri_user_time + ri.ri_system_time)
            next.cpu[pid] = t
            var p = Proc(
                pid: pid, ppid: Int32(bsd.pbi_ppid), path: path,
                name: path.isEmpty ? cString(bsd.pbi_name) : (path as NSString).lastPathComponent,
                started: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6),
                footprint: Int64(ri.ri_phys_footprint), cpuTime: t
            )
            if let before = prev.cpu[pid], t >= before { p.cpu = Double(t - before) / wall * 100 }
            if let g = gpu.perPID[pid], let before = prev.gpu[pid], g >= before { p.gpu = min(100, Double(g - before) / wall * 100) }
            procs[pid] = p
        }

        var grouper = Grouper(procs: procs, fullDisk: Permissions.hasFullDiskAccess)
        var result = grouper.build()
        result.gpuUtilization = gpu.utilization
        result.sample = next
        return result
    }

    // MARK: Grouping

    /// Sorts every process into a row: simulators, VMs, Gradle daemons, apps with their helpers,
    /// project processes, then everything else that isn't part of macOS.
    struct Grouper {
        let procs: [Int32: Proc]
        let fullDisk: Bool
        var projects: ProjectFinder
        /// Processes Claude started (its helpers, Claude Code, and the tools those run). Never stopped from here.
        var claude: Set<Int32> = []

        init(procs: [Int32: Proc], fullDisk: Bool) {
            self.procs = procs
            self.fullDisk = fullDisk
            projects = ProjectFinder(fullDisk: fullDisk)
            for p in procs.values where isClaude(p.pid) { claude.insert(p.pid) }
        }

        static func isClaudePath(_ path: String) -> Bool {
            path.contains("/Claude.app/") || path.contains("/Claude/claude-code/") || path.contains("/.local/share/claude/")
        }

        func isClaude(_ pid: Int32) -> Bool {
            var cur = pid
            for _ in 0..<16 {
                guard let p = procs[cur] else { break }
                if Self.isClaudePath(p.path) || p.name == "claude" { return true }
                guard p.ppid > 1 else { break }
                cur = p.ppid
            }
            if let r = responsible(pid), r != pid, let rp = procs[r] { return Self.isClaudePath(rp.path) }
            return false
        }

        mutating func build() -> Result {
            var buckets: [String: [Proc]] = [:]
            var simDevice: [Int32: String] = [:]       // launchd_sim pid → device UDID
            var vmProcs: [Proc] = []
            var gradle: [Proc] = []
            var limaProcs: [String: [Proc]] = [:]      // lima instance → limactl processes
            var sharedLima: [Proc] = []
            let me = getpid()

            for p in procs.values where p.name == "launchd_sim" {
                if let udid = RunningScanner.args(p.pid).lazy.compactMap(RunningScanner.udid(in:)).first { simDevice[p.pid] = udid }
            }

            for p in procs.values {
                let path = p.path
                if p.pid == me {
                    buckets["app:\(Bundle.main.bundlePath)", default: []].append(p)
                } else if let udid = simAncestor(p, simDevice) {
                    buckets["sim:\(udid)", default: []].append(p)
                } else if path.contains("/Simulator.app/") || path.contains("CoreSimulator.framework") {
                    buckets["sims:support", default: []].append(p)
                } else if path.hasSuffix("/com.apple.Virtualization.VirtualMachine") || p.name.hasPrefix("qemu-system-") {
                    vmProcs.append(p)
                } else if p.name == "limactl" {
                    let a = RunningScanner.args(p.pid)
                    if a.contains("hostagent"), let inst = a.last {
                        limaProcs[inst, default: []].append(p)
                    } else {
                        sharedLima.append(p)    // `limactl usernet`, the network helper the instances share
                    }
                } else if p.name == "colima" {
                    let a = RunningScanner.args(p.pid)
                    let profile = a.firstIndex(of: "--profile").map { a.indices.contains($0 + 1) ? a[$0 + 1] : "default" }
                        ?? a.firstIndex(of: "-p").map { a.indices.contains($0 + 1) ? a[$0 + 1] : "default" } ?? "default"
                    limaProcs[ColimaDetector.instance(for: profile), default: []].append(p)
                } else if p.name == "java", RunningScanner.args(p.pid).contains(where: { $0.hasSuffix("GradleDaemon") }) {
                    gradle.append(p)
                } else if let bundle = appBundle(path), !Self.isClaudePath(path), !isSystemApp(bundle) {
                    buckets["app:\(bundle)", default: []].append(p)
                } else if claude.contains(p.pid) {
                    // A dev server Claude started still shows under its project, just without a stop button.
                    if !Self.isClaudePath(path), p.name != "claude", !Self.shells.contains(p.name), !isSystem(path), let root = projects.project(forPID: p.pid) {
                        buckets["dev:\(root.path)", default: []].append(p)
                    } else {
                        buckets["app:/Applications/Claude.app", default: []].append(p)
                    }
                } else if !Self.shells.contains(p.name), !isSystem(path), let root = projects.project(forPID: p.pid) {
                    buckets["dev:\(root.path)", default: []].append(p)
                } else if let r = responsible(p.pid), r != p.pid, let rp = procs[r], let bundle = appBundle(rp.path),
                          !isSystemApp(bundle), !Self.isClaudePath(rp.path) {
                    buckets["app:\(bundle)", default: []].append(p)
                } else if !isSystem(path), !Self.shells.contains(p.name), !path.isEmpty {
                    buckets["other:\(p.name)", default: []].append(p)
                }
            }

            var result = Result(sample: Sample())
            var runtimes: [RunningItem] = []

            // iOS Simulators
            let simKeys = buckets.keys.filter { $0.hasPrefix("sim:") }
            if !simKeys.isEmpty {
                runtimes.append(simulators(simKeys.map { (String($0.dropFirst(4)), buckets[$0]!) }, support: buckets["sims:support"] ?? []))
            } else if let support = buckets["sims:support"], support.contains(where: { $0.path.contains("/Simulator.app/") }) {
                buckets["app:/Simulator.app"] = support    // Simulator open with nothing booted: show it as an app
            }

            // Virtual machines and their containers. The shared network helper counts with the first instance.
            if let first = limaProcs.keys.sorted().first { limaProcs[first]! += sharedLima }
            runtimes += virtualMachines(vmProcs, lima: limaProcs, buckets: &buckets)

            // Gradle daemons
            for p in gradle { runtimes.append(gradleRow(p)) }

            // Project processes
            for key in buckets.keys.filter({ $0.hasPrefix("dev:") }) {
                runtimes.append(devRow(URL(fileURLWithPath: String(key.dropFirst(4))), buckets[key]!))
            }

            // Apps
            var apps: [RunningItem] = []
            for key in buckets.keys.filter({ $0.hasPrefix("app:") }) {
                apps.append(appRow(String(key.dropFirst(4)), buckets[key]!))
            }

            // Everything else, if it's noticeable
            var others: [RunningItem] = []
            for key in buckets.keys.filter({ $0.hasPrefix("other:") }) {
                let ps = buckets[key]!
                var row = RunningItem(id: key, kind: .process, name: String(key.dropFirst(6)), detail: Fmt.shortPath(URL(fileURLWithPath: ps[0].path)))
                fill(&row, ps)
                row.symbol = "terminal"
                row.watchIdle = false
                if row.memory > 40_000_000 || row.cpu >= 1 { others.append(row) }
            }

            let byMemory: (RunningItem, RunningItem) -> Bool = { $0.memory > $1.memory }
            result.runtimes = runtimes.sorted(by: byMemory)
            result.apps = apps.sorted(by: byMemory)
            result.others = Array(others.sorted(by: byMemory).prefix(25))
            return result
        }

        /// Interactive tools that are never rows of their own (and never stopped from here).
        static let shells: Set<String> = [
            "zsh", "bash", "sh", "fish", "dash", "login", "tmux", "screen", "ssh", "sshd", "sudo", "su",
            "git", "less", "more", "man", "vim", "nvim", "vi", "nano", "emacs", "script", "caffeinate", "sleep",
        ]

        /// Tools that may run inside a project but shouldn't be stopped with a signal from here.
        static let noSignal: Set<String> = ["claude", "codex", "opencode", "aider", "gemini", "cursor-agent", "xcodebuild", "swift-build", "lldb", "debugserver"]

        // MARK: Rows

        func fill(_ row: inout RunningItem, _ ps: [Proc]) {
            row.memory = ps.reduce(0) { $0 + $1.footprint }
            row.cpu = ps.reduce(0) { $0 + $1.cpu }
            row.gpu = min(100, ps.reduce(0) { $0 + $1.gpu })
            row.started = ps.map(\.started).min()
            row.processCount = ps.count
        }

        func simAncestor(_ p: Proc, _ devices: [Int32: String]) -> String? {
            var cur = p.pid
            for _ in 0..<12 {
                if let udid = devices[cur] { return udid }
                guard let parent = procs[cur]?.ppid, parent > 1 else { return nil }
                cur = parent
            }
            return nil
        }

        func simulators(_ devices: [(udid: String, procs: [Proc])], support: [Proc]) -> RunningItem {
            let info = SimulatorDetector.booted()
            var kids: [RunningItem] = devices.map { d in
                let meta = info[d.udid]
                var row = RunningItem(id: "sim:\(d.udid)", kind: .simulator, name: meta?.name ?? "Simulator \(d.udid.prefix(8))",
                                      detail: [meta?.runtime, "\(d.procs.count) processes"].compactMap { $0 }.joined(separator: " · "))
                fill(&row, d.procs)
                // The app you were testing: anything installed in the device that isn't Apple's.
                let apps = Set(d.procs.compactMap { p -> String? in
                    guard p.path.contains("/data/Containers/Bundle/Application/") else { return nil }
                    return appBundle(p.path).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                })
                if !apps.isEmpty { row.project = apps.sorted().joined(separator: ", ") }
                row.stop = .simctl([d.udid])
                row.symbol = "iphone"
                return row
            }
            kids.sort { $0.memory > $1.memory }
            var group = RunningItem(id: "simulators", kind: .simulators, name: "iOS Simulators (\(kids.count))", detail: "")
            fill(&group, devices.flatMap(\.procs) + support)
            group.started = kids.compactMap(\.started).min()
            group.detail = "\(group.processCount) processes" + (support.contains { $0.path.contains("/Simulator.app/") } ? " · Simulator app open" : "")
            group.project = kids.compactMap(\.project).joined(separator: ", ").nilIfEmpty
            group.children = kids
            group.stop = .simctl(devices.map(\.udid))
            group.symbol = "iphone.gen3"
            return group
        }

        func virtualMachines(_ vms: [Proc], lima: [String: [Proc]], buckets: inout [String: [Proc]]) -> [RunningItem] {
            var colima: [String: [Proc]] = lima.filter { $0.key.hasPrefix("colima") }
            var plainLima: [String: [Proc]] = lima.filter { !$0.key.hasPrefix("colima") }
            var docker: [Proc] = [], orb: [Proc] = [], utm: [String: [Proc]] = [:], unknown: [(Proc, String?)] = []

            for vm in vms {
                switch VMTracer.owner(of: vm, procs: procs) {
                case .lima(let inst) where inst.hasPrefix("colima"): colima[inst, default: []].append(vm)
                case .lima(let inst): plainLima[inst, default: []].append(vm)
                case .docker: docker.append(vm)
                case .orbstack: orb.append(vm)
                case .utm(let name): utm[name, default: []].append(vm)
                case .unknown(let owner): unknown.append((vm, owner))
                }
            }

            var rows: [RunningItem] = []
            let profiles = colima.isEmpty ? [:] : ColimaDetector.profiles()
            for (inst, ps) in colima {
                let profile = ColimaDetector.profile(for: inst)
                let meta = profiles[profile]
                var row = RunningItem(id: "colima:\(profile)", kind: .vm, name: "Colima (\(profile))", detail: "")
                fill(&row, ps)
                row.started = ps.first { VMTracer.isVM($0) }?.started ?? row.started
                let sock = "\(RunningScanner.home)/.colima/\(profile)/docker.sock"
                row.children = DockerDetector.containers(host: "unix://\(sock)")
                row.detail = [
                    meta.map { "\($0.runtime.capitalized) · \($0.cpus) CPUs · \(Fmt.memory($0.memory))" } ?? "Lima VM",
                    containerSummary(row.children),
                ].compactMap { $0 }.joined(separator: " · ")
                row.stop = .colima(profile)
                row.symbol = "shippingbox"
                rows.append(row)
            }
            for (inst, ps) in plainLima {
                var row = RunningItem(id: "lima:\(inst)", kind: .vm, name: "Lima (\(inst))", detail: "Lima VM")
                fill(&row, ps)
                row.symbol = "server.rack"
                rows.append(row)
            }
            // Docker Desktop and OrbStack: the app and its VM are one runtime. Stopping asks the app to quit.
            for (label, appPath, sock, vmProcs) in [
                ("Docker Desktop", "/Applications/Docker.app", "\(RunningScanner.home)/.docker/run/docker.sock", docker),
                ("OrbStack", "/Applications/OrbStack.app", "\(RunningScanner.home)/.orbstack/run/docker.sock", orb),
            ] {
                let appProcs = buckets.removeValue(forKey: "app:\(appPath)") ?? []
                guard !(appProcs + vmProcs).isEmpty else { continue }
                var row = RunningItem(id: "vm:\(label)", kind: .vm, name: label, detail: "")
                fill(&row, appProcs + vmProcs)
                if FileManager.default.fileExists(atPath: sock) { row.children = DockerDetector.containers(host: "unix://\(sock)") }
                row.detail = ["Docker VM", containerSummary(row.children)].compactMap { $0 }.joined(separator: " · ")
                row.bundleURL = URL(fileURLWithPath: appPath)
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == appPath }) {
                    row.stop = .quitApp(app.processIdentifier)
                }
                row.symbol = "shippingbox.fill"
                rows.append(row)
            }
            if !utm.isEmpty {
                let listed = UTMDetector.started()
                for (name, ps) in utm {
                    var row = RunningItem(id: "utm:\(name)", kind: .vm, name: name, detail: "UTM virtual machine")
                    fill(&row, ps)
                    if let uuid = listed.first(where: { $0.name == name })?.uuid { row.stop = .utm(uuid) }
                    row.symbol = "desktopcomputer"
                    rows.append(row)
                }
            }
            for (vm, owner) in unknown {
                var row = RunningItem(id: "vm:\(vm.pid)", kind: .vm, name: "Virtual machine", detail: owner.map { "Started by \($0)" } ?? "Owner unknown")
                fill(&row, [vm])
                row.symbol = "cpu"
                rows.append(row)
            }
            return rows
        }

        func containerSummary(_ kids: [RunningItem]) -> String? {
            kids.isEmpty ? nil : (kids.count == 1 ? "1 container" : "\(kids.count) containers")
        }

        mutating func gradleRow(_ p: Proc) -> RunningItem {
            let a = RunningScanner.args(p.pid)
            let version = a.firstIndex { $0.hasSuffix("GradleDaemon") }.flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } ?? "?"
            let lastDir = GradleDetector.lastBuildDir(version: version, pid: p.pid)
            var row = RunningItem(id: "gradle:\(p.pid)", kind: .gradle, name: "Gradle daemon",
                                  detail: "Gradle \(version)" + (lastDir.map { " · last build in \(Fmt.shortPath($0))" } ?? ""))
            fill(&row, [p])
            if let dir = lastDir, let root = projects.project(for: dir.path) {
                row.project = root.lastPathComponent
                row.projectURL = root
            }
            // The daemon's own JDK, so `gradlew --stop` works without JAVA_HOME (apps don't get your shell's).
            let javaHome = p.path.hasSuffix("/bin/java") ? String(p.path.dropLast("/bin/java".count)) : nil
            row.stop = .gradle(version: version, projectDir: lastDir, pid: p.pid, javaHome: javaHome)
            row.symbol = "hammer"
            return row
        }

        func devRow(_ root: URL, _ ps: [Proc]) -> RunningItem {
            let names = Dictionary(grouping: ps, by: \.name)
                .sorted { $0.value.reduce(0) { $0 + $1.footprint } > $1.value.reduce(0) { $0 + $1.footprint } }
                .map(\.key)
            var row = RunningItem(id: "dev:\(root.path)", kind: .devProcess,
                                  name: names.prefix(2).joined(separator: " + ") + (names.count > 2 ? " +\(names.count - 2)" : ""),
                                  detail: Fmt.shortPath(root))
            fill(&row, ps)
            row.project = root.lastPathComponent
            row.projectURL = root
            if ps.contains(where: { claude.contains($0.pid) }) {
                row.detail += " · started by Claude"
            } else if !ps.contains(where: { Self.noSignal.contains($0.name) }) {
                row.stop = .terminate(ps.map(\.pid))
            }
            row.symbol = "chevron.left.forwardslash.chevron.right"
            return row
        }

        func appRow(_ bundle: String, _ ps: [Proc]) -> RunningItem {
            let url = URL(fileURLWithPath: bundle)
            // Without Full Disk Access, touching an app inside Desktop or Documents would stop the scan with a privacy prompt.
            let readable = fullDisk || !isPrivate(bundle)
            let name = bundle == "/Simulator.app" ? "Simulator"
                : ((readable ? FileManager.default.displayName(atPath: bundle) : url.lastPathComponent) as NSString).deletingPathExtension
            var row = RunningItem(id: "app:\(bundle)", kind: .app, name: name,
                                  detail: ps.count == 1 ? "1 process" : "\(ps.count) processes")
            fill(&row, ps)
            row.bundleURL = bundle == "/Simulator.app" || !readable ? nil : url
            let protected = bundle.hasSuffix("/Claude.app") || bundle == Bundle.main.bundlePath || isSystemApp(bundle)
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == bundle }
            if !protected, let app {
                row.stop = .quitApp(app.processIdentifier)
                row.started = app.launchDate ?? row.started
            }
            row.watchIdle = row.stop != nil && app?.activationPolicy == .regular
            if app == nil, !protected {
                row.detail = "Running in the background · not open as an app"
            }
            return row
        }
    }

    // MARK: Actions

    static func perform(_ stop: RunningItem.Stop) -> (Bool, String) {
        switch stop {
        case .simctl(let ids):
            var failed: [String] = []
            for id in ids where !DevTools.run("/usr/bin/xcrun", ["simctl", "shutdown", id], timeout: 60).ok { failed.append(id) }
            return (failed.isEmpty, failed.isEmpty ? "" : "\(failed.count) device(s) didn't shut down")
        case .colima(let profile):
            guard let colima = DevTools.find("colima") else { return (false, "colima not found") }
            return result(DevTools.run(colima, ["stop", "--profile", profile], timeout: 180))
        case .docker(let id, let host, let db):
            guard let docker = DevTools.find("docker") else { return (false, "docker not found") }
            // Databases get longer to flush to disk before Docker gives up on them.
            return result(DevTools.run(docker, ["-H", host, "stop"] + (db ? ["-t", "30"] : []) + [id], timeout: 90))
        case .gradle(_, let dir, let pid, let javaHome):
            // The project's own wrapper stops daemons of its version; a gradle on PATH stops its own.
            let env = javaHome.map { ["JAVA_HOME": $0] } ?? [:]
            // Without Full Disk Access, looking for the wrapper in Desktop or Documents would wait on a privacy prompt.
            var d = Permissions.hasFullDiskAccess || !isPrivate(dir?.path ?? "") ? dir : nil
            while let cur = d, cur.path != "/", cur.path != home {
                let wrapper = cur.appendingPathComponent("gradlew").path
                if FileManager.default.isExecutableFile(atPath: wrapper) {
                    let r = DevTools.run(wrapper, ["--stop"], cwd: cur, env: env, timeout: 120)
                    if r.ok, !isRunning(pid) { return (true, "") }
                    break
                }
                d = cur.deletingLastPathComponent()
            }
            if let gradle = DevTools.find("gradle") {
                let r = DevTools.run(gradle, ["--stop"], env: env, timeout: 120)
                if r.ok, !isRunning(pid) { return (true, "") }
            }
            // No matching gradle to ask: a daemon shuts down cleanly on SIGTERM.
            return kill(pid, SIGTERM) == 0 ? (true, "") : (false, String(cString: strerror(errno)))
        case .utm(let uuid):
            return result(DevTools.run("/Applications/UTM.app/Contents/MacOS/utmctl", ["stop", "--request", uuid], timeout: 60))
        case .quitApp(let pid):
            let done = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                ok = NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
                done.signal()
            }
            done.wait()
            return (ok, ok ? "" : "the app didn't respond")
        case .terminate(let pids):
            let failed = pids.filter { kill($0, SIGTERM) != 0 && errno != ESRCH }
            return (failed.isEmpty, failed.isEmpty ? "" : String(cString: strerror(errno)))
        }
    }

    private static func result(_ r: (ok: Bool, output: String)) -> (Bool, String) {
        (r.ok, r.ok ? "" : r.output.split(separator: "\n").last.map(String.init) ?? "")
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return false }
            usleep(250_000)
        }
        return true
    }

    // MARK: Low-level process info

    static func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, got))))
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func pidPath(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let p = cString(info.pvi_cdir.vip_path)
        return p.isEmpty ? nil : p
    }

    static func cpuTime(_ pid: Int32) -> UInt64? {
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? nanos(ri.ri_user_time + ri.ri_system_time) : nil
    }

    /// Command-line arguments, from KERN_PROCARGS2.
    static func args(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }    // executable path
        while i < size && buf[i] == 0 { i += 1 }    // padding
        var out: [String] = []
        while out.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    /// Paths of the files a process has open.
    static func openFiles(_ pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size {
                out.append(cString(info.pvip.vip_path))
            }
        }
        return out
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// The app macOS holds responsible for a process (the one Activity Monitor groups it under).
    static func responsible(_ pid: Int32) -> Int32? {
        guard let f = responsibleFn else { return nil }
        let r = f(pid)
        return r > 0 ? r : nil
    }

    /// Per-process GPU time from the GPU driver's user clients, plus overall GPU load.
    static func gpuTimes() -> (perPID: [Int32: UInt64], utilization: Double?) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return ([:], nil) }
        defer { IOObjectRelease(iter) }
        var out: [Int32: UInt64] = [:]
        var util: Double?
        var acc = IOIteratorNext(iter)
        while acc != 0 {
            if let stats = IORegistryEntryCreateCFProperty(acc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                util = max(util ?? 0, u)
            }
            var kids: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(acc, kIOServicePlane, &kids) == KERN_SUCCESS {
                var c = IOIteratorNext(kids)
                while c != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]],
                       let pid = Int32(creator.dropFirst(4).prefix { $0.isNumber }) {
                        out[pid, default: 0] += usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                    }
                    IOObjectRelease(c)
                    c = IOIteratorNext(kids)
                }
                IOObjectRelease(kids)
            }
            IOObjectRelease(acc)
            acc = IOIteratorNext(iter)
        }
        return (out, util)
    }

    // MARK: Helpers

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    static func nanos(_ ticks: UInt64) -> UInt64 {
        ticks / UInt64(timebase.denom) * UInt64(timebase.numer) + ticks % UInt64(timebase.denom) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func udid(in s: String) -> String? {
        guard let r = s.range(of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    /// The outermost .app bundle a path lives in, so helper apps roll up under their parent.
    static func appBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// Folders macOS guards with a privacy prompt. Without Full Disk Access the scanner only reads their paths, never their contents.
    static func isPrivate(_ path: String) -> Bool {
        ["/Desktop", "/Documents", "/Downloads", "/Library/Mobile Documents", "/Library/CloudStorage", "/Pictures", "/Movies", "/Music"]
            .contains { path == home + $0 || path.hasPrefix(home + $0 + "/") } || path.hasPrefix("/Volumes/")
    }

    /// Apps that are part of macOS (Finder, Dock, Spotlight…). The ones in /System/Applications are ordinary apps you can quit.
    static func isSystemApp(_ bundle: String) -> Bool {
        isSystem(bundle) && !bundle.hasPrefix("/System/Applications/")
    }

    /// Parts of macOS itself: never listed on their own and never stopped.
    static func isSystem(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/", "/Library/Developer/PrivateFrameworks/"]
            .contains { path.hasPrefix($0) }
    }
}

// MARK: - Project attribution

/// Walks up from a process's working folder to the project it belongs to: the enclosing git
/// repository if there is one, otherwise the nearest folder with a package.json, .xcodeproj or similar.
struct ProjectFinder {
    /// Folders that hold projects rather than being one, skipped when guessing from a path.
    static let containers: Set<String> = ["apps", "projects", "code", "dev", "src", "repos", "github", "developer", "work", "workspace", "git", "sites", "clients"]
    static let markers = ["package.json", "pubspec.yaml", "Cargo.toml", "go.mod", "Package.swift", "pyproject.toml", "settings.gradle", "settings.gradle.kts", "Gemfile", "composer.json"]
    let fullDisk: Bool
    private var cache: [String: URL?] = [:]

    init(fullDisk: Bool) { self.fullDisk = fullDisk }

    mutating func project(forPID pid: Int32) -> URL? {
        guard let dir = RunningScanner.cwd(pid) else { return nil }
        return project(for: dir)
    }

    mutating func project(for dir: String) -> URL? {
        if let hit = cache[dir] { return hit }
        if !fullDisk, RunningScanner.isPrivate(dir) {
            let guess = Self.guess(dir)
            cache[dir] = guess
            return guess
        }
        let home = RunningScanner.home
        let fm = FileManager.default
        var nearest: URL?
        var cur = URL(fileURLWithPath: dir).standardizedFileURL
        // Only folders inside your home count; the home folder itself is never a project.
        while cur.path.hasPrefix(home + "/") {
            if fm.fileExists(atPath: cur.appendingPathComponent(".git").path) { nearest = cur; break }
            if nearest == nil {
                if Self.markers.contains(where: { fm.fileExists(atPath: cur.appendingPathComponent($0).path) })
                    || ((try? fm.contentsOfDirectory(atPath: cur.path)) ?? []).contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                    nearest = cur
                }
            }
            cur = cur.deletingLastPathComponent()
        }
        cache[dir] = nearest
        return nearest
    }

    /// Best guess from the path alone: the first folder under Desktop, Documents and so on,
    /// stepping past folders like "Apps" or "Projects" that only group projects.
    static func guess(_ dir: String) -> URL? {
        let parts = URL(fileURLWithPath: dir).standardizedFileURL.pathComponents
        let homeParts = URL(fileURLWithPath: RunningScanner.home).pathComponents
        guard parts.starts(with: homeParts) || parts.starts(with: ["/", "Volumes"]) else { return nil }
        var i = parts.starts(with: ["/", "Volumes"]) ? 3 : homeParts.count + 1    // past the volume or the private folder
        if parts.count > homeParts.count + 1, parts[homeParts.count] == "Library" { i += 2 }  // Library/CloudStorage/<provider>/
        while i < parts.count - 1, containers.contains(parts[i].lowercased()) { i += 1 }
        guard i < parts.count else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...i])))
    }
}

// MARK: - Detectors

enum SimulatorDetector {
    struct Device { let name: String; let runtime: String }

    /// Booted devices from `xcrun simctl list devices booted`.
    static func booted() -> [String: Device] {
        let r = DevTools.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"], timeout: 20, stderr: false)
        guard let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [:] }
        var out: [String: Device] = [:]
        for (runtime, devices) in byRuntime {
            // com.apple.CoreSimulator.SimRuntime.iOS-26-5 → iOS 26.5
            let tail = runtime.components(separatedBy: ".").last ?? runtime
            let parts = tail.split(separator: "-")
            let pretty = parts.first.map { String($0) + " " + parts.dropFirst().joined(separator: ".") } ?? tail
            for d in devices {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                out[udid] = Device(name: name, runtime: pretty)
            }
        }
        return out
    }
}

enum ColimaDetector {
    struct Profile { let name: String; let status: String; let cpus: Int; let memory: Int64; let runtime: String }

    /// Lima names Colima's instances "colima" for the default profile and "colima-<name>" for others.
    static func profile(for instance: String) -> String {
        instance == "colima" ? "default" : String(instance.dropFirst("colima-".count))
    }

    static func instance(for profile: String) -> String {
        profile == "default" ? "colima" : "colima-\(profile)"
    }

    /// `colima list --json` prints one JSON object per profile.
    static func profiles() -> [String: Profile] {
        guard let colima = DevTools.find("colima") else { return [:] }
        var out: [String: Profile] = [:]
        for line in DevTools.run(colima, ["list", "--json"], timeout: 20, stderr: false).output.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = obj["name"] as? String else { continue }
            out[name] = Profile(
                name: name, status: obj["status"] as? String ?? "",
                cpus: obj["cpus"] as? Int ?? 0, memory: (obj["memory"] as? NSNumber)?.int64Value ?? 0,
                runtime: obj["runtime"] as? String ?? ""
            )
        }
        return out
    }
}

enum DockerDetector {
    /// Images that hold data. Stopping one is safe (its data stays in the volume), but deserves a warning.
    static let databases = [
        "mssql", "sqlserver", "postgres", "postgis", "timescale", "mysql", "mariadb", "percona", "mongo", "redis", "valkey",
        "cassandra", "scylla", "couchdb", "couchbase", "elasticsearch", "opensearch", "clickhouse", "cockroach", "neo4j",
        "influxdb", "oracle", "db2", "firebird", "surrealdb", "rabbitmq", "kafka",
    ]

    /// Running containers on one Docker socket, with compose project, CPU, memory and start time.
    static func containers(host: String) -> [RunningItem] {
        guard let docker = DevTools.find("docker") else { return [] }
        let ps = DevTools.run(docker, ["-H", host, "ps", "--no-trunc", "--format", "{{json .}}"], timeout: 15, stderr: false)
        guard ps.ok else { return [] }
        let rows = ps.output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard !rows.isEmpty else { return [] }

        let stats = containerStats(docker: docker, host: host)
        let ids = rows.compactMap { $0["ID"] as? String }
        var startedAt: [String: Date] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in DevTools.run(docker, ["-H", host, "inspect", "--format", "{{.Id}} {{.State.StartedAt}}"] + ids, timeout: 15, stderr: false).output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            // Docker prints nanoseconds; ISO8601DateFormatter wants at most milliseconds.
            let stamp = String(parts[1]).replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            startedAt[String(parts[0])] = iso.date(from: stamp)
        }

        return rows.compactMap { o in
            guard let id = o["ID"] as? String else { return nil }
            let name = o["Names"] as? String ?? String(id.prefix(12))
            let image = o["Image"] as? String ?? ""
            let labels = parseLabels(o["Labels"] as? String ?? "")
            let isDB = databases.contains { image.lowercased().contains($0) || name.lowercased().contains($0) }
            var row = RunningItem(id: "container:\(id)", kind: .container, name: name,
                                  detail: [image, o["Status"] as? String].compactMap { $0 }.joined(separator: " · "))
            if let s = stats[id] ?? stats.first(where: { id.hasPrefix($0.key) })?.value {
                row.cpu = s.cpu
                row.memory = s.mem
            }
            row.started = startedAt[id]
            row.processCount = 1
            if let dir = labels["com.docker.compose.project.working_dir"] {
                row.projectURL = URL(fileURLWithPath: dir)
                row.project = labels["com.docker.compose.project"] ?? row.projectURL?.lastPathComponent
            } else {
                row.project = labels["com.docker.compose.project"]
            }
            if isDB {
                row.warning = "Database. Its data stays in the container's volume, but anything connected to it loses the connection. Docker gives it 30 s to shut down cleanly."
            }
            row.stop = .docker(id: String(id.prefix(12)), host: host, database: isDB)
            row.symbol = isDB ? "cylinder.split.1x2" : "shippingbox"
            return row
        }.sorted { $0.memory > $1.memory }
    }

    typealias Stats = [String: (cpu: Double, mem: Int64)]
    private final class StatsCache: @unchecked Sendable {
        let lock = NSLock()
        var byHost: [String: (at: Date, stats: Stats)] = [:]
    }
    private static let cache = StatsCache()

    /// `docker stats` takes a couple of seconds to measure, so its numbers are reused for 30 s.
    static func containerStats(docker: String, host: String) -> Stats {
        cache.lock.lock()
        let hit = cache.byHost[host]
        cache.lock.unlock()
        if let hit, Date().timeIntervalSince(hit.at) < 30 { return hit.stats }
        var stats: Stats = [:]
        for line in DevTools.run(docker, ["-H", host, "stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"], timeout: 20, stderr: false).output.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = o["ID"] as? String else { continue }
            let cpu = Double((o["CPUPerc"] as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? 0
            let mem = parseBytes((o["MemUsage"] as? String ?? "").components(separatedBy: " / ").first ?? "")
            stats[id] = (cpu, mem)
        }
        cache.lock.lock()
        cache.byHost[host] = (Date(), stats)
        cache.lock.unlock()
        return stats
    }

    static func parseLabels(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    /// "1.25GiB", "512MiB", "300kB" → bytes.
    static func parseBytes(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        let num = Double(t.prefix { $0.isNumber || $0 == "." }) ?? 0
        let unit = t.drop { $0.isNumber || $0 == "." }.lowercased()
        let mult: Double = switch unit {
        case "kib": 1024
        case "kb": 1000
        case "mib": 1_048_576
        case "mb": 1e6
        case "gib": 1_073_741_824
        case "gb": 1e9
        case "tib": 1_099_511_627_776
        default: 1
        }
        return Int64(num * mult)
    }
}

enum GradleDetector {
    /// The folder of the last build a daemon ran, from `~/.gradle/daemon/<version>/daemon-<pid>.out.log`.
    static func lastBuildDir(version: String, pid: Int32) -> URL? {
        let log = URL(fileURLWithPath: RunningScanner.home).appendingPathComponent(".gradle/daemon/\(version)/daemon-\(pid).out.log")
        guard let h = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? h.close() }
        // Logs grow large; the newest build is near the end, the first one near the start.
        let end = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 512 * 1024
        var found: String?
        for offset in [end > chunk ? end - chunk : 0, 0] {
            try? h.seek(toOffset: offset)
            let text = String(decoding: h.readData(ofLength: Int(chunk)), as: UTF8.self)
            if let r = text.range(of: "currentDir=", options: .backwards) {
                found = String(text[r.upperBound...].prefix { $0 != "}" && $0 != "," && $0 != "\n" })
                break
            }
        }
        return found.map { URL(fileURLWithPath: $0) }
    }
}

enum UTMDetector {
    struct VM { let uuid: String; let status: String; let name: String }

    /// Started VMs from `utmctl list`. Only called while a UTM VM is running, so it never launches UTM.
    static func started() -> [VM] {
        let r = DevTools.run("/Applications/UTM.app/Contents/MacOS/utmctl", ["list"], timeout: 15, stderr: false)
        return r.output.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count == 3, cols[1] == "started" || cols[1] == "paused" else { return nil }
            return VM(uuid: String(cols[0]), status: String(cols[1]), name: String(cols[2]).trimmingCharacters(in: .whitespaces))
        }
    }
}

/// Works out whose an anonymous virtual machine process is, from the disk images it has open,
/// falling back to the app macOS holds responsible for it.
enum VMTracer {
    enum Owner { case lima(String), docker, orbstack, utm(String), unknown(String?) }

    static func isVM(_ p: RunningScanner.Proc) -> Bool {
        p.path.hasSuffix("/com.apple.Virtualization.VirtualMachine") || p.name.hasPrefix("qemu-system-")
    }

    static func owner(of vm: RunningScanner.Proc, procs: [Int32: RunningScanner.Proc]) -> Owner {
        for path in RunningScanner.openFiles(vm.pid) + RunningScanner.args(vm.pid) {
            if let o = owner(fromPath: path) { return o }
        }
        guard let r = RunningScanner.responsible(vm.pid), r != vm.pid, let rp = procs[r] else { return .unknown(nil) }
        if rp.name == "limactl", let inst = RunningScanner.args(r).last { return .lima(inst) }
        if rp.path.contains("/Docker.app/") { return .docker }
        if rp.path.contains("/OrbStack.app/") { return .orbstack }
        if rp.path.contains("/UTM.app/") { return .utm("UTM virtual machine") }
        return .unknown(RunningScanner.appBundle(rp.path).map { ($0 as NSString).lastPathComponent } ?? rp.name)
    }

    static func owner(fromPath p: String) -> Owner? {
        for base in ["/.colima/_lima/", "/.lima/"] {
            guard let r = p.range(of: base) else { continue }
            let parts = p[r.upperBound...].split(separator: "/")
            guard var inst = parts.first.map(String.init) else { continue }
            if inst == "_disks", parts.count > 1 { inst = String(parts[1]) }
            if !inst.hasPrefix("_") { return .lima(base == "/.colima/_lima/" && !inst.hasPrefix("colima") ? "colima-\(inst)" : inst) }
        }
        if p.contains("com.docker.docker") || p.hasSuffix("/Docker.raw") { return .docker }
        if p.lowercased().contains("orbstack") { return .orbstack }
        if let r = p.range(of: ".utm/") {
            return .utm((String(p[..<r.lowerBound]) as NSString).lastPathComponent)
        }
        return nil
    }
}

// MARK: - Running developer tools

enum DevTools {
    /// GUI apps get a bare PATH, so developer tools are looked up where their installers put them.
    static var searchPath: [String] {
        let h = RunningScanner.home
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(h)/.orbstack/bin", "\(h)/.docker/bin",
                "/Applications/Docker.app/Contents/Resources/bin", "\(h)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    static func find(_ name: String) -> String? {
        searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    /// Runs a tool with a timeout, so a hung VM socket can't stall the scan.
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, env extra: [String: String] = [:],
                    timeout: TimeInterval, stderr: Bool = true) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env.merge(extra) { $1 }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = stderr ? pipe : FileHandle.nullDevice
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return (false, "timed out")
        }
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: box.data, as: UTF8.self))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
