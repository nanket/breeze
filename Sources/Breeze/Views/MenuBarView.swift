import SwiftUI
import AppKit

/// Compact live monitor that lives in the menu bar.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var working: String?

    var body: some View {
        let s = model.stats
        let h = model.health
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LogoMark(size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Breeze").font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(s.macName).font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(LinearGradient(colors: h.colors, startPoint: .top, endPoint: .bottom)).frame(width: 8, height: 8)
                    Text("\(h.score) · \(h.label)").font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.08)))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Tile(title: "CPU", value: s.cpu.formatted(.percent.precision(.fractionLength(0))), fraction: s.cpu, colors: Module.smartScan.colors) {
                    Sparkline(values: s.cpuHistory, colors: Module.smartScan.colors).frame(height: 22)
                }
                Tile(title: "Memory", value: Fmt.memory(Int64(s.memUsed)), fraction: s.memFraction, colors: Module.junk.colors) {
                    SizeBar(fraction: s.memFraction, colors: Module.junk.colors, height: 5)
                }
                Tile(title: "Disk free", value: Fmt.bytes(s.diskFree), fraction: 1 - s.diskFraction, colors: Module.spaceLens.colors) {
                    SizeBar(fraction: s.diskFraction, colors: s.diskFraction > 0.9 ? [Color(hex: 0xFF8A5B), Color(hex: 0xFF3D71)] : Module.spaceLens.colors, height: 5)
                }
                Tile(title: "Network", value: "↓ " + rate(s.netDown), fraction: 0, colors: Module.organizer.colors) {
                    Text("↑ " + rate(s.netUp)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
                }
            }

            VStack(spacing: 6) {
                action("Smart Scan", icon: "sparkles", colors: Module.smartScan.colors) {
                    openMain()
                    model.select(.smartScan)
                    Task { await model.runSmartScan() }
                }
                action("Free Up RAM", icon: "memorychip", colors: Module.junk.colors) {
                    working = "Free Up RAM"
                    Task {
                        _ = await Task.detached { Shell.run("/usr/sbin/purge", admin: true) }.value
                        working = nil
                        SoundFX.shared.play(.clean)
                    }
                }
                action("Empty Trash", icon: "trash", colors: Module.largeFiles.colors) {
                    guard confirmEmptyTrash() else { return }
                    working = "Empty Trash"
                    Task {
                        _ = await Task.detached { Cleaner.emptyTrashViaFinder() }.value
                        working = nil
                        SoundFX.shared.play(.clean)
                        model.stats.refresh()
                    }
                }
            }

            Divider().overlay(Theme.stroke)

            HStack {
                Button("Open Breeze") { openMain() }
                    .buttonStyle(PillButtonStyle(colors: Theme.brand, compact: true))
                Spacer()
                IconButton(symbol: "gearshape.fill", help: "Settings") {
                    openMain()
                    model.showSettings = true
                }
                IconButton(symbol: "power", help: "Quit Breeze") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(ModuleBackground(module: .smartScan))
        .preferredColorScheme(.dark)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Emptying the Trash can't be undone, so it always asks first.
    private func confirmEmptyTrash() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Everything in the Trash will be deleted for good. You can't undo this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func rate(_ bps: Double) -> String {
        Fmt.bytes(Int64(bps)) + "/s"
    }

    private func action(_ title: String, icon: String, colors: [Color], run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                GradientIcon(symbol: icon, colors: colors, size: 24)
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if working == title {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working != nil)
    }
}

private struct Tile<Extra: View>: View {
    let title: String
    let value: String
    let fraction: Double
    let colors: [Color]
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(1).foregroundStyle(Theme.faint)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            extra
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 12, padding: 10)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}
