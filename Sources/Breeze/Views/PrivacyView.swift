import SwiftUI
import AppKit

struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.privacy

    var body: some View {
        let p = model.privacy
        switch p.phase {
        case .idle:
            IntroScreen(
                module: module,
                headline: "Clear the trail your browsers leave behind.",
                bullets: [
                    Bullet(icon: "globe", title: "Every browser", text: "Safari, Chrome, Brave, Edge, Arc, Vivaldi and Firefox, across all profiles."),
                    Bullet(icon: "slider.horizontal.3", title: "You choose what goes", text: "Caches are pre-selected. History and cookies are yours to pick, since clearing cookies signs you out."),
                    Bullet(icon: "bookmark", title: "Bookmarks and passwords stay", text: "Breeze never touches bookmarks, saved passwords or extensions."),
                ],
                buttonTitle: "Scan"
            ) {
                Task { await p.scan() }
            }
        case .scanning:
            ScanningScreen(module: module, title: "Looking at your browsers…", detail: "Safari · Chrome · Brave · Edge · Arc · Firefox")
        case .cleaning:
            ScanningScreen(module: module, title: "Clearing…", detail: "\(p.selectedCount) items")
        case .done:
            let r = p.lastResult
            DoneScreen(
                module: module,
                title: "\(Fmt.bytes(r?.cleaned ?? 0)) cleared",
                subtitle: (r?.failures.isEmpty ?? true) ? "Your browsing traces are gone." : "\(r?.failures.count ?? 0) items couldn't be removed. Is the browser still open?",
                primary: "Scan Again",
                primaryAction: { Task { await p.scan() } },
                secondary: "Done",
                secondaryAction: { withAnimation { p.phase = .idle } }
            )
        case .results:
            PrivacyResults()
        }
    }
}

private struct PrivacyResults: View {
    @Environment(AppModel.self) private var model
    private let module = Module.privacy

    var body: some View {
        let p = model.privacy
        VStack(spacing: 0) {
            ModuleHeader(title: "Privacy", subtitle: "\(p.sources.count) sources found. Pick what to clear.") {
                Button("Rescan") { Task { await p.scan() } }.buttonStyle(PillButtonStyle())
            }
            if p.sources.isEmpty {
                EmptyState(icon: "hand.raised", title: "Nothing to clear", text: "No browser data was found. Grant Full Disk Access to include Safari.", colors: module.colors)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(p.sources) { s in SourceCard(source: s) }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
                }
            }
            ActionBar(module: module, buttonTitle: "Clear", enabled: p.selectedCount > 0 && p.blocking.isEmpty, action: {
                Task { await p.clean() }
            }) {
                SelectionSummary(
                    amount: p.selectedCount == 0 ? "None selected" : Fmt.bytes(p.selectedSize),
                    caption: p.blocking.isEmpty ? "\(p.selectedCount) items selected" : "Quit \(p.blocking.map(\.name).joined(separator: ", ")) first"
                )
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            p.refreshRunning()
        }
    }
}

private struct SourceCard: View {
    @Environment(AppModel.self) private var model
    let source: PrivacySource

    var body: some View {
        let p = model.privacy
        let isRunning = source.bundleID.map { p.running.contains($0) } ?? false
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let bid = source.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    FileIcon(url: url, size: 34)
                } else {
                    GradientIcon(symbol: "applelogo", colors: Module.privacy.colors, size: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(Fmt.bytes(source.items.reduce(0) { $0 + $1.size })).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                }
                Spacer()
                if isRunning {
                    Button("Quit \(source.name)") { Task { await p.quit(source) } }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
            ForEach(source.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    RoundCheck(state: item.selected ? .on : .off, colors: Module.privacy.colors, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Image(systemName: item.kind.icon).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                            Text(item.kind.rawValue).font(.system(size: 12.5, weight: .medium))
                        }
                        Text(item.kind.note).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    Text(Fmt.bytes(item.size)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
                }
                .contentShape(Rectangle())
                .onTapGesture { p.toggle(item) }
            }
            if let note = source.note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }
            if isRunning && source.items.contains(where: \.selected) {
                Label("\(source.name) is open. Quit it so its files can be cleared.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Color(hex: 0xFFB547))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 18, padding: 16)
    }
}
