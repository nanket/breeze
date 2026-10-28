import SwiftUI
import CryptoKit

struct DupFile: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let modified: Date?
    var remove: Bool
}

struct DupGroup: Identifiable, Hashable, Sendable {
    let id: String          // content hash
    let size: Int64
    var files: [DupFile]

    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
    var removing: Int { files.filter(\.remove).count }
    var name: String { files.first?.url.lastPathComponent ?? "" }
}

enum DupScanner {
    static let chunk = 1 << 20

    /// size → quick sample (first + last 64 KB) → full SHA-256. Only true byte-for-byte copies survive.
    static func scan(roots: [URL], minSize: Int64, progress: @escaping @Sendable (String, Double) -> Void) -> [DupGroup] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .fileResourceIdentifierKey, .contentModificationDateKey]
        var bySize: [Int64: [(URL, Date?)]] = [:]
        var seenInodes = Set<String>()
        var n = 0

        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                n += 1
                if n % 500 == 0 {
                    if Task.isCancelled { return [] }
                    progress(Fmt.shortPath(u), 0)
                }
                if u.lastPathComponent == "Library" && u.deletingLastPathComponent() == fm.homeDirectoryForCurrentUser {
                    e.skipDescendants(); continue
                }
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize.map(Int64.init), size >= minSize else { continue }
                // Hard links point at the same data; deleting one frees nothing.
                if let rid = v.fileResourceIdentifier {
                    let key = "\(rid)"
                    if !seenInodes.insert(key).inserted { continue }
                }
                bySize[size, default: []].append((u, v.contentModificationDate))
            }
        }

        let candidates = bySize.filter { $0.value.count > 1 }
        let totalCandidates = max(1, candidates.values.reduce(0) { $0 + $1.count })
        var hashed = 0
        var groups: [DupGroup] = []

        for (size, files) in candidates {
            if Task.isCancelled { return [] }
            // Pass 2: cheap sample.
            var bySample: [String: [(URL, Date?)]] = [:]
            for f in files {
                if let s = sample(f.0, size: size) { bySample[s, default: []].append(f) }
            }
            // Pass 3: full hash, only where samples collide.
            for (_, same) in bySample where same.count > 1 {
                var byHash: [String: [(URL, Date?)]] = [:]
                for f in same {
                    hashed += 1
                    progress(Fmt.shortPath(f.0), Double(hashed) / Double(totalCandidates))
                    if let h = fullHash(f.0) { byHash[h, default: []].append(f) }
                }
                for (h, dupes) in byHash where dupes.count > 1 {
                    // Keep the oldest copy (usually the original); mark the rest.
                    let sorted = dupes.sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
                    let entries = sorted.enumerated().map { i, f in DupFile(url: f.0, modified: f.1, remove: i > 0) }
                    groups.append(DupGroup(id: h, size: size, files: entries))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func sample(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let n = 64 * 1024
        var data = (try? h.read(upToCount: n)) ?? Data()
        if size > Int64(n * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(n))
            data.append((try? h.read(upToCount: n)) ?? Data())
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            guard let d = try? h.read(upToCount: chunk), !d.isEmpty else { break }
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class DuplicatesModel {
    static let sizeOptions: [Int64] = [100 * 1024, 1_048_576, 10 * 1_048_576, 100 * 1_048_576]

    var phase: Phase = .idle
    var groups: [DupGroup] = []
    var roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    var minSize: Int64 = 1_048_576
    var currentPath = ""
    var progress = 0.0
    var lastResult: Cleaner.Result?
    var expanded: Set<String> = []
    private var task: Task<[DupGroup], Never>?

    var removingCount: Int { groups.reduce(0) { $0 + $1.removing } }
    var removingSize: Int64 { groups.reduce(0) { $0 + Int64($1.removing) * $1.size } }
    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    var rootsLabel: String {
        roots.map { $0.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : $0.lastPathComponent }.joined(separator: ", ")
    }

    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        SoundFX.shared.play(.scanStart)
        progress = 0
        currentPath = ""
        let r = roots, m = minSize
        let t = Task.detached(priority: .userInitiated) { [weak self] in
            DupScanner.scan(roots: r, minSize: m) { path, p in
                Task { @MainActor in
                    self?.currentPath = path
                    if p > 0 { self?.progress = p }
                }
            }
        }
        task = t
        groups = await t.value
        expanded = Set(groups.prefix(3).map(\.id))
        withAnimation(.spring(response: 0.5)) { phase = .results }
        SoundFX.shared.play(.scanDone)
    }

    func stop() { task?.cancel() }

    /// Clicking a copy makes it the one you keep; every other copy in that group gets removed.
    func keep(_ file: DupFile, in group: DupGroup) {
        guard let g = groups.firstIndex(where: { $0.id == group.id }) else { return }
        for i in groups[g].files.indices { groups[g].files[i].remove = groups[g].files[i].url != file.url }
        SoundFX.shared.play(.tap)
    }

    func toggle(_ file: DupFile, in group: DupGroup) {
        guard let g = groups.firstIndex(where: { $0.id == group.id }),
              let i = groups[g].files.firstIndex(where: { $0.url == file.url }) else { return }
        // Never allow removing every copy.
        if !groups[g].files[i].remove && groups[g].removing >= groups[g].files.count - 1 { return }
        groups[g].files[i].remove.toggle()
        SoundFX.shared.play(.tap)
    }

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func clean() async {
        var jobs: [Cleaner.Job] = []
        for g in groups where g.removing < g.files.count {
            for f in g.files where f.remove { jobs.append(.init(url: f.url, size: g.size, permanent: false)) }
        }
        guard !jobs.isEmpty else { return }
        phase = .cleaning
        let result = await Task.detached { [jobs] in Cleaner.remove(jobs, source: "Duplicates") }.value
        try? await Task.sleep(for: .seconds(0.8))
        lastResult = result
        Lifetime.record(result)
        for g in groups.indices {
            groups[g].files.removeAll { $0.remove && !FileManager.default.fileExists(atPath: $0.url.path) }
        }
        groups.removeAll { $0.files.count < 2 }
        phase = .done
        SoundFX.shared.play(result.failures.isEmpty ? .clean : .warn)
    }
}
