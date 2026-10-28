import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Theme {
    static let base = Color(hex: 0x0C0A1C)
    static let baseDeep = Color(hex: 0x07060F)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.08)
    static let dim = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.40)
    static let brand: [Color] = [Color(hex: 0x8B7CFF), Color(hex: 0x3EE6C4)]
}

enum Module: String, CaseIterable, Identifiable {
    case smartScan, junk, devCleanup, largeFiles, duplicates, spaceLens, organizer, security, privacy, uninstaller, updater, optimization, maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: "Smart Scan"
        case .junk: "System Junk"
        case .devCleanup: "Dev Cleanup"
        case .duplicates: "Duplicates"
        case .largeFiles: "Large & Old Files"
        case .spaceLens: "Space Lens"
        case .organizer: "Organizer"
        case .security: "Security Check"
        case .privacy: "Privacy"
        case .updater: "Updater"
        case .uninstaller: "Uninstaller"
        case .optimization: "Launch Agents"
        case .maintenance: "Maintenance"
        }
    }

    var icon: String {
        switch self {
        case .smartScan: "sparkles"
        case .junk: "bubbles.and.sparkles"
        case .devCleanup: "chevron.left.forwardslash.chevron.right"
        case .duplicates: "square.on.square"
        case .largeFiles: "doc.on.doc"
        case .spaceLens: "circle.hexagongrid"
        case .organizer: "folder.badge.gearshape"
        case .security: "checkmark.shield"
        case .privacy: "hand.raised"
        case .updater: "arrow.down.app"
        case .uninstaller: "xmark.app"
        case .optimization: "gauge.with.dots.needle.67percent"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    var colors: [Color] {
        switch self {
        case .smartScan: [Color(hex: 0xB26BFF), Color(hex: 0xFF5FA2)]
        case .junk: [Color(hex: 0x2EE6A8), Color(hex: 0x1FA2FF)]
        case .devCleanup: [Color(hex: 0x43CEA2), Color(hex: 0x185A9D)]
        case .duplicates: [Color(hex: 0xFC5C7D), Color(hex: 0x6A82FB)]
        case .largeFiles: [Color(hex: 0xFFB547), Color(hex: 0xFF6A3D)]
        case .spaceLens: [Color(hex: 0x4FACFE), Color(hex: 0x6A5BFF)]
        case .organizer: [Color(hex: 0x84FAB0), Color(hex: 0x3BB2F6)]
        case .security: [Color(hex: 0x56CCF2), Color(hex: 0x2F80ED)]
        case .privacy: [Color(hex: 0xA18CD1), Color(hex: 0xFBC2EB)]
        case .updater: [Color(hex: 0x00C9FF), Color(hex: 0x92FE9D)]
        case .uninstaller: [Color(hex: 0xFF6B8B), Color(hex: 0xC44BFF)]
        case .optimization: [Color(hex: 0xFFE066), Color(hex: 0xFF9F43)]
        case .maintenance: [Color(hex: 0x7DE2FC), Color(hex: 0xB9A6FF)]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct SidebarSection: Hashable {
    let title: String?
    let modules: [Module]

    static let all: [SidebarSection] = [
        SidebarSection(title: nil, modules: [.smartScan]),
        SidebarSection(title: "Cleanup", modules: [.junk, .devCleanup]),
        SidebarSection(title: "Files", modules: [.largeFiles, .duplicates, .spaceLens, .organizer]),
        SidebarSection(title: "Protection", modules: [.security, .privacy]),
        SidebarSection(title: "Applications", modules: [.uninstaller, .updater]),
        SidebarSection(title: "Speed", modules: [.optimization, .maintenance]),
    ]
}

/// Lifecycle shared by every scanning module.
enum Phase: Equatable {
    case idle, scanning, results, cleaning, done
}

enum CheckState { case off, mixed, on }
