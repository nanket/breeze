import SwiftUI

@MainActor
@Observable
final class AppModel {
    var module: Module = .smartScan
    var smartPhase: Phase = .idle
    var smartResult: Cleaner.Result?
    var hasFullDiskAccess = Permissions.hasFullDiskAccess
    var showSettings = false
    var showOnboarding = !Permissions.hasFullDiskAccess && !UserDefaults.standard.bool(forKey: "onboardingSkipped")

    let junk = JunkModel()
    let large = LargeFilesModel()
    let lens = SpaceLensModel()
    let organizer = OrganizerModel()
    let dev = DevCleanupModel()
    let dupes = DuplicatesModel()
    let security = SecurityModel()
    let privacy = PrivacyModel()
    let updates = AppUpdatesModel()
    let updater = SelfUpdater()
    var showHistory = false
    var crashReport: URL? = CrashReports.newReport()
    let apps = UninstallerModel()
    let agents = LaunchAgentsModel()
    let running = RunningModel()
    let maintenance = MaintenanceModel()
    let stats = SystemStats()

    var smartStatus: String {
        if junk.phase == .scanning { return junk.currentPath.isEmpty ? "Looking for junk…" : junk.currentPath }
        if large.phase == .scanning { return large.currentPath.isEmpty ? "Looking for large files…" : large.currentPath }
        if apps.loading { return "Measuring applications…" }
        return "Wrapping up…"
    }

    var smartStep: String {
        if junk.phase == .scanning { return "Finding system junk" }
        if large.phase == .scanning { return "Finding large files" }
        return "Checking applications"
    }

    /// Whether the main window and the menu bar panel are really on screen (not closed or covered).
    private(set) var windowOnScreen = false
    private(set) var panelOnScreen = false
    var isLive: Bool { windowOnScreen || panelOnScreen }

    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var lastCheckupTry = Date().addingTimeInterval(-29 * 60)   // first try a minute in

    init() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.updater.checkIfDue()
        }
        startStatsLoop()
    }

    /// Called by the main window and the menu bar panel as they come on and off screen.
    func setOnScreen(window: Bool? = nil, panel: Bool? = nil) {
        let wasLive = isLive
        if let window { windowOnScreen = window }
        if let panel { panelOnScreen = panel }
        if isLive != wasLive { startStatsLoop() }
    }

    /// While something is on screen, live stats tick every 5 s (disk space every 30 s).
    /// Otherwise a quiet 10 s tick only watches for low disk space, so nothing redraws.
    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                let live = self.isLive
                if live {
                    // Snap to the new numbers: animating every tick kept the window redrawing non-stop.
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { self.stats.refresh(disk: ticks % 6 == 0) }
                    DiskAlerts.check(freeBytes: self.stats.diskFree)
                } else if ticks % 3 == 0, let d = SystemStats.diskSpace() {
                    DiskAlerts.check(freeBytes: d.free)
                }
                if Date().timeIntervalSince(self.lastCheckupTry) > 30 * 60 {
                    self.lastCheckupTry = Date()
                    Task { await self.weeklyCheckupIfDue() }
                }
                ticks += 1
                try? await Task.sleep(for: .seconds(live ? 5 : 10))
            }
        }
    }

    func select(_ m: Module) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { module = m }
    }

    func runSmartScan() async {
        guard smartPhase != .scanning else { return }
        refreshPermissions()
        withAnimation { smartPhase = .scanning }
        SoundFX.shared.play(.scanStart)
        junk.reset()
        await SoundFX.shared.quietly {
            async let a: Void = junk.scan()
            async let b: Void = large.scan()
            async let c: Void = apps.load()
            async let d: Void = agents.load()
            _ = await (a, b, c, d)
        }
        withAnimation(.spring(response: 0.5)) { smartPhase = .results }
        SoundFX.shared.play(.scanDone)
    }

    func runSmartClean() async {
        withAnimation { smartPhase = .cleaning }
        await SoundFX.shared.quietly { await junk.clean() }
        SoundFX.shared.play((junk.lastResult?.failures.isEmpty ?? true) ? .clean : .warn)
        smartResult = junk.lastResult
        stats.refresh()
        withAnimation(.spring(response: 0.5)) { smartPhase = .done }
    }

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess
    }

    func badge(for m: Module) -> String? {
        switch m {
        case .smartScan: return nil
        case .junk: return junk.phase == .results && junk.totalSelected > 0 ? Fmt.bytes(junk.totalSelected) : nil
        case .largeFiles: return large.phase == .results && !large.files.isEmpty ? "\(large.files.count)" : nil
        case .spaceLens: return nil
        case .organizer: return nil
        case .security: return security.phase == .results && !security.threats.isEmpty ? "!" : nil
        case .privacy: return privacy.phase == .results && privacy.selectedSize > 0 ? Fmt.bytes(privacy.selectedSize) : nil
        case .updater: return updates.phase == .results && !updates.updates.isEmpty ? "\(updates.updates.count)" : nil
        case .devCleanup: return dev.phase == .results && dev.totalSize > 0 ? Fmt.bytes(dev.totalSize) : nil
        case .duplicates: return dupes.phase == .results && !dupes.groups.isEmpty ? "\(dupes.groups.count)" : nil
        case .uninstaller: return apps.loaded ? "\(apps.apps.count)" : nil
        case .running: return running.loaded && !running.idleRuntimes.isEmpty ? "\(running.idleRuntimes.count) idle" : nil
        case .optimization: return agents.loaded ? "\(agents.items.count)" : nil
        case .maintenance: return nil
        }
    }
}
