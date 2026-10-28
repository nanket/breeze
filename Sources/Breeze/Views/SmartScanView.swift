import SwiftUI

struct SmartScanView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Lifetime.key) private var lifetime: Double = 0

    var body: some View {
        switch model.smartPhase {
        case .idle:
            idle
        case .scanning:
            ScanningScreen(module: .smartScan, title: model.smartStep + "…", detail: model.smartStatus)
        case .results:
            results
        case .cleaning:
            ScanningScreen(module: .smartScan, title: "Cleaning up…", detail: "Removing \(Fmt.bytes(model.junk.totalSelected)) of junk")
        case .done:
            let r = model.smartResult
            DoneScreen(
                module: .smartScan,
                title: "\(Fmt.bytes(r?.cleaned ?? 0)) cleaned",
                subtitle: doneSubtitle(r),
                primary: "Scan Again",
                primaryAction: { Task { await model.runSmartScan() } },
                secondary: "Back to Overview",
                secondaryAction: { withAnimation { model.smartPhase = .idle } },
                extra: (model.junk.lastResult?.failures.isEmpty ?? true) ? nil : AnyView(
                    LeftoversCard(failures: model.junk.lastResult?.failures ?? [], working: model.junk.removingLeftovers, colors: Module.smartScan.colors) {
                        Task {
                            await model.junk.removeLeftovers()
                            model.smartResult = model.junk.lastResult
                        }
                    }
                )
            )
        }
    }

    private func doneSubtitle(_ r: Cleaner.Result?) -> String {
        guard let r else { return "" }
        var s = "\(r.removed) items removed."
        if r.trashed > 0 { s += " \(Fmt.bytes(r.trashed)) went to the Trash so you can still restore it." }
        if !r.failures.isEmpty { s += " \(Fmt.bytes(r.leftover)) couldn't be removed — see below." }
        return s
    }

    // MARK: Idle

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
    }

    private var idle: some View {
        let s = model.stats
        return VStack(spacing: 0) {
            ModuleHeader(title: greeting, subtitle: "\(s.macName) · \(s.chip) · \(s.osVersion)")

            HStack(alignment: .top, spacing: 16) {
                HealthCard(report: model.health) { m in model.select(m) }
                    .frame(width: 300)
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        StatCard(
                            title: "Storage", icon: "internaldrive",
                            value: Fmt.bytes(s.diskFree), caption: "free of \(Fmt.bytes(s.diskTotal))",
                            fraction: s.diskFraction, colors: Module.spaceLens.colors
                        )
                        StatCard(
                            title: "Memory", icon: "memorychip",
                            value: Fmt.memory(Int64(s.memUsed)), caption: "used of \(Fmt.memory(Int64(s.memTotal)))",
                            fraction: s.memFraction, colors: Module.junk.colors
                        )
                    }
                    HStack(spacing: 12) {
                        CPUCard(load: s.cpu, history: s.cpuHistory)
                        StatCard(
                            title: "Uptime", icon: "clock",
                            value: Fmt.uptime(s.uptime), caption: s.uptime > 7 * 86_400 ? "A restart might help" : "since last restart",
                            fraction: min(1, s.uptime / (14 * 86_400)), colors: Module.largeFiles.colors
                        )
                    }
                }
            }
            .padding(.horizontal, 32)

            Spacer()
            VStack(spacing: 10) {
                Text("Let's make your Mac feel new.")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Smart Scan checks for junk, large forgotten files and unused apps in one go.\nNothing is removed until you say so.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
                if lifetime > 0 {
                    Label("Breeze has freed \(Fmt.bytes(Int64(lifetime))) on this Mac so far", systemImage: "leaf.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: Module.junk.colors, startPoint: .leading, endPoint: .trailing))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.06)))
                        .padding(.top, 4)
                }
            }
            Spacer()

            ActionButton(title: "Scan", colors: Module.smartScan.colors, size: 128) {
                Task { await model.runSmartScan() }
            }
            .padding(.bottom, 48)
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            ModuleHeader(title: "Here's what we found", subtitle: "Review any area, or clean the junk right away.") {
                Button("Start Over") { withAnimation { model.smartPhase = .idle } }
                    .buttonStyle(PillButtonStyle())
            }

            FullDiskAccessBanner().padding(.horizontal, 32).padding(.bottom, 12)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ResultTile(
                    module: .junk, headline: Fmt.bytes(model.junk.totalSelected),
                    caption: "of junk is ready to be cleaned",
                    detail: "\(model.junk.selectedCount) items across \(model.junk.categories.filter { $0.selectedCount > 0 }.count) categories",
                    action: { model.select(.junk) }
                )
                ResultTile(
                    module: .largeFiles, headline: "\(model.large.files.count) files",
                    caption: "over \(Fmt.bytes(model.large.minSize)) · \(Fmt.bytes(model.large.totalSize)) total",
                    detail: "Review and decide what to keep",
                    action: { model.select(.largeFiles) }
                )
                ResultTile(
                    module: .uninstaller, headline: "\(model.apps.unusedCount) apps",
                    caption: "haven't been opened in 6+ months",
                    detail: "\(model.apps.apps.count) apps installed · \(Fmt.bytes(model.apps.totalSize))",
                    action: {
                        model.apps.filter = .unused
                        model.select(.uninstaller)
                    }
                )
                ResultTile(
                    module: .optimization, headline: "\(model.agents.enabledCount) on",
                    caption: "background items start with your Mac",
                    detail: "\(model.agents.items.count) launch agents and daemons installed",
                    action: { model.select(.optimization) }
                )
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 8)

            ActionBar(module: .smartScan, buttonTitle: "Clean", enabled: model.junk.totalSelected > 0, action: {
                Task { await model.runSmartClean() }
            }) {
                SelectionSummary(amount: Fmt.bytes(model.junk.totalSelected), caption: "Junk selected for cleaning")
            }
        }
    }
}

private struct StatCard: View {
    let title: String
    let icon: String
    let value: String
    let caption: String
    let fraction: Double
    let colors: [Color]

    var body: some View {
        HStack(spacing: 16) {
            RingGauge(fraction: fraction, colors: colors, lineWidth: 8) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.faint)
                Text(value)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .glass()
    }
}

private struct ResultTile: View {
    let module: Module
    let headline: String
    let caption: String
    let detail: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                GradientIcon(symbol: module.icon, colors: module.colors, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.title.uppercased())
                        .font(.system(size: 10.5, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(module.gradient)
                    Text(headline)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(caption).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.top, 2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(hover ? 0.9 : 0.35))
                    .offset(x: hover ? 3 : 0)
                    .padding(.top, 4)
            }
            .glass(radius: 20, padding: 20, highlighted: hover)
            .contentShape(Rectangle())
            .scaleEffect(hover ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3)) { hover = h } }
    }
}


private struct HealthCard: View {
    let report: HealthReport
    let go: (Module) -> Void
    @State private var shown = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                RingGauge(fraction: Double(report.score) / 100 * shown, colors: report.colors, lineWidth: 11) {
                    VStack(spacing: 0) {
                        Text("\(Int(Double(report.score) * shown))")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                        Text("of 100").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.faint)
                    }
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MAC HEALTH").font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundStyle(Theme.faint)
                    Text(report.label)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: report.colors, startPoint: .leading, endPoint: .trailing))
                    Text(report.issues.isEmpty ? "Nothing needs attention." : "\(report.issues.count) thing\(report.issues.count == 1 ? "" : "s") to look at")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                }
            }
            ForEach(report.issues.prefix(3)) { issue in
                Button {
                    if let m = issue.module { go(m) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: issue.icon).font(.system(size: 11)).frame(width: 16).foregroundStyle(report.colors[0])
                        Text(issue.text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        Spacer()
                        if issue.module != nil {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
        .onAppear { withAnimation(.spring(response: 1.2, dampingFraction: 0.85).delay(0.15)) { shown = 1 } }
    }
}

private struct CPUCard: View {
    let load: Double
    let history: [Double]

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CPU").font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundStyle(Theme.faint)
                Text(load.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("in use right now").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 0)
            Sparkline(values: history, colors: Module.smartScan.colors)
                .frame(width: 90, height: 44)
        }
        .frame(maxWidth: .infinity)
        .glass()
        .animation(.easeOut(duration: 0.4), value: load)
    }
}

struct Sparkline: View {
    let values: [Double]
    let colors: [Color]

    var body: some View {
        GeometryReader { g in
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(1, values.count - 1)),
                        y: g.size.height * (1 - CGFloat(min(1, max(0, v)))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last?.x ?? 0, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [colors[0].opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
