import SwiftUI
import AppKit

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.duplicates

    var body: some View {
        let d = model.dupes
        switch d.phase {
        case .idle:
            IntroScreen(
                module: module,
                headline: "Find every file you've saved twice.",
                bullets: [
                    Bullet(icon: "checkmark.shield", title: "Byte-for-byte exact", text: "Compared by content, not name, so only true copies are matched."),
                    Bullet(icon: "hand.tap", title: "You pick the keeper", text: "The oldest copy is kept by default. Click any other copy to keep that one instead."),
                    Bullet(icon: "trash", title: "Safe removal", text: "Extra copies go to the Trash, and Breeze never removes the last one."),
                ],
                buttonTitle: "Scan"
            ) {
                Task { await d.scan() }
            } footer: {
                DupOptions()
            }
        case .scanning:
            VStack(spacing: 18) {
                ScanningScreen(module: module, title: d.progress > 0 ? "Comparing contents…" : "Collecting files…", detail: d.currentPath, onStop: { d.stop() })
            }
            .overlay(alignment: .bottom) {
                if d.progress > 0 {
                    SizeBar(fraction: d.progress, colors: module.colors, height: 6)
                        .frame(width: 320)
                        .padding(.bottom, 120)
                        .animation(.easeOut, value: d.progress)
                }
            }
        case .cleaning:
            ScanningScreen(module: module, title: "Moving copies to Trash…", detail: "\(d.removingCount) files")
        case .done:
            let r = d.lastResult
            DoneScreen(
                module: module,
                title: "\(Fmt.bytes(r?.cleaned ?? 0)) of copies removed",
                subtitle: "\(r?.removed ?? 0) duplicate files are in the Trash. Empty it when you're happy.",
                primary: d.groups.isEmpty ? "Scan Again" : "Back to Results",
                primaryAction: {
                    if d.groups.isEmpty { _ = Task { await d.scan() } } else { withAnimation { d.phase = .results } }
                },
                secondary: "Done",
                secondaryAction: { withAnimation { d.phase = .idle } }
            )
        case .results:
            DupResults()
        }
    }
}

private struct DupOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.dupes
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Look in").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                Chip(title: d.rootsLabel, icon: "folder", active: true, colors: Module.duplicates.colors) {}
                Button("Change…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.prompt = "Search Here"
                    if panel.runModal() == .OK, !panel.urls.isEmpty { d.roots = panel.urls }
                }
                .buttonStyle(PillButtonStyle(compact: true))
            }
            HStack(spacing: 8) {
                Text("Ignore files under").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                ForEach(DuplicatesModel.sizeOptions, id: \.self) { s in
                    Chip(title: Fmt.bytes(s), active: d.minSize == s, colors: Module.duplicates.colors) { d.minSize = s }
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct DupResults: View {
    @Environment(AppModel.self) private var model
    private let module = Module.duplicates

    var body: some View {
        let d = model.dupes
        VStack(spacing: 0) {
            ModuleHeader(title: "Duplicates", subtitle: "\(d.groups.count) sets of identical files · \(Fmt.bytes(d.wasted)) taken by extra copies") {
                Button("Rescan") { Task { await d.scan() } }.buttonStyle(PillButtonStyle())
            }
            if d.groups.isEmpty {
                EmptyState(icon: "sparkles", title: "No duplicates", text: "Every file in \(d.rootsLabel) is one of a kind.", colors: module.colors)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(d.groups) { g in
                            DupGroupCard(group: g, expanded: d.expanded.contains(g.id))
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
                }
            }
            ActionBar(module: module, buttonTitle: "Remove", enabled: d.removingCount > 0, action: {
                Task { await d.clean() }
            }) {
                SelectionSummary(
                    amount: d.removingCount == 0 ? "None selected" : Fmt.bytes(d.removingSize),
                    caption: d.removingCount == 0 ? "Pick copies to remove" : "\(d.removingCount) extra copies to the Trash"
                )
            }
        }
    }
}

private struct DupGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: DupGroup
    let expanded: Bool

    var body: some View {
        let d = model.dupes
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { d.toggleExpanded(group.id) }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        FileIcon(url: group.files[0].url, size: 34).offset(x: 5, y: -4).opacity(0.5)
                        FileIcon(url: group.files[0].url, size: 34)
                    }
                    .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Text("\(group.files.count) copies × \(Fmt.bytes(group.size))")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.bytes(group.wasted)).font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("wasted").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.files) { f in
                        HStack(spacing: 10) {
                            RoundCheck(state: f.remove ? .on : .off, colors: Module.duplicates.colors, size: 18)
                                .onTapGesture { d.toggle(f, in: group) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Fmt.shortPath(f.url.deletingLastPathComponent()))
                                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text("Modified \(Fmt.ago(f.modified).lowercased())").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            if !f.remove {
                                Label("Keeping", systemImage: "star.fill")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(Color(hex: 0xFFD166))
                            } else {
                                Button("Keep this") { d.keep(f, in: group) }
                                    .buttonStyle(PillButtonStyle(compact: true))
                            }
                            IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([f.url]) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(f.remove ? Module.duplicates.colors[0].opacity(0.06) : .clear)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
