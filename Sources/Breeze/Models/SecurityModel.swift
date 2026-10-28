import SwiftUI
import Security

struct SecurityCheck: Identifiable, Sendable {
    enum Status: Sendable { case good, warn, bad, info }
    let id: String
    let title: String
    let detail: String
    let icon: String
    let status: Status
    var fixTitle: String? = nil
    var fixURL: String? = nil
}

struct FlaggedItem: Identifiable, Hashable, Sendable {
    enum Severity: Int, Sendable { case info = 0, caution = 1, threat = 2 }
    var id: URL { url }
    let url: URL
    let title: String
    let reason: String
    let severity: Severity
}

enum Signature: Sendable {
    case apple, signed(team: String), adhoc, unsigned, invalid
    var trusted: Bool {
        switch self {
        case .apple, .signed: true
        default: false
        }
    }
}

enum SecurityScanner {
    /// Bundle IDs / launch labels of well-known adware families. A match is a strong signal, not proof.
    static let adwarePatterns: [String] = [
        "com.pcv.", "com.mackeeper", "com.zeobit", "com.genieo", "com.vsearch", "com.conduit", "com.crossrider",
        "com.spigot", "com.installmac", "com.searchmine", "com.myshopcoupon", "com.mughthesec", "com.pirrit",
        "com.bundlore", "com.shlayer", "com.adload", "com.mynewsearch", "com.searchbaron", "com.adsinsight",
        "com.webhelper", "com.safefinder", "com.chumsearch", "com.operatorsystem", "com.qsearch", "com.weknow",
    ]

    static func run(_ cmd: String) -> String { Shell.run(cmd).output.lowercased() }

    static func systemChecks() -> [SecurityCheck] {
        var out: [SecurityCheck] = []

        let gk = run("/usr/sbin/spctl --status")
        out.append(gk.contains("enabled")
            ? .init(id: "gatekeeper", title: "Gatekeeper is on", detail: "Only apps from the App Store and identified developers open without a warning.", icon: "checkmark.shield", status: .good)
            : .init(id: "gatekeeper", title: "Gatekeeper is off", detail: "Any app can run without being checked. Turn it back on unless you know why it's off.", icon: "xmark.shield", status: .bad,
                    fixTitle: "Open Privacy & Security", fixURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"))

        let sip = run("/usr/bin/csrutil status")
        out.append(sip.contains("enabled")
            ? .init(id: "sip", title: "System Integrity Protection is on", detail: "macOS system files can't be changed, even by admin apps.", icon: "lock.shield", status: .good)
            : .init(id: "sip", title: "System Integrity Protection is off", detail: "System files can be modified. It can only be turned back on from Recovery mode.", icon: "lock.open", status: .bad))

        let fv = run("/usr/bin/fdesetup status")
        out.append(fv.contains("filevault is on")
            ? .init(id: "filevault", title: "FileVault is on", detail: "Your disk is encrypted, so a lost or stolen Mac keeps your data private.", icon: "lock.doc", status: .good)
            : .init(id: "filevault", title: "FileVault is off", detail: "Anyone with your Mac can read the disk. Encryption runs in the background.", icon: "lock.doc", status: .warn,
                    fixTitle: "Turn On FileVault", fixURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault"))

        let fw = run("/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate")
        out.append(fw.contains("enabled") || fw.contains("state = 1") || fw.contains("state = 2")
            ? .init(id: "firewall", title: "Firewall is on", detail: "Unwanted incoming connections are blocked.", icon: "flame", status: .good)
            : .init(id: "firewall", title: "Firewall is off", detail: "Recommended on public Wi-Fi. It doesn't affect normal browsing.", icon: "flame", status: .warn,
                    fixTitle: "Open Firewall Settings", fixURL: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"))

        let xp = URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle")
        let xpInfo = NSDictionary(contentsOf: xp.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let xpVersion = xpInfo?["CFBundleShortVersionString"] as? String ?? "unknown"
        let xpDate = (try? xp.appendingPathComponent("Contents/Info.plist").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let stale = xpDate.map { Date().timeIntervalSince($0) > 60 * 86_400 } ?? true
        out.append(stale
            ? .init(id: "xprotect", title: "Malware definitions look old", detail: "XProtect \(xpVersion), last updated \(Fmt.ago(xpDate).lowercased()). Make sure security responses install automatically.", icon: "shield.lefthalf.filled", status: .warn,
                    fixTitle: "Open Software Update", fixURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
            : .init(id: "xprotect", title: "Malware definitions are current", detail: "Apple's XProtect \(xpVersion), updated \(Fmt.ago(xpDate).lowercased()). It removes known malware automatically.", icon: "shield.lefthalf.filled", status: .good))

        let auto = run("/usr/bin/defaults read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall 2>/dev/null")
        out.append(auto.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
            ? .init(id: "responses", title: "Security responses are off", detail: "macOS won't install security fixes and malware definitions automatically.", icon: "arrow.down.circle", status: .bad,
                    fixTitle: "Open Software Update", fixURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
            : .init(id: "responses", title: "Security responses install automatically", detail: "Apple's background security fixes reach you without waiting for a full update.", icon: "arrow.down.circle", status: .good))
        return out
    }

    static func signature(of url: URL) -> Signature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources)), nil)
        if validity == errSecCSUnsigned { return .unsigned }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info)
        let dict = info as? [String: Any] ?? [:]
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String ?? ""
        if flags & 0x2 != 0 { return .adhoc }                       // kSecCodeSignatureAdhoc
        if validity != errSecSuccess { return .invalid }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String { return .signed(team: team) }
        return identifier.hasPrefix("com.apple.") ? .apple : .signed(team: "?")
    }

    static func flaggedApps(_ apps: [AppInfo]) -> [FlaggedItem] {
        var out: [FlaggedItem] = []
        for app in apps {
            let bid = (app.bundleID ?? "").lowercased()
            if adwarePatterns.contains(where: { bid.hasPrefix($0) }) {
                out.append(.init(url: app.url, title: app.name, reason: "Matches a known adware name", severity: .threat))
                continue
            }
            switch signature(of: app.url) {
            case .unsigned: out.append(.init(url: app.url, title: app.name, reason: "Not signed by any developer", severity: .caution))
            case .invalid: out.append(.init(url: app.url, title: app.name, reason: "Signature is broken (the app was modified after signing)", severity: .caution))
            case .adhoc: out.append(.init(url: app.url, title: app.name, reason: "Signed locally, not by an identified developer", severity: .info))
            default: break
            }
        }
        return out
    }

    static func flaggedAgents(_ items: [LaunchItem]) -> [FlaggedItem] {
        var out: [FlaggedItem] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for item in items {
            let label = item.label.lowercased()
            if adwarePatterns.contains(where: { label.hasPrefix($0) }) {
                out.append(.init(url: item.url, title: item.label, reason: "Matches a known adware name", severity: .threat))
                continue
            }
            guard item.program.hasPrefix("/"), FileManager.default.fileExists(atPath: item.program) else { continue }
            let sig = signature(of: URL(fileURLWithPath: item.program))
            guard !sig.trusted else { continue }
            // Tools you install yourself (Homebrew, scripts in your home) are often unsigned and harmless.
            let personal = item.program.hasPrefix("/opt/homebrew/") || item.program.hasPrefix("/usr/local/") || item.program.hasPrefix(home)
            out.append(.init(
                url: item.url, title: item.label,
                reason: personal ? "Runs an unsigned tool you likely installed yourself" : "Runs an unsigned program at startup",
                severity: personal ? .info : .caution
            ))
        }
        return out
    }
}

@MainActor
@Observable
final class SecurityModel {
    var phase: Phase = .idle
    var checks: [SecurityCheck] = []
    var flagged: [FlaggedItem] = []
    var step = ""

    var score: Int {
        guard !checks.isEmpty else { return 0 }
        var s = 100.0
        for c in checks {
            switch c.status {
            case .bad: s -= 22
            case .warn: s -= 9
            default: break
            }
        }
        for f in flagged {
            switch f.severity {
            case .threat: s -= 25
            case .caution: s -= 4
            case .info: break
            }
        }
        return Int(max(0, min(100, s)))
    }

    var threats: [FlaggedItem] { flagged.filter { $0.severity == .threat } }

    func scan(apps: UninstallerModel, agents: LaunchAgentsModel) async {
        phase = .scanning
        SoundFX.shared.play(.scanStart)
        step = "Checking macOS protections…"
        checks = await Task.detached { SecurityScanner.systemChecks() }.value
        step = "Checking app signatures…"
        if !apps.loaded { await SoundFX.shared.quietly { await apps.load() } }
        let appList = apps.apps
        let appFlags = await Task.detached { SecurityScanner.flaggedApps(appList) }.value
        step = "Checking background items…"
        if !agents.loaded { await agents.load() }
        let items = agents.items
        let agentFlags = await Task.detached { SecurityScanner.flaggedAgents(items) }.value
        flagged = (appFlags + agentFlags).sorted { $0.severity.rawValue > $1.severity.rawValue }
        withAnimation(.spring(response: 0.5)) { phase = .results }
        SoundFX.shared.play(threats.isEmpty ? .scanDone : .warn)
    }

    func trash(_ item: FlaggedItem) async {
        let result = await Task.detached { Cleaner.remove([.init(url: item.url, size: 0, permanent: false)], source: "Security Check") }.value
        if result.failures.isEmpty {
            withAnimation { flagged.removeAll { $0.id == item.id } }
            SoundFX.shared.play(.clean)
        } else if Cleaner.finderTrash(item.url) {
            withAnimation { flagged.removeAll { $0.id == item.id } }
        }
    }
}
