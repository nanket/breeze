import SwiftUI
import AppKit

struct OrganizerView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.organizer

    var body: some View {
        let org = model.organizer
        switch org.phase {
        case .idle:
            IntroScreen(
                module: module,
                headline: "Turn a messy folder into a tidy one.",
                bullets: [
                    Bullet(icon: "square.grid.2x2", title: "Sort by type or month", text: "Images, videos, PDFs, installers, code… each into its own folder."),
                    Bullet(icon: "eye", title: "Preview first", text: "See exactly where every file will go, and skip any group you like."),
                    Bullet(icon: "arrow.uturn.backward", title: "One-click undo", text: "Changed your mind? Everything goes straight back where it was."),
                ],
                buttonTitle: "Preview"
            ) {
                Task { await org.preview() }
            } footer: {
                FolderPicker()
            }
        case .scanning:
            ScanningScreen(module: module, title: "Sorting \(org.folderName)…", detail: Fmt.shortPath(org.folder))
        case .cleaning:
            ScanningScreen(module: module, title: "Organizing…", detail: "Moving \(org.fileCount) files")
        case .done:
            DoneScreen(
                module: module,
                title: org.undoneCount != nil ? "Put back \(org.undoneCount!) files" : "\(org.movedCount) files organized",
                subtitle: org.undoneCount != nil
                    ? "\(org.folderName) is back the way it was."
                    : "\(org.folderName) now has \(org.active.count) neat folders." + (org.failedCount > 0 ? " \(org.failedCount) files couldn't be moved." : ""),
                primary: "Open \(org.folderName)",
                primaryAction: { Finder.open(org.folder) },
                secondary: org.canUndo ? "Undo" : "Done",
                secondaryAction: {
                    if org.canUndo { _ = Task { await org.undo() } } else { org.reset() }
                }
            )
        case .results:
            OrganizerPreview()
        }
    }
}

private struct FolderPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var org = model.organizer
        let home = FileManager.default.homeDirectoryForCurrentUser
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(["Downloads", "Desktop", "Documents"], id: \.self) { name in
                    let url = home.appendingPathComponent(name)
                    Chip(title: name, icon: "folder", active: org.folder == url, colors: Module.organizer.colors) { org.folder = url }
                }
                Chip(title: org.folder.deletingLastPathComponent() == home ? "Other…" : org.folder.lastPathComponent,
                     icon: "ellipsis", active: org.folder.deletingLastPathComponent() != home, colors: Module.organizer.colors) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url { org.folder = url }
                }
            }
            HStack(spacing: 8) {
                ForEach(OrganizeMode.allCases) { m in
                    Chip(title: m.rawValue, icon: m.icon, active: org.mode == m, colors: Module.organizer.colors) { org.mode = m }
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct OrganizerPreview: View {
    @Environment(AppModel.self) private var model
    private let module = Module.organizer

    var body: some View {
        let org = model.organizer
        VStack(spacing: 0) {
            ModuleHeader(title: "Organize \(org.folderName)", subtitle: "\(org.fileCount) loose files → \(org.active.count) folders. Click a card to skip it.") {
                HStack(spacing: 8) {
                    Button("Change") { org.reset() }.buttonStyle(PillButtonStyle())
                }
            }

            if org.groups.isEmpty {
                EmptyState(icon: "sparkles", title: "Already tidy", text: "There are no loose files to sort in \(org.folderName).", colors: module.colors)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(Array(org.groups.enumerated()), id: \.element.id) { i, g in
                            GroupCard(group: g, index: i, skipped: org.excluded.contains(g.folder)) { org.toggle(g) }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 12)
                }
            }

            ActionBar(module: module, buttonTitle: "Organize", enabled: org.fileCount > 0, action: {
                Task { await org.organize() }
            }) {
                SelectionSummary(amount: "\(org.fileCount) files", caption: "\(Fmt.bytes(org.totalSize)) into \(org.active.count) folders")
            }
        }
    }
}

private struct GroupCard: View {
    let group: FileGroup
    let index: Int
    let skipped: Bool
    let toggle: () -> Void
    @State private var shown = false
    @State private var hover = false

    var body: some View {
        let c1 = Color(hue: group.hue, saturation: 0.55, brightness: 0.98)
        let c2 = Color(hue: (group.hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.8)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(LinearGradient(colors: [c1, c2], startPoint: .top, endPoint: .bottom))
                    Image(systemName: group.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(y: 3)
                }
                .shadow(color: c1.opacity(0.4), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.folder).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("\(group.files.count) files · \(Fmt.bytes(group.size))")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                }
                Spacer()
                RoundCheck(state: skipped ? .off : .on, colors: [c1, c2], size: 20)
            }
            // A peek at the files, as small chips that fan in.
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(group.files.prefix(4).enumerated()), id: \.offset) { j, f in
                    HStack(spacing: 7) {
                        FileIcon(url: f, size: 16)
                        Text(f.lastPathComponent).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    }
                    .offset(x: shown ? 0 : -20)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(index) * 0.04 + Double(j) * 0.05), value: shown)
                }
                if group.files.count > 4 {
                    Text("+ \(group.files.count - 4) more").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.faint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 18, padding: 16, highlighted: hover)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: [c1.opacity(skipped ? 0 : 0.6), c2.opacity(skipped ? 0 : 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .opacity(skipped ? 0.45 : 1)
        .saturation(skipped ? 0.2 : 1)
        .scaleEffect(shown ? (hover ? 1.015 : 1) : 0.85)
        .opacity(shown ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { h in withAnimation(.spring(response: 0.3)) { hover = h } }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75).delay(Double(index) * 0.04)) { shown = true }
        }
        .animation(.spring(response: 0.35), value: skipped)
    }
}
