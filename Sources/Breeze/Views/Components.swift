import SwiftUI
import AppKit

// MARK: - Surfaces

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - On-screen tracking

/// Reports whether the window hosting it is really on screen: not closed, minimised, hidden,
/// covered by other windows, on another Space or behind a locked screen.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ v: ReaderView, context: Context) { v.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { report(false); return }
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] n in
                    self?.report(n.name == NSWindow.willCloseNotification ? false : nil)
                })
            }
            report(nil)
        }

        private func report(_ forced: Bool?) {
            let visible = forced ?? window?.occlusionState.contains(.visible) ?? false
            guard visible != last else { return }
            last = visible
            onChange(visible)
        }
    }
}

private struct OnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the window is closed, covered or minimised. Looping animations rest then.
    var isOnScreen: Bool {
        get { self[OnScreenKey.self] }
        set { self[OnScreenKey.self] = newValue }
    }
}

/// Plays a looping animation on `flag` while the window is on screen and `active`, and parks it
/// otherwise. Each animation frame re-lays out the whole window, so a forever loop kept Breeze
/// at 40–90 % CPU even with its window closed. Idle screens use a few repeats, then rest.
private struct LoopWhileOnScreen: ViewModifier {
    @Environment(\.isOnScreen) private var onScreen
    @Binding var flag: Bool
    let animation: Animation
    let active: Bool

    func body(content: Content) -> some View {
        content.onChange(of: onScreen && active, initial: true) { _, run in
            if run {
                withAnimation(animation) { flag = true }
            } else {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { flag = false }
            }
        }
    }
}

extension View {
    func loop(_ flag: Binding<Bool>, _ animation: Animation, active: Bool = true) -> some View {
        modifier(LoopWhileOnScreen(flag: flag, animation: animation, active: active))
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 16
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(highlighted ? Theme.cardHover : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func glass(radius: CGFloat = 18, padding: CGFloat = 16, highlighted: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, padding: padding, highlighted: highlighted))
    }
}

struct ModuleBackground: View {
    let module: Module

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.base, Theme.baseDeep], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [module.colors[0].opacity(0.42), .clear],
                center: UnitPoint(x: 0.82, y: 0.08), startRadius: 0, endRadius: 620
            )
            RadialGradient(
                colors: [module.colors[1].opacity(0.26), .clear],
                center: UnitPoint(x: 0.1, y: 1.0), startRadius: 0, endRadius: 560
            )
        }
        .animation(.easeInOut(duration: 0.7), value: module)
    }
}

// MARK: - Icons

struct GradientIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            )
            .frame(width: size, height: size)
    }
}

struct LogoMark: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: Theme.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: "wind")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: Theme.brand[0].opacity(0.5), radius: 8, y: 3)
    }
}

struct HeroGlyph: View {
    let module: Module
    var size: CGFloat = 210
    @State private var float = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [module.colors[1].opacity(0.5), .clear], center: .center, startRadius: 10, endRadius: size))
                .frame(width: size * 1.9, height: size * 1.9)
                .blur(radius: 24)
                .scaleEffect(float ? 1.06 : 0.94)

            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(module.gradient)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                )
                .overlay(
                    Image(systemName: module.icon)
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                )
                .frame(width: size, height: size)
                .shadow(color: module.colors[0].opacity(0.55), radius: 40, y: 24)
                .rotation3DEffect(.degrees(float ? 7 : -7), axis: (x: 1, y: -1, z: 0), perspective: 0.6)
                .offset(y: float ? -10 : 10)
        }
        .loop($float, .easeInOut(duration: 3.4).repeatCount(3, autoreverses: true))
    }
}

// MARK: - Buttons

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The big round call-to-action that anchors every screen.
struct ActionButton: View {
    let title: String
    let colors: [Color]
    var size: CGFloat = 116
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(colors[0].opacity(0.6), lineWidth: 2)
                    .scaleEffect(pulse ? 1.45 : 1)
                    .opacity(pulse || !enabled ? 0 : 0.9)
                Circle()
                    .stroke(colors[1].opacity(0.4), lineWidth: 1.5)
                    .scaleEffect(pulse ? 1.25 : 1)
                    .opacity(pulse || !enabled ? 0 : 0.7)
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(0.42), .clear], startPoint: .top, endPoint: .center))
                    .padding(4)
                Circle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                Text(title)
                    .font(.system(size: max(14, size * 0.16), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            .frame(width: size, height: size)
            .shadow(color: colors[0].opacity(hover ? 0.8 : 0.5), radius: hover ? 34 : 22, y: 10)
            .scaleEffect(hover && enabled ? 1.05 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { h in withAnimation(.spring(response: 0.3)) { hover = h } }
        .loop($pulse, .easeOut(duration: 2.0).repeatCount(3, autoreverses: false), active: enabled)
    }
}

struct PillButtonStyle: ButtonStyle {
    var colors: [Color]? = nil
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .padding(.horizontal, compact ? 11 : 15)
            .padding(.vertical, compact ? 5 : 8)
            .background(
                Capsule().fill(
                    colors.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) }
                        ?? AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.18 : 0.1))
                )
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.2), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.7))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hover ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help.isEmpty ? symbol : help)
        .onHover { hover = $0 }
    }
}

// MARK: - Selection

struct RoundCheck: View {
    let state: CheckState
    let colors: [Color]
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            if state == .off {
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
            } else {
                Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: state == .on ? "checkmark" : "minus")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .accessibilityElement()
        .accessibilityLabel(state == .on ? "Selected" : (state == .mixed ? "Partly selected" : "Not selected"))
        .accessibilityAddTraits(.isButton)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: state)
    }
}

struct Chip: View {
    let title: String
    var icon: String? = nil
    var count: Int? = nil
    let active: Bool
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(active ? 0.25 : 0.1)))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule().fill(
                    active ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.white.opacity(0.07))
                )
            )
            .overlay(Capsule().strokeBorder(.white.opacity(active ? 0.25 : 0.08)))
            .foregroundStyle(.white.opacity(active ? 1 : 0.75))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: active)
    }
}

// MARK: - Gauges

struct RingGauge<Center: View>: View {
    let fraction: Double
    let colors: [Color]
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(1, fraction)))
                .stroke(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.5), radius: 6)
            center
        }
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: fraction)
    }
}

struct SizeBar: View {
    let fraction: Double
    let colors: [Color]
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Screens

struct Bullet: Identifiable {
    var id: String { title }
    let icon: String
    let title: String
    let text: String
}

struct ModuleHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 18)
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct IntroScreen<Footer: View>: View {
    let module: Module
    let headline: String
    let bullets: [Bullet]
    let buttonTitle: String
    let action: () -> Void
    @ViewBuilder var footer: Footer
    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 56) {
                VStack(alignment: .leading, spacing: 22) {
                    Text(module.title.uppercased())
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(module.gradient)
                    Text(headline)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(bullets) { b in
                            HStack(alignment: .top, spacing: 14) {
                                GradientIcon(symbol: b.icon, colors: module.colors, size: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(b.title).font(.system(size: 14, weight: .semibold))
                                    Text(b.text)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.dim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    footer
                }
                .frame(maxWidth: 430, alignment: .leading)
                .offset(x: appear ? 0 : -20)
                .opacity(appear ? 1 : 0)

                HeroGlyph(module: module)
                    .scaleEffect(appear ? 1 : 0.85)
                    .opacity(appear ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)

            ActionButton(title: buttonTitle, colors: module.colors, action: action)
                .padding(.bottom, 48)
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { appear = true } }
    }
}

extension IntroScreen where Footer == EmptyView {
    init(module: Module, headline: String, bullets: [Bullet], buttonTitle: String, action: @escaping () -> Void) {
        self.init(module: module, headline: headline, bullets: bullets, buttonTitle: buttonTitle, action: action) { EmptyView() }
    }
}

struct ScanningRing: View {
    let module: Module
    var diameter: CGFloat = 210
    @Environment(\.isOnScreen) private var onScreen
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [module.colors[0].opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: diameter))
                .frame(width: diameter * 1.7, height: diameter * 1.7)
                .blur(radius: 20)
            Circle().stroke(.white.opacity(0.07), lineWidth: 14)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(
                    AngularGradient(colors: [module.colors[0].opacity(0), module.colors[0], module.colors[1]], center: .center),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(spin ? 360 : 0))
            Circle()
                .trim(from: 0, to: 0.35)
                .stroke(module.colors[1].opacity(0.5), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(26)
                .rotationEffect(.degrees(spin ? -360 : 0))
            Image(systemName: module.icon)
                .font(.system(size: diameter * 0.26, weight: .semibold))
                .foregroundStyle(module.gradient)
                .symbolEffect(.pulse, isActive: onScreen)
        }
        .frame(width: diameter, height: diameter)
        .loop($spin, .linear(duration: 1.3).repeatForever(autoreverses: false))
    }
}

struct ScanningScreen: View {
    let module: Module
    let title: String
    let detail: String
    var onStop: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ScanningRing(module: module)
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
                .contentTransition(.opacity)
            if let onStop {
                Button("Stop", action: onStop).buttonStyle(PillButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DoneScreen: View {
    let module: Module
    let title: String
    let subtitle: String
    let primary: String
    let primaryAction: () -> Void
    var secondary: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var extra: AnyView? = nil
    @State private var appear = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [module.colors[0].opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 200))
                    .frame(width: 360, height: 360)
                    .blur(radius: 16)
                Circle()
                    .fill(module.gradient)
                    .frame(width: 150, height: 150)
                    .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center)).padding(4))
                    .shadow(color: module.colors[0].opacity(0.6), radius: 30, y: 14)
                Image(systemName: "checkmark")
                    .font(.system(size: 62, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(height: 220)
            .scaleEffect(appear ? 1 : 0.5)
            .opacity(appear ? 1 : 0)

            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                Button(primary, action: primaryAction).buttonStyle(PillButtonStyle(colors: module.colors))
                if let secondary, let secondaryAction {
                    Button(secondary, action: secondaryAction).buttonStyle(PillButtonStyle())
                }
            }
            .padding(.top, 6)
            if let extra { extra.padding(.top, 8) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { appear = true } }
    }
}

/// Bottom bar with the selection summary on the left and the round action centred.
struct ActionBar<Leading: View>: View {
    let module: Module
    let buttonTitle: String
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        ZStack {
            HStack {
                leading
                Spacer()
            }
            ActionButton(title: buttonTitle, colors: module.colors, size: 92, enabled: enabled, action: action)
        }
        .padding(.horizontal, 32)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .background(
            LinearGradient(colors: [.clear, Theme.baseDeep.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }
}

struct SelectionSummary: View {
    let amount: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(amount)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
        }
        .animation(.spring(response: 0.3), value: amount)
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct Toast: View {
    let text: String
    let colors: [Color]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let text: String
    let colors: [Color]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.hasFullDiskAccess {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFE066), Color(hex: 0xFF9F43)], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Some folders are off-limits").font(.system(size: 12.5, weight: .semibold))
                    Text("Give Breeze Full Disk Access to clean Mail, Trash and app containers.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                    .buttonStyle(PillButtonStyle(compact: true))
                IconButton(symbol: "arrow.clockwise", help: "Check again") { model.refreshPermissions() }
            }
            .glass(radius: 14, padding: 12)
        }
    }
}


/// Lists what couldn't be removed, with the reason, and offers to finish the job.
struct LeftoversCard: View {
    let failures: [Cleaner.Failure]
    let working: Bool
    let colors: [Color]
    let onAdminRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFFB547))
                Text(failures.count == 1 ? "1 item couldn't be removed" : "\(failures.count) items couldn't be removed")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Fmt.bytes(failures.reduce(0) { $0 + $1.remaining }))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            ForEach(failures.prefix(4)) { f in
                HStack(spacing: 10) {
                    FileIcon(url: f.url, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(f.reason).font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.bytes(f.remaining)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
                    IconButton(symbol: "magnifyingglass", help: "Show in Finder") { Finder.reveal([f.url]) }
                }
            }
            if failures.contains(where: \.permanent) {
                HStack {
                    Text("macOS can be told to remove these with your admin password.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    Spacer()
                    Button(action: onAdminRemove) {
                        HStack(spacing: 6) {
                            if working { ProgressView().controlSize(.small) } else { Image(systemName: "lock.open") }
                            Text("Remove with Password")
                        }
                    }
                    .buttonStyle(PillButtonStyle(colors: colors, compact: true))
                    .disabled(working)
                }
                .padding(.top, 2)
            }
        }
        .frame(width: 520)
        .glass(radius: 16, padding: 14)
    }
}


/// Lays children out left to right and wraps onto new rows when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width && !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width = r.indices.isEmpty ? size.width : r.width + spacing + size.width
            r.height = max(r.height, size.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
