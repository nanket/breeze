import SwiftUI

struct JunkView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.junk

    var body: some View {
        let junk = model.junk
        switch junk.phase {
        case .idle:
            IntroScreen(
                module: module,
                headline: "Clear out the clutter your Mac collects.",
                bullets: [
                    Bullet(icon: "archivebox", title: "Caches & logs", text: "Temporary files apps leave behind and quietly rebuild when needed."),
                    Bullet(icon: "hammer", title: "Developer leftovers", text: "Xcode DerivedData, npm, Gradle, CocoaPods, Homebrew and editor caches."),
                    Bullet(icon: "opticaldiscdrive", title: "Old installers", text: "Disk images and packages left in Downloads after installing."),
                ],
                buttonTitle: "Scan"
            ) {
                Task { await junk.scan() }
            }
        case .scanning:
            ScanningScreen(module: module, title: "Looking for junk…", detail: junk.currentPath)
        case .cleaning:
            ScanningScreen(module: module, title: "Cleaning…", detail: "Removing \(junk.selectedCount) items")
        case .done:
            let r = junk.lastResult
            DoneScreen(
                module: module,
                title: "\(Fmt.bytes(r?.cleaned ?? 0)) cleaned",
                subtitle: summary(r),
                primary: "Scan Again",
                primaryAction: { Task { await junk.scan() } },
                secondary: "Done",
                secondaryAction: { withAnimation { junk.reset() } },
                extra: (r?.failures.isEmpty ?? true) ? nil : AnyView(
                    LeftoversCard(failures: r?.failures ?? [], working: junk.removingLeftovers, colors: module.colors) {
                        Task { await junk.removeLeftovers() }
                    }
                )
            )
        case .results:
            JunkResults()
        }
    }

    private func summary(_ r: Cleaner.Result?) -> String {
        guard let r else { return "" }
        var parts = ["\(r.removed) items removed."]
        if r.trashed > 0 { parts.append("\(Fmt.bytes(r.trashed)) is in the Trash if you change your mind.") }
        if !r.failures.isEmpty { parts.append("\(Fmt.bytes(r.leftover)) couldn't be removed — see below.") }
        return parts.joined(separator: " ")
    }
}

private struct JunkResults: View {
    @Environment(AppModel.self) private var model
    private let module = Module.junk

    var body: some View {
        let junk = model.junk
        VStack(spacing: 0) {
            ModuleHeader(title: "System Junk", subtitle: "\(Fmt.bytes(junk.totalFound)) found. Everything safe is already selected.") {
                Button("Rescan") { Task { await junk.scan() } }.buttonStyle(PillButtonStyle())
            }

            if junk.categories.isEmpty {
                EmptyState(icon: "sparkles", title: "Squeaky clean", text: "There's no junk worth removing right now.", colors: module.colors)
            } else {
                FullDiskAccessBanner().padding(.horizontal, 32).padding(.bottom, 12)

                HStack(alignment: .top, spacing: 16) {
                    // Categories
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(junk.categories) { c in
                                CategoryRow(
                                    category: c,
                                    focused: junk.focused?.id == c.id,
                                    maxSize: junk.categories.map(\.totalSize).max() ?? 1,
                                    onFocus: { withAnimation(.spring(response: 0.3)) { junk.focusedID = c.id } },
                                    onToggle: { junk.toggleCategory(c.id) }
                                )
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 330)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))

                    // Detail
                    if let c = junk.focused {
                        CategoryDetail(category: c)
                            .id(c.id)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 32)
            }

            ActionBar(module: module, buttonTitle: "Clean", enabled: junk.totalSelected > 0, action: {
                Task { await junk.clean() }
            }) {
                SelectionSummary(amount: Fmt.bytes(junk.totalSelected), caption: "\(junk.selectedCount) items selected")
            }
        }
    }
}

private struct CategoryRow: View {
    let category: JunkCategory
    let focused: Bool
    let maxSize: Int64
    let onFocus: () -> Void
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            RoundCheck(state: category.checkState, colors: Module.junk.colors)
                .onTapGesture(perform: onToggle)
                .opacity(category.items.isEmpty ? 0.3 : 1)
            GradientIcon(symbol: category.icon, colors: focused ? Module.junk.colors : [.white.opacity(0.16), .white.opacity(0.06)], size: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(category.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if category.denied && category.items.isEmpty {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    } else {
                        Text(Fmt.bytes(category.totalSize))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                SizeBar(fraction: Double(category.totalSize) / Double(max(1, maxSize)), colors: Module.junk.colors, height: 4)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(focused ? 0.1 : (hover ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .onHover { hover = $0 }
    }
}

private struct CategoryDetail: View {
    @Environment(AppModel.self) private var model
    let category: JunkCategory

    var body: some View {
        let safe = UserDefaults.standard.bool(forKey: "safeMode")
        // Simulators are removed by simctl, which can't use the Trash.
        let usesSimctl = category.items.contains { $0.removal != nil }
        let goesToTrash = !category.permanent || (safe && category.id != "trash" && !usesSimctl)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                GradientIcon(symbol: category.icon, colors: Module.junk.colors, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(category.detail).font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(goesToTrash ? "Moved to Trash" : "Deleted permanently",
                          systemImage: goesToTrash ? "trash" : "bolt.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(goesToTrash ? Color(hex: 0x2EE6A8) : Color(hex: 0xFFB547))
                        .padding(.top, 2)
                }
                Spacer()
            }
            .padding(18)

            Divider().overlay(Theme.stroke)

            if category.items.isEmpty {
                EmptyState(
                    icon: category.denied ? "lock.shield" : "checkmark.seal",
                    title: category.denied ? "Needs Full Disk Access" : "Nothing here",
                    text: category.denied ? "macOS protects this folder. Grant Full Disk Access to Breeze, then rescan." : "This area is already clean.",
                    colors: Module.junk.colors
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(category.items) { item in
                            JunkItemRow(item: item) {
                                model.junk.toggleItem(category: category.id, item: item.url)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
    }
}

private struct JunkItemRow: View {
    let item: JunkItem
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            RoundCheck(state: item.selected ? .on : .off, colors: Module.junk.colors, size: 18)
            FileIcon(url: item.url, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(Fmt.shortPath(item.url)).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hover {
                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([item.url]) }
            }
            Text(Fmt.bytes(item.size))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(hover ? Color.white.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal([item.url]) }
        }
    }
}
