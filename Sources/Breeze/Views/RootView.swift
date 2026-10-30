import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 250)

            ZStack {
                ModuleBackground(module: model.module)
                content
                    .id(model.module)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 14)),
                        removal: .opacity
                    ))
            }
            .clipped()
        }
        .background(Theme.base)
        .background(WindowVisibilityReader { model.setOnScreen(window: $0) })
        .ignoresSafeArea()
        .frame(minWidth: 1080, minHeight: 720)
        .preferredColorScheme(.dark)
        .overlay {
            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .sheet(isPresented: Binding(get: { model.showSettings }, set: { model.showSettings = $0 })) {
            SettingsView()
                .environment(model)
        }
        .sheet(isPresented: Binding(get: { model.updater.showSheet }, set: { model.updater.showSheet = $0 })) {
            UpdateSheet()
                .environment(model)
        }
        .sheet(isPresented: Binding(get: { model.showHistory }, set: { model.showHistory = $0 })) {
            HistoryView()
                .environment(model)
        }
        .overlay(alignment: .top) {
            if let report = model.crashReport {
                CrashBanner(report: report) { withAnimation { model.crashReport = nil } }
                    .padding(.top, 14)
                    .padding(.leading, 250)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            model.stats.refresh()
        }
        .environment(\.isOnScreen, model.windowOnScreen)
    }

    @ViewBuilder private var content: some View {
        switch model.module {
        case .smartScan: SmartScanView()
        case .junk: JunkView()
        case .largeFiles: LargeFilesView()
        case .spaceLens: SpaceLensView()
        case .organizer: OrganizerView()
        case .devCleanup: DevCleanupView()
        case .security: SecurityView()
        case .privacy: PrivacyView()
        case .updater: AppUpdatesView()
        case .duplicates: DuplicatesView()
        case .uninstaller: UninstallerView()
        case .optimization: LaunchAgentsView()
        case .maintenance: MaintenanceView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                LogoMark(size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Breeze").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Mac Cleaner").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 48)
            .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SidebarSection.all, id: \.self) { section in
                        if let title = section.title {
                            Text(title.uppercased())
                                .font(.system(size: 10.5, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(Theme.faint)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 1)
                        }
                        ForEach(section.modules) { m in
                            SidebarRow(module: m, selected: model.module == m, badge: model.badge(for: m)) {
                                model.select(m)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)
            DiskFooter()
                .padding(12)
        }
        .background(
            ZStack {
                VisualEffectView(material: .sidebar)
                Color.black.opacity(0.28)
            }
        )
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
        }
    }
}

struct SidebarRow: View {
    let module: Module
    let selected: Bool
    let badge: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                GradientIcon(
                    symbol: module.icon,
                    colors: selected ? module.colors : [.white.opacity(0.14), .white.opacity(0.06)],
                    size: 24
                )
                Text(module.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.78))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(selected ? 0.18 : 0.08)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(selected ? 0.11 : (hover ? 0.05 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onChange(of: selected) { _, _ in hover = false }
        .animation(.spring(response: 0.3), value: badge)
    }
}

struct DiskFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill").foregroundStyle(Theme.dim)
                Text("Macintosh HD").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !model.hasFullDiskAccess {
                    IconButton(symbol: "lock.shield", help: "Grant Full Disk Access") {
                        withAnimation(.spring(response: 0.5)) { model.showOnboarding = true }
                    }
                }
                IconButton(symbol: "gearshape.fill", help: "Settings") { model.showSettings = true }
            }
            SizeBar(
                fraction: s.diskFraction,
                colors: s.diskFraction > 0.9 ? [Color(hex: 0xFF6A3D), Color(hex: 0xFF3D71)] : Theme.brand,
                height: 6
            )
            Text("\(Fmt.bytes(s.diskFree)) available of \(Fmt.bytes(s.diskTotal))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)

        }
        .glass(radius: 14, padding: 12)
    }
}
