import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.largeFiles

    var body: some View {
        let large = model.large
        switch large.phase {
        case .idle:
            IntroScreen(
                module: module,
                headline: "Find the big files you forgot about.",
                bullets: [
                    Bullet(icon: "film", title: "Sorted by size", text: "Old videos, archives and disk images rise straight to the top."),
                    Bullet(icon: "clock.arrow.circlepath", title: "Filter by age", text: "Show only files you haven't opened in months or years."),
                    Bullet(icon: "trash", title: "Always recoverable", text: "Anything you remove goes to the Trash first."),
                ],
                buttonTitle: "Scan"
            ) {
                Task { await large.scan() }
            } footer: {
                SizePicker()
            }
        case .scanning:
            ScanningScreen(
                module: module,
                title: "Scanning your files…",
                detail: large.scanned > 0 ? "\(large.scanned.formatted()) files checked · \(large.currentPath)" : "Starting…",
                onStop: { large.stop() }
            )
        case .cleaning:
            ScanningScreen(module: module, title: "Moving to Trash…", detail: "\(large.selected.count) files")
        case .done:
            let r = large.lastResult
            DoneScreen(
                module: module,
                title: "\(Fmt.bytes(r?.trashed ?? 0)) moved to Trash",
                subtitle: "Empty the Trash when you're sure to get the space back."
                    + ((r?.failures.isEmpty ?? true) ? "" : " \(r!.failures.count == 1 ? "1 file" : "\(r!.failures.count) files") couldn't be moved."),
                primary: "Back to Results",
                primaryAction: { withAnimation { large.phase = .results } },
                secondary: "Scan Again",
                secondaryAction: { Task { await large.scan() } }
            )
        case .results:
            LargeResults()
        }
    }
}

private struct SizePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text("Files larger than").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            ForEach(LargeFilesModel.sizeOptions, id: \.self) { s in
                Chip(title: Fmt.bytes(s), active: model.large.minSize == s, colors: Module.largeFiles.colors) {
                    model.large.minSize = s
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct LargeResults: View {
    @Environment(AppModel.self) private var model
    private let module = Module.largeFiles

    var body: some View {
        @Bindable var large = model.large
        VStack(spacing: 0) {
            ModuleHeader(title: "Large & Old Files", subtitle: "\(large.files.count) files over \(Fmt.bytes(large.minSize)) · \(Fmt.bytes(large.totalSize)) in total") {
                HStack(spacing: 10) {
                    Picker("", selection: $large.age) {
                        ForEach(AgeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    Button("Rescan") { Task { await large.scan() } }.buttonStyle(PillButtonStyle())
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FileKind.allCases) { k in
                        let n = large.count(of: k)
                        if k == .all || n > 0 {
                            Chip(title: k.rawValue, icon: k.icon, count: n, active: large.kind == k, colors: module.colors) {
                                large.kind = k
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 12)

            let files = large.visible
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    RoundCheck(state: large.visibleCheckState, colors: module.colors, size: 18)
                        .onTapGesture { large.toggleAllVisible() }
                    Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                    Text("LAST OPENED").frame(width: 140, alignment: .leading)
                    Text("SIZE").frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1)
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                Divider().overlay(Theme.stroke)

                if files.isEmpty {
                    EmptyState(icon: "doc.text.magnifyingglass", title: "Nothing matches", text: "Try another file type or age filter.", colors: module.colors)
                } else {
                    let maxSize = files.first?.size ?? 1
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(files) { f in
                                LargeFileRow(file: f, maxSize: maxSize) { large.toggle(f.id) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
            .padding(.horizontal, 32)

            ActionBar(module: module, buttonTitle: "Remove", enabled: !large.selected.isEmpty, action: {
                Task { await large.trashSelected() }
            }) {
                SelectionSummary(
                    amount: large.selected.isEmpty ? "None selected" : Fmt.bytes(large.selectedSize),
                    caption: large.selected.isEmpty ? "Select files to move to the Trash" : "\(large.selected.count) files selected"
                )
            }
        }
    }
}

private struct LargeFileRow: View {
    let file: LargeFile
    let maxSize: Int64
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            RoundCheck(state: file.selected ? .on : .off, colors: Module.largeFiles.colors, size: 18)
            FileIcon(url: file.url, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(file.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if hover {
                        IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([file.url]) }
                        IconButton(symbol: "arrow.up.forward.app", help: "Open") { Finder.open(file.url) }
                    }
                }
                Text(Fmt.shortPath(file.url.deletingLastPathComponent()))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.ago(file.lastUsed))
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .frame(width: 140, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.bytes(file.size)).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                SizeBar(fraction: Double(file.size) / Double(max(1, maxSize)), colors: Module.largeFiles.colors, height: 3)
                    .frame(width: 70)
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(file.selected ? Module.largeFiles.colors[0].opacity(0.08) : (hover ? Color.white.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open") { Finder.open(file.url) }
            Button("Reveal in Finder") { Finder.reveal([file.url]) }
        }
    }
}
