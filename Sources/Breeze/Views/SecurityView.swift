import SwiftUI
import AppKit

struct SecurityView: View {
    @Environment(AppModel.self) private var model
    private let module = Module.security

    var body: some View {
        let sec = model.security
        switch sec.phase {
        case .idle, .cleaning, .done:
            IntroScreen(
                module: module,
                headline: "Make sure your Mac's defences are switched on.",
                bullets: [
                    Bullet(icon: "lock.shield", title: "Built-in protections", text: "Gatekeeper, System Integrity Protection, FileVault, Firewall and Apple's XProtect malware definitions."),
                    Bullet(icon: "signature", title: "Who made your apps", text: "Flags apps and startup items that aren't signed by an identified developer."),
                    Bullet(icon: "exclamationmark.octagon", title: "Known adware", text: "Spots apps and background items that match well-known adware families."),
                ],
                buttonTitle: "Check"
            ) {
                Task { await sec.scan(apps: model.apps, agents: model.agents) }
            }
        case .scanning:
            ScanningScreen(module: module, title: "Checking your Mac…", detail: sec.step)
        case .results:
            SecurityResults()
        }
    }
}

private struct SecurityResults: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: FlaggedItem?
    private let module = Module.security

    var body: some View {
        let sec = model.security
        let colors: [Color] = sec.score >= 85 ? Module.junk.colors : (sec.score >= 60 ? Module.optimization.colors : [Color(hex: 0xFF8A5B), Color(hex: 0xFF3D71)])
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    RingGauge(fraction: Double(sec.score) / 100, colors: colors, lineWidth: 12) {
                        VStack(spacing: 0) {
                            Image(systemName: sec.threats.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                            Text("\(sec.score)").font(.system(size: 22, weight: .heavy, design: .rounded))
                        }
                    }
                    .frame(width: 110, height: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sec.threats.isEmpty ? (sec.score >= 85 ? "Your Mac is well protected" : "A few things to tighten up") : "Possible adware found")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("\(sec.checks.filter { $0.status == .good }.count) of \(sec.checks.count) protections on · \(sec.flagged.filter { $0.severity != .info }.count) items to review")
                            .font(.system(size: 13)).foregroundStyle(Theme.dim)
                        Text("Breeze checks settings and signatures. It isn't antivirus. macOS's own XProtect removes known malware.")
                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    Button("Check Again") { Task { await sec.scan(apps: model.apps, agents: model.agents) } }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(.top, 40)

                Text("PROTECTIONS").font(.system(size: 11, weight: .heavy)).tracking(1.2).foregroundStyle(Theme.faint)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(sec.checks) { c in CheckCard(check: c) }
                }

                if !sec.flagged.isEmpty {
                    Text("APPS & BACKGROUND ITEMS").font(.system(size: 11, weight: .heavy)).tracking(1.2).foregroundStyle(Theme.faint)
                        .padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(sec.flagged) { f in
                            HStack(spacing: 12) {
                                Image(systemName: f.severity == .threat ? "exclamationmark.octagon.fill" : (f.severity == .caution ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                                    .foregroundStyle(f.severity == .threat ? Color(hex: 0xFF3D71) : (f.severity == .caution ? Color(hex: 0xFFB547) : Theme.faint))
                                FileIcon(url: f.url, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(f.reason).font(.system(size: 11)).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                IconButton(symbol: "magnifyingglass", help: "Reveal in Finder") { Finder.reveal([f.url]) }
                                if f.severity != .info {
                                    Button("Move to Trash") { confirm = f }.buttonStyle(PillButtonStyle(compact: true))
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            if f.id != sec.flagged.last?.id { Divider().overlay(Theme.stroke) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .confirmationDialog("Move \(confirm?.title ?? "") to the Trash?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let c = confirm { Task { await sec.trash(c) } }
            }
        } message: {
            Text("You can put it back from the Trash if it turns out you need it.")
        }
    }
}

private struct CheckCard: View {
    let check: SecurityCheck

    var body: some View {
        let color: Color = switch check.status {
        case .good: Color(hex: 0x2EE6A8)
        case .warn: Color(hex: 0xFFB547)
        case .bad: Color(hex: 0xFF3D71)
        case .info: Theme.dim
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: check.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(color.opacity(0.15)))
                Text(check.title).font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Image(systemName: check.status == .good ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(color)
            }
            Text(check.detail).font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            if let t = check.fixTitle, let u = check.fixURL, let url = URL(string: u) {
                Button(t) { NSWorkspace.shared.open(url) }.buttonStyle(PillButtonStyle(compact: true))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .glass(radius: 16, padding: 14)
    }
}
