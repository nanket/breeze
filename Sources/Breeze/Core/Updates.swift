import SwiftUI

/// Checks a small JSON feed (docs/appcast.json) for a newer Breeze and offers the download.
@MainActor
@Observable
final class SelfUpdater {
    struct Release: Decodable, Equatable {
        let version: String
        let build: Int
        let url: URL
        let notes: String?
        let minimumOS: String?
    }

    nonisolated static let autoKey = "checkForUpdates"
    private static let lastCheckKey = "updateCheckedAt"
    private static let skipKey = "updateSkippedBuild"

    var available: Release?
    var checking = false
    var lastMessage: String?
    var showSheet = false

    var autoCheck: Bool { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }

    /// Once a day at most, quietly.
    func checkIfDue() async {
        guard autoCheck, AppConfig.isConfigured else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        guard AppConfig.isConfigured else {
            lastMessage = "Update feed isn't set up yet (see AppConfig.swift)."
            return
        }
        checking = true
        defer { checking = false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        do {
            var req = URLRequest(url: AppConfig.updateFeedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.setValue("\(AppConfig.appName)/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            let r = try JSONDecoder().decode(Release.self, from: data)
            if let min = r.minimumOS, Self.osVersion.compare(min, options: .numeric) == .orderedAscending {
                lastMessage = "Breeze \(r.version) needs macOS \(min) or later."
                return
            }
            let skipped = UserDefaults.standard.integer(forKey: Self.skipKey)
            if r.build > AppConfig.build && (userInitiated || r.build != skipped) {
                available = r
                showSheet = true
                lastMessage = "Breeze \(r.version) is available."
            } else {
                available = nil
                lastMessage = "You're on the latest version (\(AppConfig.version))."
            }
        } catch {
            lastMessage = userInitiated ? "Couldn't check for updates. Try again later." : nil
            CleanLog.log("Update check failed: \(error.localizedDescription)")
        }
    }

    func skipThisVersion() {
        if let a = available { UserDefaults.standard.set(a.build, forKey: Self.skipKey) }
        showSheet = false
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let u = model.updater
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                LogoMark(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A new version of Breeze is ready").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Version \(u.available?.version ?? "") · you have \(AppConfig.version)")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
            }
            if let notes = u.available?.notes, !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .glass(radius: 12, padding: 12)
            }
            HStack {
                Button("Skip This Version") { u.skipThisVersion() }.buttonStyle(PillButtonStyle(compact: true))
                Spacer()
                Button("Later") { dismiss() }.buttonStyle(PillButtonStyle())
                Button("Download") {
                    if let url = u.available?.url { NSWorkspace.shared.open(url) }
                    dismiss()
                }
                .buttonStyle(PillButtonStyle(colors: Theme.brand))
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.base)
        .preferredColorScheme(.dark)
    }
}
