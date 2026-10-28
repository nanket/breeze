import SwiftUI
import AppKit

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("safeMode") private var safeMode = false
    @AppStorage(SoundFX.enabledKey) private var soundsOn = true
    @AppStorage(SoundFX.volumeKey) private var volume = 0.6
    @AppStorage("showMenuBar") private var menuBar = true
    @AppStorage(DiskAlerts.enabledKey) private var lowDisk = true
    @AppStorage(DiskAlerts.thresholdKey) private var lowDiskGB = 15.0
    @AppStorage(AppModel.weeklyKey) private var weekly = true
    @AppStorage(SelfUpdater.autoKey) private var autoUpdates = true
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                LogoMark(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Breeze \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                }
                Spacer()
                IconButton(symbol: "xmark", help: "Close") { dismiss() }
            }

            section("General", icon: "gearshape.fill", colors: Theme.brand) {
                Toggle(isOn: $loginOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Breeze at login").font(.system(size: 13, weight: .semibold))
                        Text(loginError ?? "Starts quietly in the menu bar so alerts and check-ups keep working.")
                            .font(.system(size: 11.5)).foregroundStyle(loginError == nil ? Theme.dim : Color(hex: 0xFF8A5B))
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: loginOn) { _, on in
                    loginError = LoginItem.set(on)
                    if loginError != nil { loginOn = LoginItem.isEnabled }
                }
                Toggle(isOn: $weekly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weekly check-up").font(.system(size: 13, weight: .semibold))
                        Text("Once a week Breeze looks for junk in the background and lets you know if there's over 1 GB to clean. It never cleans on its own.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $autoUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for Breeze updates automatically").font(.system(size: 13, weight: .semibold))
                        Text(model.updater.lastMessage ?? "You're on version \(AppConfig.version).")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(.switch)
                HStack {
                    Button {
                        Task { await model.updater.check(userInitiated: true) }
                    } label: {
                        HStack(spacing: 6) {
                            if model.updater.checking { ProgressView().controlSize(.mini) }
                            Text("Check Now")
                        }
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                    Spacer()
                }
            }

            section("Sound", icon: "speaker.wave.2.fill", colors: Module.smartScan.colors) {
                Toggle(isOn: $soundsOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sound effects").font(.system(size: 13, weight: .semibold))
                        Text("Soft chimes when scans finish and things get cleaned.").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: soundsOn) { _, on in if on { SoundFX.shared.play(.scanDone, force: true) } }

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(Theme.faint)
                    Slider(value: $volume, in: 0.05...1, onEditingChanged: { editing in
                        if !editing { SoundFX.shared.play(.tap, force: true) }
                    })
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.faint)
                    Button("Preview") { SoundFX.shared.play(.clean, force: true) }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
                .disabled(!soundsOn)
                .opacity(soundsOn ? 1 : 0.4)
            }

            section("Support Breeze", icon: "heart.fill", colors: [Color(hex: 0x8B7CFF), Color(hex: 0xFF5FA2)]) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Breeze is free and open source").font(.system(size: 13, weight: .semibold))
                        Text("If it saved you some space, a tip helps keep it going.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Button("Source Code") { NSWorkspace.shared.open(AppConfig.sourceURL) }
                        .buttonStyle(PillButtonStyle(compact: true))
                    Button("Leave a Tip") { NSWorkspace.shared.open(AppConfig.tipURL) }
                        .buttonStyle(PillButtonStyle(colors: [Color(hex: 0x8B7CFF), Color(hex: 0xFF5FA2)], compact: true))
                }
            }

            section("Menu Bar & Alerts", icon: "menubar.rectangle", colors: Module.spaceLens.colors) {
                Toggle(isOn: $menuBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Breeze in the menu bar").font(.system(size: 13, weight: .semibold))
                        Text("Live CPU, memory, disk and network, plus one-click Free RAM and Empty Trash.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $lowDisk) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Warn me when disk space runs low").font(.system(size: 13, weight: .semibold))
                        Text("A notification when free space drops under \(Int(lowDiskGB)) GB, at most once a day.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(.switch)
                HStack {
                    Text("Threshold").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Slider(value: $lowDiskGB, in: 5...100, step: 5)
                    Text("\(Int(lowDiskGB)) GB").font(.system(size: 12, weight: .semibold, design: .rounded)).frame(width: 48)
                }
                .disabled(!lowDisk)
                .opacity(lowDisk ? 1 : 0.4)
            }

            section("Cleaning", icon: "bubbles.and.sparkles", colors: Module.junk.colors) {
                Toggle(isOn: $safeMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always use the Trash").font(.system(size: 13, weight: .semibold))
                        Text("Caches and logs are normally deleted straight away because apps rebuild them. Turn this on to send them to the Trash first.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }

            section("Help & Privacy", icon: "questionmark.circle.fill", colors: Module.privacy.colors) {
                Text("Breeze runs entirely on your Mac. It has no account and no analytics, and nothing about your files ever leaves this computer. The only network requests are update checks for Breeze and, when you open the Updater, for your other apps.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Cleaning History…") { dismiss(); model.showHistory = true }.buttonStyle(PillButtonStyle(compact: true))
                    Button("Contact Support") { Support.contact() }.buttonStyle(PillButtonStyle(compact: true))
                    Button("Privacy Policy") { NSWorkspace.shared.open(AppConfig.privacyURL) }.buttonStyle(PillButtonStyle(compact: true))
                    Button("Terms") { NSWorkspace.shared.open(AppConfig.termsURL) }.buttonStyle(PillButtonStyle(compact: true))
                }
            }

            section("Permissions", icon: "lock.shield.fill", colors: Module.optimization.colors) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(model.hasFullDiskAccess ? Color(hex: 0x2EE6A8) : Color(hex: 0xFFB547))
                        .frame(width: 9, height: 9)
                        .shadow(color: model.hasFullDiskAccess ? Color(hex: 0x2EE6A8) : Color(hex: 0xFFB547), radius: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.hasFullDiskAccess ? "Full Disk Access is on" : "Full Disk Access is off")
                            .font(.system(size: 13, weight: .semibold))
                        Text(model.hasFullDiskAccess ? "Breeze can clean everything without asking folder by folder." : "macOS will ask before Breeze reads Desktop, Documents and Downloads.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    if !model.hasFullDiskAccess {
                        Button("Set Up") {
                            dismiss()
                            withAnimation(.spring(response: 0.5)) { model.showOnboarding = true }
                        }
                        .buttonStyle(PillButtonStyle(colors: Module.optimization.colors, compact: true))
                    }
                }
            }
        }
        .padding(24)
        }
        .frame(width: 520, height: 680)
        .background(ModuleBackground(module: .smartScan))
        .preferredColorScheme(.dark)
        .onAppear { model.refreshPermissions() }
    }

    private func section<Content: View>(_ title: String, icon: String, colors: [Color], @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GradientIcon(symbol: icon, colors: colors, size: 22)
                Text(title.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(1.2).foregroundStyle(Theme.dim)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 16, padding: 16)
    }
}

// MARK: - First-launch permissions guide

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var appear = false
    @State private var pulse = false
    @State private var granted = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Theme.baseDeep.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [(granted ? Module.junk.colors[0] : Theme.brand[0]).opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 120))
                        .frame(width: 240, height: 240)
                        .scaleEffect(pulse ? 1.08 : 0.92)
                    if granted {
                        Circle().fill(Module.junk.gradient).frame(width: 96, height: 96)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 42, weight: .bold)).foregroundStyle(.white))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        LogoMark(size: 96)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 150)

                VStack(spacing: 8) {
                    Text(granted ? "You're all set" : "One quick setup")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(granted
                         ? "Breeze can now clean everywhere without asking folder by folder."
                         : "Give Breeze Full Disk Access once, and macOS stops asking about Desktop, Downloads and Documents every time you scan.")
                        .font(.system(size: 14)).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                if !granted {
                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "Click **Open Privacy Settings** below.")
                        step(2, "Turn on **Breeze** in the list. If it's not there, drag this icon into the list:")
                        HStack {
                            Spacer()
                            DragAppTile()
                            Spacer()
                        }
                        step(3, "Come back here. Breeze notices on its own.")
                    }
                    .frame(width: 440)
                    .glass(radius: 18, padding: 18)

                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: 0xFFB547)).frame(width: 8, height: 8)
                            .opacity(pulse ? 1 : 0.3)
                        Text("Waiting for access…").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Permissions.openFullDiskAccessSettings()
                        } label: {
                            Label("Open Privacy Settings", systemImage: "lock.open.fill")
                        }
                        .buttonStyle(PillButtonStyle(colors: Theme.brand))
                        Button("Skip for now") {
                            UserDefaults.standard.set(true, forKey: "onboardingSkipped")
                            close()
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                } else {
                    Button("Start Cleaning") { close() }
                        .buttonStyle(PillButtonStyle(colors: Module.junk.colors))
                }
            }
            .padding(40)
            .scaleEffect(appear ? 1 : 0.92)
            .opacity(appear ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appear = true }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
        .task {
            // Poll until access shows up, then celebrate.
            while !Task.isCancelled && !granted {
                try? await Task.sleep(for: .seconds(1.2))
                if Permissions.hasFullDiskAccess {
                    model.refreshPermissions()
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { granted = true }
                    SoundFX.shared.play(.clean)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.45)) { model.showOnboarding = false }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 24, height: 24)
                .background(Circle().fill(LinearGradient(colors: Theme.brand, startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app's own icon, draggable straight into the Full Disk Access list.
private struct DragAppTile: View {
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Breeze").font(.system(size: 13, weight: .semibold))
                Text("Drag me").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            Image(systemName: "hand.draw").foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.12 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.white.opacity(0.25)))
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
    }
}
