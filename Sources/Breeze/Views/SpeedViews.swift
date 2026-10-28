import SwiftUI

// MARK: - Launch agents

struct LaunchAgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: LaunchItem?
    private let module = Module.optimization

    var body: some View {
        let agents = model.agents
        if !agents.loaded {
            if agents.loading {
                ScanningScreen(module: module, title: "Checking background items…", detail: "Reading LaunchAgents and LaunchDaemons")
            } else {
                IntroScreen(
                    module: module,
                    headline: "Take control of what runs in the background.",
                    bullets: [
                        Bullet(icon: "bolt.horizontal", title: "See every helper", text: "Updaters, sync tools and daemons that start with your Mac."),
                        Bullet(icon: "circle.fill", title: "Know what's running", text: "Live status shows which ones are active right now."),
                        Bullet(icon: "trash", title: "Remove what you don't need", text: "Leftover agents from uninstalled apps are safe to clear out."),
                    ],
                    buttonTitle: "Review"
                ) {
                    Task { await agents.load() }
                }
            }
        } else {
            list
        }
    }

    private var list: some View {
        let agents = model.agents
        return VStack(spacing: 0) {
            ModuleHeader(title: "Launch Agents", subtitle: "\(agents.items.count) background items · \(agents.enabledCount) switched on · \(agents.runningCount) running now") {
                HStack(spacing: 8) {
                    Button("Login Items…") { Permissions.openLoginItemsSettings() }
                        .buttonStyle(PillButtonStyle())
                    IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await agents.load() } }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                        let items = agents.items.filter { $0.scope == scope }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(scope.rawValue).font(.system(size: 15, weight: .bold, design: .rounded))
                                    Text("\(items.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                                    Spacer()
                                    Text(scope.note).font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                                }
                                VStack(spacing: 0) {
                                    ForEach(items) { item in
                                        AgentRow(item: item, busy: agents.busy.contains(item.url),
                                                 onToggle: { on in Task { await agents.setEnabled(item, on) } },
                                                 onRemove: { pending = item })
                                        if item.id != items.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 58) }
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
                            }
                        }
                    }
                    if agents.items.isEmpty {
                        EmptyState(icon: "checkmark.seal", title: "Nothing in the background", text: "No third-party launch agents are installed.", colors: module.colors)
                            .frame(height: 300)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .confirmationDialog("Remove \(pending?.label ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Remove", role: .destructive) {
                if let p = pending { Task { await agents.remove(p) } }
            }
        } message: {
            Text("It will be stopped and its file moved to your Trash. The app that installed it may add it back the next time it runs.")
        }
        .overlay(alignment: .bottom) {
            if let t = agents.toast {
                Toast(text: t, colors: module.colors)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { agents.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4), value: agents.toast)
    }
}

private struct AgentRow: View {
    let item: LaunchItem
    let busy: Bool
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            GradientIcon(
                symbol: item.scope == .daemon ? "gearshape.2" : "bolt.horizontal",
                colors: item.enabled ? Module.optimization.colors : [.white.opacity(0.16), .white.opacity(0.06)],
                size: 32
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(.white.opacity(item.enabled ? 1 : 0.55))
                    status
                }
                Text(item.program.isEmpty ? Fmt.shortPath(item.url) : item.program)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hover {
                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([item.url]) }
                IconButton(symbol: "trash", help: "Remove for good", action: onRemove)
            }
            if busy {
                ProgressView().controlSize(.small).frame(width: 40)
            } else {
                Toggle("", isOn: Binding(get: { item.enabled }, set: { onToggle($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Module.optimization.colors[1])
                    .help(item.enabled ? "Switch off — it won't start again until you switch it back on" : "Switch back on")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    @ViewBuilder private var status: some View {
        if !item.enabled {
            Text("Off").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(.white.opacity(0.08)))
        } else if item.running {
            HStack(spacing: 4) {
                Circle().fill(Color(hex: 0x2EE6A8)).frame(width: 6, height: 6)
                Text("Running").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Color(hex: 0x2EE6A8))
        } else if item.loaded {
            Text("Waiting").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                .help("Loaded, and starts on a schedule or when needed")
        }
    }
}

// MARK: - Maintenance

struct MaintenanceView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.maintenance

    var body: some View {
        let m = model.maintenance
        VStack(spacing: 0) {
            ModuleHeader(title: "Maintenance", subtitle: "Quick fixes for a Mac that feels slow or behaves oddly. Pick what to run.")

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                    ForEach(m.tasks) { t in
                        TaskCard(task: t) { m.toggle(t.id) }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
            }

            ActionBar(module: module, buttonTitle: m.running ? "Running" : "Run", enabled: m.selectedCount > 0 && !m.running, action: {
                Task { await m.runSelected() }
            }) {
                SelectionSummary(
                    amount: "\(m.selectedCount) tasks",
                    caption: m.tasks.contains { $0.selected && $0.admin } ? "You'll be asked for your password once" : "No password needed"
                )
            }
        }
    }
}

private struct TaskCard: View {
    let task: MaintenanceTask
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GradientIcon(symbol: task.icon, colors: task.selected ? Module.maintenance.colors : [.white.opacity(0.16), .white.opacity(0.06)], size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title).font(.system(size: 14, weight: .semibold))
                    if task.admin {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.faint)
                            .help("Needs your admin password")
                    }
                }
                Text(task.detail).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Group {
                switch task.status {
                case .running: ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                        .foregroundStyle(Color(hex: 0x2EE6A8))
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                        .foregroundStyle(Color(hex: 0xFF6B8B))
                        .help("Didn't complete. You may have cancelled the password prompt.")
                case .idle:
                    RoundCheck(state: task.selected ? .on : .off, colors: Module.maintenance.colors)
                }
            }
            .frame(width: 22, height: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 18, padding: 16, highlighted: hover || task.selected)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: Module.maintenance.colors.map { $0.opacity(task.selected ? 0.5 : 0) }, startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}
