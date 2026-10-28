import SwiftUI

struct AppUpdatesView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.updater

    var body: some View {
        let u = model.updates
        switch u.phase {
        case .idle, .cleaning, .done:
            IntroScreen(
                module: module,
                headline: "Keep every app up to date in one place.",
                bullets: [
                    Bullet(icon: "arrow.triangle.2.circlepath", title: "Developer updates", text: "Checks each app's own update feed, the same one the app uses itself."),
                    Bullet(icon: "mug", title: "Homebrew apps", text: "Finds outdated casks and updates them with one click."),
                    Bullet(icon: "bag", title: "App Store apps", text: "Jumps straight to the App Store's Updates page."),
                ],
                buttonTitle: "Check"
            ) {
                Task { await u.scan(apps: model.apps) }
            }
        case .scanning:
            ScanningScreen(module: module, title: "Checking for updates…", detail: "Asking each app's update feed")
        case .results:
            UpdatesResults()
        }
    }
}

private struct UpdatesResults: View {
    @Environment(AppModel.self) private var model
    private let module = Module.updater

    var body: some View {
        let u = model.updates
        VStack(spacing: 0) {
            ModuleHeader(title: "Updater", subtitle: "\(u.updates.count) updates available · \(u.checkedCount) apps checked") {
                HStack(spacing: 8) {
                    if u.appStoreCount > 0 {
                        Button("App Store Updates (\(u.appStoreCount) apps)") { u.openAppStore() }.buttonStyle(PillButtonStyle())
                    }
                    Button("Check Again") { Task { await u.scan(apps: model.apps) } }.buttonStyle(PillButtonStyle())
                }
            }
            if u.updates.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Everything's up to date", text: u.hasBrew ? "All apps with update feeds and Homebrew casks are current." : "All apps with update feeds are current.", colors: module.colors)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(u.updates) { up in UpdateRow(update: up) }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

private struct UpdateRow: View {
    @Environment(AppModel.self) private var model
    let update: AppUpdate

    var body: some View {
        let u = model.updates
        HStack(spacing: 14) {
            if let url = update.appURL {
                FileIcon(url: url, size: 40)
            } else {
                GradientIcon(symbol: "mug.fill", colors: [Color(hex: 0xFBB040), Color(hex: 0xF15A24)], size: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(update.name).font(.system(size: 14, weight: .semibold))
                    Text(update.channel.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .foregroundStyle(Theme.dim)
                }
                HStack(spacing: 6) {
                    Text(update.installed).foregroundStyle(Theme.faint)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                    Text(update.latest).foregroundStyle(LinearGradient(colors: Module.updater.colors, startPoint: .leading, endPoint: .trailing))
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                if case .failed(let msg) = update.status {
                    Text(msg).font(.system(size: 11)).foregroundStyle(Color(hex: 0xFF8A5B))
                }
            }
            Spacer()
            switch update.status {
            case .updating:
                ProgressView().controlSize(.small)
            case .done:
                Label(update.channel == .homebrew ? "Updated" : "Opened", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x2EE6A8))
            default:
                if update.channel == .sparkle, update.downloadURL != nil {
                    Button("Download") { u.download(update) }.buttonStyle(PillButtonStyle(compact: true))
                }
                Button(update.channel == .homebrew ? "Update" : "Open to Update") { Task { await u.update(update) } }
                    .buttonStyle(PillButtonStyle(colors: Module.updater.colors, compact: true))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }
}
