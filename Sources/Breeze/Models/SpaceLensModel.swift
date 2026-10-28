import SwiftUI

struct LensChild: Hashable, Sendable {
    let name: String
    let size: Int64
    let isDirectory: Bool
}

struct LensNode: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    var size: Int64?
    var children: [LensChild] = []
    var selected = false
    var name: String { url.lastPathComponent }
}

enum LensStyle: String, CaseIterable, Identifiable {
    case orbit = "Orbit", map = "Map"
    var id: String { rawValue }
    var icon: String { self == .orbit ? "circle.circle" : "square.grid.2x2" }
}

@MainActor
@Observable
final class SpaceLensModel {
    var trail: [URL] = []
    var nodes: [LensNode] = []
    var loading = false
    var hovered: URL?
    var lastResult: Cleaner.Result?
    private var cache: [URL: (Int64, [LensChild])] = [:]
    private var task: Task<Void, Never>?

    var current: URL? { trail.last }
    var total: Int64 { nodes.reduce(0) { $0 + ($1.size ?? 0) } }
    var measured: Int { nodes.filter { $0.size != nil }.count }
    var selected: [LensNode] { nodes.filter(\.selected) }
    var selectedSize: Int64 { selected.reduce(0) { $0 + ($1.size ?? 0) } }

    var sortedNodes: [LensNode] {
        nodes.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
    }

    func start(at url: URL) {
        SoundFX.shared.play(.scanStart)
        trail = [url]
        load(url)
    }

    func enter(_ url: URL) {
        SoundFX.shared.play(.drill)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { trail.append(url) }
        load(url)
    }

    /// Jumps several levels at once (used when clicking an outer-ring segment).
    func enter(path: [URL]) {
        SoundFX.shared.play(.drill)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { trail.append(contentsOf: path) }
        if let last = path.last { load(last) }
    }

    func jump(to index: Int) {
        guard trail.indices.contains(index), index != trail.count - 1 else { return }
        SoundFX.shared.play(.drill)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { trail = Array(trail.prefix(index + 1)) }
        load(trail[index])
    }

    func back() {
        guard trail.count > 1 else { return }
        jump(to: trail.count - 2)
    }

    func refresh() {
        guard let c = current else { return }
        cache = cache.filter { !$0.key.path.hasPrefix(c.path) }
        load(c)
    }

    private func load(_ dir: URL) {
        task?.cancel()
        hovered = nil
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: []
        )) ?? []

        nodes = kids.compactMap { u -> LensNode? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { return nil }
            let name = u.lastPathComponent
            if name == ".DS_Store" || name == ".localized" { return nil }
            if dir.path == "/" && ["dev", "Volumes", ".vol", ".file", ".nofollow", ".resolve", ".VolumeIcon.icns"].contains(name) {
                return nil
            }
            let isDir = v?.isDirectory == true && v?.isPackage != true
            let cached = cache[u]
            return LensNode(url: u, isDirectory: isDir, size: cached?.0, children: isDir ? (cached?.1 ?? []) : [])
        }

        let pending = nodes.filter { $0.size == nil }.map(\.url)
        guard !pending.isEmpty else { loading = false; return }
        loading = true

        task = Task { [weak self] in
            await withTaskGroup(of: (URL, Int64, [LensChild]).self) { group in
                var iterator = pending.makeIterator()
                for _ in 0..<8 {
                    guard let u = iterator.next() else { break }
                    group.addTask { let b = FileSizer.breakdown(of: u); return (u, b.total, b.children) }
                }
                while let r = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    guard let self else { break }
                    let (u, s, kids) = r
                    self.cache[u] = (s, kids)
                    if let i = self.nodes.firstIndex(where: { $0.url == u }) {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                            self.nodes[i].size = s
                            if self.nodes[i].isDirectory { self.nodes[i].children = kids }
                        }
                    }
                    if let next = iterator.next() {
                        group.addTask { let b = FileSizer.breakdown(of: next); return (next, b.total, b.children) }
                    }
                }
            }
            if !Task.isCancelled {
                self?.loading = false
                SoundFX.shared.play(.scanDone)
            }
        }
    }

    func toggle(_ id: URL) {
        if let i = nodes.firstIndex(where: { $0.id == id }) {
            nodes[i].selected.toggle()
            SoundFX.shared.play(.tap)
        }
    }

    func trashSelected() async {
        let jobs = selected.map { Cleaner.Job(url: $0.url, size: $0.size ?? 0, permanent: false) }
        guard !jobs.isEmpty else { return }
        let result = await Task.detached { Cleaner.remove(jobs, source: "Space Lens") }.value
        lastResult = result
        Lifetime.record(result)
        for j in jobs { cache[j.url] = nil }
        // Parent folders' cached sizes are now stale.
        for t in trail { cache[t] = nil }
        withAnimation(.spring(response: 0.5)) {
            nodes.removeAll { $0.selected && !FileManager.default.fileExists(atPath: $0.url.path) }
        }
        SoundFX.shared.play(.clean)
    }
}
