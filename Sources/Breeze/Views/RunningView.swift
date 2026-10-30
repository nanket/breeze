import SwiftUI

// MARK: - Running

struct RunningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isOnScreen) private var onScreen
    @State private var pending: RunningItem?
    @State private var expanded: Set<String> = []
    private let module = Module.running

    var body: some View {
        let running = model.running
        Group {
            if running.loaded {
                list
            } else {
                ScanningScreen(module: module, title: "Looking at what's running…", detail: "Simulators, VMs, containers, daemons and apps")
            }
        }
        // Live while you're looking at it, every 10 s; nothing runs while the window is closed or covered.
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                await running.load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var list: some View {
        let running = model.running
        let all = running.runtimes + running.apps + running.others
        let maxMemory = max(1, all.map(\.memory).max() ?? 1)
        let idle = running.idleRuntimes
        return VStack(spacing: 0) {
            ModuleHeader(title: "Running", subtitle: subtitle) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await running.load() } }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !idle.isEmpty {
                        IdleBanner(items: idle, colors: module.colors)
                    }
                    if running.runtimes.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(LinearGradient(colors: module.colors, startPoint: .top, endPoint: .bottom))
                            Text("No simulators, VMs, containers, Gradle daemons or project servers running.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                            Spacer(minLength: 0)
                        }
                        .glass(radius: 16, padding: 14)
                    }
                    section("Developer runtimes", note: "Simulators, VMs, containers, daemons and project servers", items: running.runtimes, maxMemory: maxMemory)
                    section("Apps", note: "Helpers counted with their app", items: running.apps, maxMemory: maxMemory)
                    section("Other", note: "Tools not tied to an app or project", items: running.others, maxMemory: maxMemory)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .confirmationDialog(pending.map { "Stop \($0.name)?" } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(pending?.stop.map(stopTitle) ?? "Stop") {
                if let p = pending { Task { await running.stop(p) } }
            }
        } message: {
            if let p = pending, let stop = p.stop {
                Text(([explain(stop, p)] + [p.warning].compactMap { $0 } + ["Runs: \(stop.command)"]).joined(separator: "\n\n"))
            }
        }
        .overlay(alignment: .bottom) {
            if let t = running.toast {
                Toast(text: t, colors: module.colors)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { running.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4), value: running.toast)
    }

    private var subtitle: String {
        let r = model.running
        var parts = ["\(Fmt.memory(r.totalMemory)) in use by what's listed"]
        if !r.runtimes.isEmpty { parts.append(r.runtimes.count == 1 ? "1 developer runtime" : "\(r.runtimes.count) developer runtimes") }
        if let gpu = r.gpuUtilization { parts.append("GPU \(Int(gpu.rounded()))% busy") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func section(_ title: String, note: String, items: [RunningItem], maxMemory: Int64) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("\(items.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                    Spacer()
                    Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                }
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        RunningRow(item: item, maxMemory: maxMemory, depth: 0,
                                   expanded: expanded.contains(item.id),
                                   busy: model.running.busy,
                                   onToggle: { toggle(item.id) },
                                   onStop: { pending = $0 })
                        if expanded.contains(item.id) {
                            ForEach(item.children) { child in
                                Divider().overlay(Theme.stroke).padding(.leading, 76)
                                RunningRow(item: child, maxMemory: maxMemory, depth: 1, expanded: false,
                                           busy: model.running.busy, onToggle: {}, onStop: { pending = $0 })
                            }
                        }
                        if item.id != items.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 58) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func stopTitle(_ stop: RunningItem.Stop) -> String {
        switch stop {
        case .simctl(let ids): ids.count == 1 ? "Shut Down" : "Shut Down All"
        case .quitApp: "Quit"
        default: "Stop"
        }
    }

    private func explain(_ stop: RunningItem.Stop, _ item: RunningItem) -> String {
        switch stop {
        case .simctl(let ids):
            "\(ids.count == 1 ? "The simulator shuts down" : "\(ids.count) simulators shut down"), like pressing the power button. Apps and data on \(ids.count == 1 ? "it" : "them") stay."
        case .colima:
            "Colima shuts its Linux VM down cleanly. Containers inside stop with it; images and volumes stay. `colima start` brings it back."
        case .docker(_, _, let db):
            "Docker asks the container to stop and gives it \(db ? "30" : "10") seconds to finish. It stays on disk; `docker start` brings it back."
        case .gradle:
            "Gradle's daemons of this version finish and exit. Gradle starts a fresh one on your next build."
        case .utm:
            "UTM asks the guest system to shut down, like pressing its power button."
        case .quitApp:
            "\(item.name) is asked to quit, the same as ⌘Q. It may ask you to save first."
        case .terminate(let pids):
            "Asks \(pids.count == 1 ? "the process" : "these \(pids.count) processes") to stop (SIGTERM), like closing the terminal they run in. A dev server that's mid-request drops it."
        }
    }
}

private struct IdleBanner: View {
    let items: [RunningItem]
    let colors: [Color]

    var body: some View {
        let memory = items.reduce(0) { $0 + $1.memory }
        HStack(spacing: 14) {
            GradientIcon(symbol: "moon.zzz", colors: colors, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(items.count == 1 ? "1 runtime looks forgotten" : "\(items.count) runtimes look forgotten")
                    .font(.system(size: 14, weight: .semibold))
                Text("Running for over 6 hours at under 1% CPU, holding \(Fmt.memory(memory)) of memory: \(items.map(\.name).joined(separator: ", ")).")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .glass(radius: 16, padding: 14)
    }
}

private struct RunningRow: View {
    let item: RunningItem
    let maxMemory: Int64
    let depth: Int
    let expanded: Bool
    let busy: Set<String>
    let onToggle: () -> Void
    let onStop: (RunningItem) -> Void
    @State private var hover = false

    private var colors: [Color] { Module.running.colors }

    var body: some View {
        HStack(spacing: 12) {
            disclosure
            icon
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: depth == 0 ? 13 : 12.5, weight: .semibold)).lineLimit(1)
                    if item.isIdle { tag("Idle", symbol: "moon.zzz", color: Color(hex: 0xFFB547)) }
                    if item.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xFFB547))
                            .help(item.warning ?? "")
                    }
                    if let project = item.project { tag(project, symbol: "folder", color: colors[0]) }
                }
                Text(item.detail)
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if hover, let url = item.projectURL ?? item.bundleURL {
                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([url]) }
            }
            stats
            stopButton
        }
        .padding(.leading, depth == 0 ? 14 : 34)
        .padding(.trailing, 14)
        .padding(.vertical, depth == 0 ? 10 : 8)
        .contentShape(Rectangle())
        .onTapGesture { if !item.children.isEmpty { onToggle() } }
        .onHover { hover = $0 }
    }

    @ViewBuilder private var disclosure: some View {
        if depth == 0 {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.children.isEmpty)
            .opacity(item.children.isEmpty ? 0 : 1)
            .accessibilityLabel(expanded ? "Hide what's inside \(item.name)" : "Show what's inside \(item.name)")
        }
    }

    @ViewBuilder private var icon: some View {
        if let url = item.bundleURL {
            FileIcon(url: url, size: depth == 0 ? 32 : 26)
        } else {
            GradientIcon(symbol: item.symbol, colors: item.isIdle ? [Color(hex: 0xFFB547), Color(hex: 0xFF6A3D)] : colors, size: depth == 0 ? 32 : 26)
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.memory(item.memory)).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                SizeBar(fraction: Double(item.memory) / Double(maxMemory), colors: colors, height: 4).frame(width: 70)
            }
            .frame(width: 80, alignment: .trailing)
            .help("Memory: physical footprint, the figure Activity Monitor shows")
            metric(cpuText, label: "CPU").frame(width: 44)
            metric(item.gpu >= 0.5 ? "\(Int(item.gpu.rounded()))%" : "–", label: "GPU").frame(width: 36)
            metric(item.started == nil ? "–" : Fmt.uptime(item.uptime), label: "Up").frame(width: 56)
        }
    }

    private var cpuText: String {
        item.cpu >= 10 ? "\(Int(item.cpu.rounded()))%" : String(format: "%.1f%%", item.cpu)
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            Text(label.uppercased()).font(.system(size: 8.5, weight: .bold)).tracking(0.8).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private var stopButton: some View {
        Group {
            if busy.contains(item.id) {
                ProgressView().controlSize(.small)
            } else if item.stop != nil {
                Button(stopLabel) { onStop(item) }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help(item.stop?.command ?? "")
            } else {
                Color.clear
            }
        }
        .frame(width: 92, alignment: .trailing)
    }

    private var stopLabel: String {
        switch item.stop {
        case .simctl: "Shut Down"
        case .quitApp: "Quit"
        default: "Stop"
        }
    }

    private func tag(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            Text(text).font(.system(size: 10, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}
