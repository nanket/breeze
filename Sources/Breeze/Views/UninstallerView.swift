import SwiftUI

struct UninstallerView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.uninstaller

    var body: some View {
        let apps = model.apps
        if !apps.loaded {
            if apps.loading {
                ScanningScreen(module: module, title: "Finding your apps…", detail: "Reading /Applications")
            } else {
                IntroScreen(
                    module: module,
                    headline: "Remove apps completely, leftovers and all.",
                    bullets: [
                        Bullet(icon: "magnifyingglass", title: "Finds hidden leftovers", text: "Preferences, caches, containers and support files scattered across your Library."),
                        Bullet(icon: "clock.badge.questionmark", title: "Spots unused apps", text: "See which apps you haven't opened in months."),
                        Bullet(icon: "arrow.counterclockwise", title: "Reset instead of remove", text: "Wipe an app's data to fix it while keeping the app itself."),
                    ],
                    buttonTitle: "View Apps"
                ) {
                    Task { await apps.load() }
                }
            }
        } else {
            AppsBrowser()
        }
    }
}

private struct AppsBrowser: View {
    @Environment(AppModel.self) private var model
    private let module = Module.uninstaller

    var body: some View {
        @Bindable var apps = model.apps
        VStack(spacing: 0) {
            ModuleHeader(title: "Uninstaller", subtitle: "\(apps.apps.count) apps · \(Fmt.bytes(apps.totalSize)) · \(apps.unusedCount) unused for 6+ months") {
                if apps.loading { ProgressView().controlSize(.small) }
            }

            HStack(alignment: .top, spacing: 16) {
                // App list
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                        TextField("Search apps", text: $apps.search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))

                    HStack(spacing: 6) {
                        ForEach(AppFilter.allCases) { f in
                            Chip(title: f.rawValue, active: apps.filter == f, colors: module.colors) { apps.filter = f }
                        }
                        Spacer()
                        Menu {
                            Picker("Sort by", selection: $apps.sort) {
                                ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 30)
                    }

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(apps.visible) { app in
                                AppRow(app: app, selected: apps.selectedID == app.id) { apps.select(app) }
                            }
                        }
                    }
                    .disabled(apps.working)
                }
                .padding(12)
                .frame(width: 360)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))

                // Detail
                if let app = apps.selected {
                    AppDetail(app: app)
                        .id(app.id)
                        .transition(.opacity)
                } else {
                    EmptyState(icon: "xmark.app", title: "Pick an app", text: "Choose an app on the left to see everything it installed.", colors: module.colors)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .overlay(alignment: .bottom) {
            if let t = apps.toast {
                Toast(text: t, colors: module.colors)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3.5))
                        withAnimation { apps.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4), value: apps.toast)
    }
}

private struct AppRow: View {
    let app: AppInfo
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            FileIcon(url: app.url, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if app.isUnused {
                        Text("Unused")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color(hex: 0xFF6B8B).opacity(0.25)))
                            .foregroundStyle(Color(hex: 0xFF9FB4))
                    }
                    Text(Fmt.ago(app.lastUsed)).font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Spacer()
            if let s = app.size {
                Text(Fmt.bytes(s)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(LinearGradient(colors: Module.uninstaller.colors.map { $0.opacity(0.28) }, startPoint: .leading, endPoint: .trailing))
                      : AnyShapeStyle(Color.white.opacity(hover ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    let app: AppInfo
    @State private var confirm = false
    private let module = Module.uninstaller

    var body: some View {
        @Bindable var apps = model.apps
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                FileIcon(url: app.url, size: 76)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                    HStack(spacing: 14) {
                        Label(app.size.map(Fmt.bytes) ?? "Measuring…", systemImage: "internaldrive")
                        Label("Last opened \(Fmt.ago(app.lastUsed).lowercased())", systemImage: "clock")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 2)
                }
                Spacer()
                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([app.url]) }
            }
            .padding(20)

            Divider().overlay(Theme.stroke)

            HStack {
                Text("FILES TO REMOVE")
                    .font(.system(size: 10.5, weight: .bold)).tracking(1).foregroundStyle(Theme.faint)
                Spacer()
                Picker("", selection: $apps.keepApp) {
                    Text("Uninstall").tag(false)
                    Text("Reset").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 2) {
                    if !apps.keepApp {
                        LeftoverRow(icon: app.url, title: app.name + ".app", group: "Application", size: app.size ?? 0, state: .on, locked: true) {}
                    }
                    if apps.leftoversLoading {
                        HStack { ProgressView().controlSize(.small); Text("Looking for leftovers…").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                            .padding(16)
                    } else if apps.leftovers.isEmpty {
                        Text(apps.keepApp ? "This app hasn't stored any data in your Library." : "No leftovers found. Just the app itself.")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim).padding(16)
                    } else {
                        ForEach(apps.leftovers) { l in
                            LeftoverRow(icon: l.url, title: l.url.lastPathComponent, group: l.group, size: l.size, state: l.selected ? .on : .off, locked: false) {
                                apps.toggleLeftover(l.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider().overlay(Theme.stroke)

            HStack {
                SelectionSummary(amount: Fmt.bytes(apps.removalSize), caption: apps.keepApp ? "App data to reset" : "Will be moved to the Trash")
                Spacer()
                Button {
                    confirm = true
                } label: {
                    HStack(spacing: 6) {
                        if apps.working { ProgressView().controlSize(.small) }
                        Text(apps.keepApp ? "Reset App" : "Uninstall")
                    }
                    .frame(minWidth: 110)
                }
                .buttonStyle(PillButtonStyle(colors: module.colors))
                .disabled(apps.working || (apps.keepApp && apps.leftovers.filter(\.selected).isEmpty))
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
        .confirmationDialog(apps.keepApp ? "Reset \(app.name)?" : "Uninstall \(app.name)?", isPresented: $confirm) {
            Button(apps.keepApp ? "Reset" : "Uninstall", role: .destructive) { Task { await apps.uninstall() } }
        } message: {
            Text("\(Fmt.bytes(apps.removalSize)) will be moved to the Trash. If \(app.name) is open, it will be quit first.")
        }
    }
}

private struct LeftoverRow: View {
    let icon: URL
    let title: String
    let group: String
    let size: Int64
    let state: CheckState
    let locked: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            RoundCheck(state: state, colors: Module.uninstaller.colors, size: 18)
                .opacity(locked ? 0.6 : 1)
            FileIcon(url: icon, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(group).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }
            Spacer()
            if hover && !locked {
                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([icon]) }
            }
            Text(Fmt.bytes(size)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hover ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if !locked { toggle() } }
        .onHover { hover = $0 }
    }
}
