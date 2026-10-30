import SwiftUI
import Darwin
import UserNotifications

// MARK: - Live system stats

@MainActor
@Observable
final class SystemStats {
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var uptime: TimeInterval = 0
    var cpu: Double = 0              // 0…1
    var netDown: Double = 0          // bytes / second
    var netUp: Double = 0
    var cpuHistory: [Double] = Array(repeating: 0, count: 30)

    let chip = SysInfo.string("machdep.cpu.brand_string") ?? "Apple Silicon"
    let model = SysInfo.string("hw.model") ?? "Mac"
    let macName = Host.current().localizedName ?? "Your Mac"
    let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()

    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    var diskUsed: Int64 { max(0, diskTotal - diskFree) }
    var diskFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }
    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }

    init() { refresh() }

    /// Disk space is the slow part (about 10 ms for the "important usage" figure), so the live
    /// tick skips it most of the time. Anything that just freed space refreshes with `disk: true`.
    func refresh(disk: Bool = true) {
        if disk, let d = Self.diskSpace() {
            diskTotal = d.total
            diskFree = d.free
        }
        memUsed = Self.memoryUsed()
        uptime = ProcessInfo.processInfo.systemUptime

        let c = Self.cpuTicks()
        if let last = lastCPU, c.total > last.total {
            cpu = Double(c.busy &- last.busy) / Double(c.total - last.total)
            cpuHistory.append(cpu)
            if cpuHistory.count > 30 { cpuHistory.removeFirst(cpuHistory.count - 30) }
        }
        lastCPU = c

        let n = Self.netBytes()
        let now = Date()
        if let last = lastNet {
            let dt = max(0.5, now.timeIntervalSince(last.at))
            netDown = n.rx >= last.rx ? Double(n.rx - last.rx) / dt : 0
            netUp = n.tx >= last.tx ? Double(n.tx - last.tx) / dt : 0
        }
        lastNet = (n.rx, n.tx, now)
    }

    nonisolated static func diskSpace() -> (total: Int64, free: Int64)? {
        var root = URL(fileURLWithPath: "/")
        root.removeAllCachedResourceValues()
        guard let v = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return (Int64(v.volumeTotalCapacity ?? 0), v.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
    nonisolated static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    nonisolated static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, 0) }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for i in 0..<Int(cpus) {
            let base = Int(CPU_STATE_MAX) * i
            func tick(_ s: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(s)])) }
            let used = tick(CPU_STATE_USER) + tick(CPU_STATE_SYSTEM) + tick(CPU_STATE_NICE)
            busy += used
            total += used + tick(CPU_STATE_IDLE)
        }
        let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        return (busy, total)
    }

    nonisolated static func netBytes() -> (rx: UInt64, tx: UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            let a = ifa.pointee
            if let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data {
                let name = String(cString: a.ifa_name)
                if !name.hasPrefix("lo") && !name.hasPrefix("utun") && !name.hasPrefix("awdl") && !name.hasPrefix("llw") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    rx += UInt64(d.ifi_ibytes)
                    tx += UInt64(d.ifi_obytes)
                }
            }
            p = a.ifa_next
        }
        return (rx, tx)
    }
}

// MARK: - Mac Health score

struct HealthReport {
    struct Issue: Identifiable {
        var id: String { text }
        let icon: String
        let text: String
        let module: Module?
    }

    let score: Int
    let issues: [Issue]

    var label: String {
        switch score {
        case 85...: "Excellent"
        case 70..<85: "Good"
        case 50..<70: "Fair"
        default: "Needs care"
        }
    }

    var colors: [Color] {
        switch score {
        case 85...: [Color(hex: 0x2EE6A8), Color(hex: 0x1FA2FF)]
        case 70..<85: [Color(hex: 0x7CF29C), Color(hex: 0x2EE6A8)]
        case 50..<70: [Color(hex: 0xFFE066), Color(hex: 0xFF9F43)]
        default: [Color(hex: 0xFF8A5B), Color(hex: 0xFF3D71)]
        }
    }
}

extension AppModel {
    var health: HealthReport {
        var score = 100.0
        var issues: [HealthReport.Issue] = []
        let s = stats

        if s.diskFraction > 0.75 {
            let p = min(35, (s.diskFraction - 0.75) / 0.2 * 35)
            score -= p
            issues.append(.init(icon: "internaldrive", text: "Disk is \(Int(s.diskFraction * 100))% full", module: .spaceLens))
        }
        if junk.phase == .results, junk.totalSelected > 500_000_000 {
            score -= min(20, Double(junk.totalSelected) / 1e9 * 2)
            issues.append(.init(icon: "bubbles.and.sparkles", text: "\(Fmt.bytes(junk.totalSelected)) of junk to clean", module: .junk))
        }
        if s.memFraction > 0.85 {
            score -= 10
            issues.append(.init(icon: "memorychip", text: "Memory is under pressure", module: .maintenance))
        }
        if s.uptime > 7 * 86_400 {
            score -= s.uptime > 14 * 86_400 ? 12 : 8
            issues.append(.init(icon: "clock", text: "Not restarted in \(Int(s.uptime / 86_400)) days", module: nil))
        }
        if apps.loaded, apps.unusedCount > 0 {
            score -= min(8, Double(apps.unusedCount) * 2)
            issues.append(.init(icon: "xmark.app", text: "\(apps.unusedCount) apps unused for 6+ months", module: .uninstaller))
        }
        if dev.phase == .results, dev.staleSize > 1_000_000_000 {
            score -= min(10, Double(dev.staleSize) / 1e9)
            issues.append(.init(icon: "chevron.left.forwardslash.chevron.right", text: "\(Fmt.bytes(dev.staleSize)) in idle project builds", module: .devCleanup))
        }
        if running.loaded, !running.idleRuntimes.isEmpty {
            let idle = running.idleRuntimes
            score -= min(8, Double(idle.count) * 3)
            issues.append(.init(icon: "moon.zzz", text: "\(idle.count) dev runtime\(idle.count == 1 ? "" : "s") idle for 6+ hours", module: .running))
        }
        return HealthReport(score: Int(max(0, min(100, score)).rounded()), issues: issues)
    }
}

// MARK: - Low-disk alerts

@MainActor
enum DiskAlerts {
    nonisolated static let enabledKey = "lowDiskAlerts"
    nonisolated static let thresholdKey = "lowDiskThresholdGB"
    private static let lastKey = "lowDiskLastAlert"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var thresholdGB: Double { UserDefaults.standard.object(forKey: thresholdKey) as? Double ?? 15 }

    /// At most one notification a day while free space is under the threshold.
    static func check(freeBytes: Int64) {
        guard enabled, freeBytes > 0, Double(freeBytes) < thresholdGB * 1e9 else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your Mac is running low on space"
            content.body = "Only \(Fmt.bytes(freeBytes)) left. Open Breeze to free some up."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "breeze.lowdisk", content: content, trigger: nil))
        }
    }
}
