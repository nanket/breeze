import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

// MARK: - Cleaning history

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [CleanRecord] = []
    @State private var filter = ""

    private var days: [(String, [CleanRecord])] {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        let visible = filter.isEmpty ? records : records.filter { $0.path.localizedCaseInsensitiveContains(filter) || $0.source.localizedCaseInsensitiveContains(filter) }
        var order: [String] = []
        var map: [String: [CleanRecord]] = [:]
        for r in visible {
            let k = f.string(from: r.date)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(r)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GradientIcon(symbol: "clock.arrow.circlepath", colors: Theme.brand, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cleaning History").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Everything Breeze removed, kept only on this Mac.").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Open Log Folder") { NSWorkspace.shared.open(AppConfig.logFolder) }.buttonStyle(PillButtonStyle(compact: true))
                IconButton(symbol: "xmark", help: "Close") { dismiss() }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Filter by path or module", text: $filter).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))

            if records.isEmpty {
                EmptyState(icon: "tray", title: "Nothing yet", text: "Items Breeze removes will be listed here.", colors: Theme.brand)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.0) { day, recs in
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(recs) { r in HistoryRow(record: r) }
                                }
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                            } header: {
                                HStack {
                                    Text(day).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dim)
                                    Spacer()
                                    Text(Fmt.bytes(recs.reduce(0) { $0 + $1.size })).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                                }
                                .padding(.vertical, 4)
                                .background(Theme.base)
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 680, height: 560)
        .background(Theme.base)
        .preferredColorScheme(.dark)
        .task { records = await Task.detached { CleanLog.load() }.value }
    }
}

private struct HistoryRow: View {
    let record: CleanRecord

    var body: some View {
        let skipped = record.outcome.hasPrefix("Skipped")
        HStack(spacing: 10) {
            Image(systemName: skipped ? "exclamationmark.circle" : (record.outcome == "Moved to Trash" ? "trash" : "bolt.fill"))
                .font(.system(size: 11))
                .foregroundStyle(skipped ? Color(hex: 0xFFB547) : Theme.dim)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text((record.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(record.source) · \(record.outcome) · \(Fmt.shortPath(URL(fileURLWithPath: record.path).deletingLastPathComponent()))")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(record.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            Text(Fmt.bytes(record.size)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

// MARK: - Crash banner

struct CrashBanner: View {
    let report: URL
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Color(hex: 0xFFB547))
            VStack(alignment: .leading, spacing: 1) {
                Text("Breeze quit unexpectedly last time").font(.system(size: 12.5, weight: .semibold))
                Text("Sending the report helps fix it. Nothing is sent automatically.").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            Button("Send Report") { CrashReports.send(report); dismiss() }.buttonStyle(PillButtonStyle(colors: Theme.brand, compact: true))
            IconButton(symbol: "xmark", help: "Dismiss", action: dismiss)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

// MARK: - Launch at login, notifications, weekly check-up

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum Notifier {
    static func post(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }
}

extension AppModel {
    nonisolated static let weeklyKey = "weeklyCheckup"
    nonisolated static let weeklyLastKey = "weeklyCheckupAt"

    /// Once a week, quietly look for junk and send a notification if there's a meaningful amount.
    func weeklyCheckupIfDue() async {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.weeklyKey) as? Bool ?? true else { return }
        let last = d.double(forKey: Self.weeklyLastKey)
        let now = Date().timeIntervalSince1970
        if last == 0 { d.set(now, forKey: Self.weeklyLastKey); return }   // start the clock on first launch
        guard now - last > 7 * 86_400, junk.phase != .scanning, smartPhase != .scanning else { return }
        d.set(now, forKey: Self.weeklyLastKey)
        let cats = await JunkScanner.scan { _ in }
        let total = cats.reduce(Int64(0)) { $0 + $1.selectedSize }
        CleanLog.log("Weekly check-up found \(Fmt.bytes(total)) of junk")
        guard total > 1_000_000_000 else { return }
        Notifier.post(id: "breeze.weekly", title: "Time for a quick clean", body: "Breeze found \(Fmt.bytes(total)) of junk you can safely remove.")
    }
}
