import SwiftUI
import AppKit

struct SpaceLensView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.spaceLens

    var body: some View {
        let lens = model.lens
        if lens.trail.isEmpty {
            IntroScreen(
                module: module,
                headline: "See exactly where your space went.",
                bullets: [
                    Bullet(icon: "circle.circle", title: "Orbit & Map views", text: "Rings show every folder and what's inside it, drawn to scale. Or flip to a block map."),
                    Bullet(icon: "arrow.down.right.circle", title: "Dive in", text: "Click any folder to drill down. Sizes fill in live as they're measured."),
                    Bullet(icon: "trash", title: "Tidy as you go", text: "Select anything and send it to the Trash without leaving the map."),
                ],
                buttonTitle: "Explore"
            ) {
                lens.start(at: FileManager.default.homeDirectoryForCurrentUser)
            } footer: {
                HStack(spacing: 8) {
                    Button("Whole disk") { lens.start(at: URL(fileURLWithPath: "/")) }
                        .buttonStyle(PillButtonStyle(compact: true))
                    Button("Choose folder…") { choose() }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
                .padding(.top, 6)
            }
        } else {
            LensBrowser(choose: choose)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Explore"
        if panel.runModal() == .OK, let url = panel.url {
            model.lens.start(at: url)
        }
    }
}

private struct LensBrowser: View {
    @Environment(AppModel.self) private var model
    let choose: () -> Void
    @State private var confirm = false
    @AppStorage("lensStyle") private var style: LensStyle = .orbit
    private let module = Module.spaceLens

    var body: some View {
        let lens = model.lens
        VStack(spacing: 0) {
            // Header with breadcrumb
            HStack(spacing: 10) {
                IconButton(symbol: "chevron.left", help: "Back") { lens.back() }
                    .disabled(lens.trail.count < 2)
                    .opacity(lens.trail.count < 2 ? 0.35 : 1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(lens.trail.enumerated()), id: \.offset) { i, url in
                            if i > 0 {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                            }
                            Button {
                                lens.jump(to: i)
                            } label: {
                                Text(displayName(url))
                                    .font(.system(size: i == lens.trail.count - 1 ? 20 : 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(i == lens.trail.count - 1 ? 1 : 0.55))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(LensStyle.allCases) { st in
                        Chip(title: st.rawValue, icon: st.icon, active: style == st, colors: module.colors) {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { style = st }
                        }
                    }
                }
                .padding(3)
                .background(Capsule().fill(.white.opacity(0.05)))
                if lens.loading {
                    ProgressView().controlSize(.small)
                    Text("Measuring \(lens.measured)/\(lens.nodes.count)")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                        .contentTransition(.numericText())
                } else {
                    Text(Fmt.bytes(lens.total)).font(.system(size: 14, weight: .bold, design: .rounded))
                }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { lens.refresh() }
                Menu {
                    Button("Home Folder") { lens.start(at: FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Whole Disk") { lens.start(at: URL(fileURLWithPath: "/")) }
                    Divider()
                    Button("Choose Folder…", action: choose)
                } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 16)

            HStack(spacing: 16) {
                ZStack {
                    if style == .orbit {
                        OrbitView()
                            .id(lens.current)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.6).combined(with: .opacity),
                                removal: .scale(scale: 1.25).combined(with: .opacity)
                            ))
                    } else {
                        Treemap()
                            .id(lens.current)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                LensList()
                    .frame(width: 330)
            }
            .padding(.horizontal, 32)

            ActionBar(module: module, buttonTitle: "Remove", enabled: !lens.selected.isEmpty, action: { confirm = true }) {
                SelectionSummary(
                    amount: lens.selected.isEmpty ? "None selected" : Fmt.bytes(lens.selectedSize),
                    caption: lens.selected.isEmpty ? "Select items in the list to remove them" : "\(lens.selected.count) items selected"
                )
            }
        }
        .confirmationDialog("Move \(lens.selected.count) items to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { Task { await lens.trashSelected() } }
        } message: {
            Text(lens.selected.map(\.name).prefix(6).joined(separator: ", ") + (lens.selected.count > 6 ? "…" : ""))
        }
    }

    private func displayName(_ url: URL) -> String {
        if url.path == "/" { return "Macintosh HD" }
        if url.path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
        return url.lastPathComponent
    }
}

private struct Treemap: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lens = model.lens
        let items = lens.sortedNodes.filter { ($0.size ?? 0) > 0 }.prefix(36)
        let total = Double(items.reduce(0) { $0 + ($1.size ?? 0) })
        GeometryReader { g in
            let rects = TreemapLayout.layout(items.map { ($0.url, Double($0.size ?? 0)) }, in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                if items.isEmpty {
                    EmptyState(
                        icon: lens.loading ? "hourglass" : "folder",
                        title: lens.loading ? "Measuring…" : "Empty folder",
                        text: lens.loading ? "Sizes appear as each folder is measured." : "Nothing to show here.",
                        colors: Module.spaceLens.colors
                    )
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, node in
                    if let r = rects[node.url] {
                        TreemapTile(
                            node: node, index: i,
                            share: total > 0 ? Double(node.size ?? 0) / total : 0,
                            hovered: lens.hovered == node.url
                        )
                        .frame(width: max(0, r.width - 4), height: max(0, r.height - 4))
                        .offset(x: r.minX + 2, y: r.minY + 2)
                        .onHover { h in lens.hovered = h ? node.url : (lens.hovered == node.url ? nil : lens.hovered) }
                        .onTapGesture { if node.isDirectory { lens.enter(node.url) } }
                        .contextMenu {
                            if node.isDirectory { Button("Open") { lens.enter(node.url) } }
                            Button("Reveal in Finder") { Finder.reveal([node.url]) }
                            Button(node.selected ? "Deselect" : "Select for Removal") { lens.toggle(node.url) }
                        }
                    }
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: rects.count)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
    }
}

private struct TreemapTile: View {
    let node: LensNode
    let index: Int
    let share: Double
    let hovered: Bool
    @State private var shown = false

    private var colors: [Color] {
        let palette: [[Color]] = [
            [Color(hex: 0x4FACFE), Color(hex: 0x6A5BFF)],
            [Color(hex: 0x6A5BFF), Color(hex: 0xB26BFF)],
            [Color(hex: 0x2EE6A8), Color(hex: 0x1FA2FF)],
            [Color(hex: 0x00C6FB), Color(hex: 0x005BEA)],
            [Color(hex: 0x8E7CFF), Color(hex: 0x4FACFE)],
            [Color(hex: 0x43E97B), Color(hex: 0x38F9D7)],
        ]
        return palette[index % palette.count]
    }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: colors.map { $0.opacity(hovered ? 0.95 : 0.72) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(node.selected ? 0.95 : (hovered ? 0.5 : 0.15)), lineWidth: node.selected ? 2.5 : 1)

                if g.size.width > 64 && g.size.height > 38 {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        if g.size.height > 54 {
                            Text(Fmt.bytes(node.size ?? 0))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .opacity(0.85)
                        }
                        if g.size.height > 90 && g.size.width > 110 {
                            Spacer()
                            Text(share.formatted(.percent.precision(.fractionLength(0))))
                                .font(.system(size: min(34, g.size.height * 0.22), weight: .bold, design: .rounded))
                                .opacity(0.9)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(9)
                }
                if node.selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
        }
        .scaleEffect(shown ? (hovered ? 0.985 : 1) : 0.7)
        .opacity(shown ? 1 : 0)
        .animation(.spring(response: 0.25), value: hovered)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75).delay(Double(min(index, 30)) * 0.025)) { shown = true }
        }
        .help("\(node.name) — \(Fmt.bytes(node.size ?? 0))")
    }
}

private struct LensList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lens = model.lens
        let nodes = lens.sortedNodes
        let maxSize = nodes.first?.size ?? 1
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(nodes) { n in
                    LensRow(node: n, maxSize: maxSize, hovered: lens.hovered == n.url)
                        .onHover { h in lens.hovered = h ? n.url : nil }
                }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
    }
}

private struct LensRow: View {
    @Environment(AppModel.self) private var model
    let node: LensNode
    let maxSize: Int64
    let hovered: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundCheck(state: node.selected ? .on : .off, colors: Module.spaceLens.colors, size: 17)
                .onTapGesture { model.lens.toggle(node.url) }
            FileIcon(url: node.url, size: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer()
                    if let s = node.size {
                        Text(Fmt.bytes(s)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                SizeBar(fraction: Double(node.size ?? 0) / Double(max(1, maxSize)), colors: Module.spaceLens.colors, height: 3)
            }
            if node.isDirectory {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovered ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory { model.lens.enter(node.url) } else { model.lens.toggle(node.url) }
        }
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal([node.url]) }
            Button(node.selected ? "Deselect" : "Select for Removal") { model.lens.toggle(node.url) }
        }
    }
}

/// Binary-split treemap: recursively divides items into two halves of roughly equal
/// weight along the longer side. Simple, stable, and gives readable aspect ratios.
enum TreemapLayout {
    static func layout(_ items: [(URL, Double)], in rect: CGRect) -> [URL: CGRect] {
        var out: [URL: CGRect] = [:]
        split(items[...], rect, &out)
        return out
    }

    private static func split(_ items: ArraySlice<(URL, Double)>, _ rect: CGRect, _ out: inout [URL: CGRect]) {
        guard let first = items.first else { return }
        if items.count == 1 { out[first.0] = rect; return }
        let total = items.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return }

        var acc = 0.0
        var mid = items.startIndex + 1
        for i in items.indices {
            acc += items[i].1
            if acc >= total / 2 { mid = i + 1; break }
        }
        mid = min(max(mid, items.startIndex + 1), items.endIndex - 1)

        let a = items[items.startIndex..<mid]
        let b = items[mid..<items.endIndex]
        let frac = a.reduce(0) { $0 + $1.1 } / total

        if rect.width >= rect.height {
            let w = rect.width * frac
            split(a, CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), &out)
            split(b, CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height), &out)
        } else {
            let h = rect.height * frac
            split(a, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h), &out)
            split(b, CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h), &out)
        }
    }
}
