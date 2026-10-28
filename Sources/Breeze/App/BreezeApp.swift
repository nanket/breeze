import SwiftUI
import AppKit

@main
struct BreezeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("Breeze", id: "main") {
            RootView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await model.updater.check(userInitiated: true) } }
                Button("Support Breeze…") { NSWorkspace.shared.open(AppConfig.tipURL) }
            }
            CommandGroup(replacing: .help) {
                Button("Cleaning History") { model.showHistory = true }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                Button("Contact Support…") { Support.contact() }
                Button("Open Log Folder") { NSWorkspace.shared.open(AppConfig.logFolder) }
            }
            CommandMenu("Scan") {
                Button("Smart Scan") {
                    model.module = .smartScan
                    Task { await model.runSmartScan() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
                ForEach(Module.allCases) { m in
                    Button(m.title) { model.select(m) }
                }
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environment(model)
        } label: {
            Image(systemName: "wind")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With the menu bar monitor on, closing the window keeps Breeze running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true)
    }
}
