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

    init() {
        // Keep live stats ticking for the dashboard and menu bar, and watch for low disk space.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.updater.checkIfDue()
        }
        Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.stats.refresh()
                DiskAlerts.check(freeBytes: self.stats.diskFree)
                ticks += 1
                if ticks % 900 == 30 { await self.weeklyCheckupIfDue() }   // ~every 30 min, starting a minute in
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
        case .optimization: return agents.loaded ? "\(agents.items.count)" : nil
        case .maintenance: return nil
        }
    }
}
