import SwiftUI

struct DevCleanupView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.devCleanup

    var body: some View {
        let dev = model.dev
        switch dev.phase {
        case .idle:
            IntroScreen(
                module: module,
                headline: "Reclaim the gigabytes your projects rebuild anyway.",
                bullets: [
                    Bullet(icon: "shippingbox.fill", title: "Every stack", text: "node_modules, Unity Library, Pods, Gradle & Flutter builds, Python venvs, Rust target, SwiftPM .build."),
                    Bullet(icon: "clock.badge.checkmark", title: "Only what's stale", text: "Projects you haven't touched in 30 days are pre-selected. Active ones are left alone."),
                    Bullet(icon: "arrow.clockwise", title: "Always recoverable", text: "Each item shows the one command that brings it back."),
                ],
                buttonTitle: "Scan"
            ) {
                Task { await dev.scan() }
            }
        case .scanning:
            ScanningScreen(module: module, title: "Looking through your projects…", detail: dev.currentPath, onStop: { dev.stop() })
        case .cleaning:
            ScanningScreen(module: module, title: "Cleaning…", detail: "Removing \(dev.selected.count) build folders")
        case .done:
            let r = dev.lastResult
            DoneScreen(
                module: module,
                title: "\(Fmt.bytes(r?.cleaned ?? 0)) reclaimed",
                subtitle: "Your projects are intact. Rebuild any of them with its usual install command.",
                primary: "Back to List",
                primaryAction: { withAnimation { dev.phase = .results } },
                secondary: "Scan Again",
                secondaryAction: { Task { await dev.scan() } }
            )
        case .results:
            DevResults()
        }
    }
}

private struct DevResults: View {
    @Environment(AppModel.self) private var model
    private let module = Module.devCleanup

    var body: some View {
        let dev = model.dev
        VStack(spacing: 0) {
            ModuleHeader(title: "Developer Cleanup", subtitle: "\(dev.items.count) build folders · \(Fmt.bytes(dev.totalSize)) total · \(Fmt.bytes(dev.staleSize)) in projects idle 30+ days") {
                HStack(spacing: 8) {
                    Button("Select Stale") { dev.selectStale() }.buttonStyle(PillButtonStyle())
                    Button("Rescan") { Task { await dev.scan() } }.buttonStyle(PillButtonStyle())
                }
            }

            if dev.items.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "No build clutter", text: "No rebuildable project folders over 1 MB were found.", colors: module.colors)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "All", count: dev.items.count, active: dev.kindFilter == nil, colors: module.colors) { dev.kindFilter = nil }
                        ForEach(dev.kinds, id: \.id) { k in
                            Chip(title: k.title, icon: k.icon, count: dev.items.filter { $0.kind == k }.count,
                                 active: dev.kindFilter == k.id, colors: module.colors) { dev.kindFilter = k.id }
                        }
                    }
                    .padding(.horizontal, 32)
                }
                .padding(.bottom, 12)

                let maxSize = dev.items.first?.size ?? 1
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(dev.visible.enumerated()), id: \.element.id) { i, a in
                            ArtifactRow(item: a, maxSize: maxSize, index: i) { dev.toggle(a.id) }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
                }
            }

            ActionBar(module: module, buttonTitle: "Clean", enabled: !dev.selected.isEmpty, action: {
                Task { await dev.clean() }
            }) {
                SelectionSummary(
                    amount: dev.selected.isEmpty ? "None selected" : Fmt.bytes(dev.selectedSize),
                    caption: dev.selected.isEmpty ? "Pick build folders to clear" : "\(dev.selected.count) build folders selected"
                )
            }
        }
    }
}

private struct ArtifactRow: View {
    let item: DevArtifact
    let maxSize: Int64
    let index: Int
    let toggle: () -> Void
    @State private var hover = false
    @State private var shown = false

    var body: some View {
        let c1 = Color(hue: item.kind.hue, saturation: 0.6, brightness: 0.98)
        let c2 = Color(hue: (item.kind.hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.78)
        HStack(spacing: 14) {
            RoundCheck(state: item.selected ? .on : .off, colors: Module.devCleanup.colors, size: 20)
            GradientIcon(symbol: item.kind.icon, colors: [c1, c2], size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.project.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(item.kind.title)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(c1.opacity(0.22)))
                        .foregroundStyle(c1)
                    if item.isStale {
                        Text("Idle").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .foregroundStyle(Theme.dim)
                    }
                }
                Text(Fmt.shortPath(item.url)).font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                if hover {
                    Text("Restore with: \(item.kind.restore)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(c1.opacity(0.9))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.bytes(item.size)).font(.system(size: 14, weight: .bold, design: .rounded))
                SizeBar(fraction: Double(item.size) / Double(max(1, maxSize)), colors: [c1, c2], height: 4).frame(width: 90)
                Text("Edited \(Fmt.ago(item.lastTouched).lowercased())").font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
            if hover {
                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([item.url]) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(item.selected ? c1.opacity(0.09) : Theme.card)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(item.selected ? c1.opacity(0.4) : Theme.stroke))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { h in withAnimation(.spring(response: 0.3)) { hover = h } }
        .offset(y: shown ? 0 : 14)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(min(index, 20)) * 0.03)) { shown = true } }
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal([item.url]) }
            Button("Open Project Folder") { Finder.open(item.project) }
        }
    }
}
