import SwiftUI

/// One ring segment. Angles are radians measured clockwise from 12 o'clock.
struct ArcSegment: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(start, end), AnimatablePair(inner, outer)) }
        set {
            start = newValue.first.first
            end = newValue.first.second
            inner = newValue.second.first
            outer = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let span = max(0, end - start)
        let pad = min(0.008, span * 0.18)
        let s = start + pad
        let e = max(s + 0.0001, end - pad)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .radians(s - .pi / 2), endAngle: .radians(e - .pi / 2), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .radians(e - .pi / 2), endAngle: .radians(s - .pi / 2), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct OrbitSegment: Identifiable {
    let id: String
    let ring: Int
    let name: String
    let size: Int64
    let isDirectory: Bool
    let start: Double
    let end: Double
    let hue: Double
    let shade: Double
    let url: URL?          // nil for the "Other" bucket
    let parent: URL?       // set on outer-ring segments
    let selected: Bool
}

struct OrbitView: View {
    @Environment(AppModel.self) private var model
    @State private var hoveredID: String?
    @State private var appear = 0.0
    @State private var spin = false

    var body: some View {
        let lens = model.lens
        let total = Double(max(1, lens.total))
        let segments = Self.layout(lens.sortedNodes, total: total)

        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let R = side / 2 - 18
            let hole = R * 0.34
            let r1 = (hole + 6, R * 0.68)
            let r2 = (R * 0.70, R * 0.95)
            let hovered = segments.first { $0.id == hoveredID }

            ZStack {
                // Decorative orbit rings
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                    .foregroundStyle(.white.opacity(0.12))
                    .frame(width: (R + 12) * 2, height: (R + 12) * 2)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                if lens.loading {
                    Circle()
                        .trim(from: 0, to: 0.08)
                        .stroke(LinearGradient(colors: Module.spaceLens.colors, startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: (R + 12) * 2, height: (R + 12) * 2)
                        .rotationEffect(.degrees(spin ? 720 : 0))
                        .shadow(color: Module.spaceLens.colors[0], radius: 6)
                }

                // Rings
                ForEach(segments) { seg in
                    let isHover = seg.id == hoveredID
                    let related = hovered.map { h in h.id == seg.id || seg.parent == h.url || h.parent == seg.url } ?? true
                    let radii = seg.ring == 1 ? r1 : r2
                    ArcSegment(
                        start: seg.start * appear,
                        end: seg.end * appear,
                        inner: radii.0 + (isHover && seg.ring == 1 ? -3 : 0),
                        outer: radii.1 + (isHover ? 12 : 0)
                    )
                    .fill(fill(for: seg, inner: radii.0, outer: radii.1))
                    .overlay(
                        ArcSegment(start: seg.start * appear, end: seg.end * appear, inner: radii.0, outer: radii.1 + (isHover ? 12 : 0))
                            .stroke(.white.opacity(seg.selected ? 0.95 : 0), lineWidth: 2.5)
                    )
                    .opacity(related ? 1 : 0.35)
                    .shadow(color: Color(hue: seg.hue, saturation: 0.8, brightness: 1).opacity(isHover ? 0.75 : 0), radius: 14)
                    .allowsHitTesting(false)
                }

                // Centre disc
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)], center: .top, startRadius: 0, endRadius: hole * 1.4))
                    .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                    .frame(width: hole * 2 - 8, height: hole * 2 - 8)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                CenterLabel(segment: hovered, total: lens.total, folder: lens.current, canGoUp: lens.trail.count > 1, loading: lens.loading)
                    .frame(width: hole * 1.6)
                    .allowsHitTesting(false)
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let id = hit(p, in: g.size, hole: hole, r1: r1, r2: r2, segments: segments)
                    if id != hoveredID {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hoveredID = id }
                        let seg = segments.first { $0.id == id }
                        lens.hovered = seg?.ring == 1 ? seg?.url : seg?.parent
                    }
                case .ended:
                    withAnimation(.spring(response: 0.3)) { hoveredID = nil }
                    lens.hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                if hypot(p.x - c.x, p.y - c.y) < hole {
                    lens.back()
                    return
                }
                guard let id = hit(p, in: g.size, hole: hole, r1: r1, r2: r2, segments: segments),
                      let seg = segments.first(where: { $0.id == id }), let url = seg.url else { return }
                if seg.ring == 1 {
                    if seg.isDirectory { lens.enter(url) } else { lens.toggle(url) }
                } else if let parent = seg.parent {
                    lens.enter(path: seg.isDirectory ? [parent, url] : [parent])
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
        .onAppear {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.86)) { appear = 1 }
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) { spin = true }
        }
    }

    private func fill(for seg: OrbitSegment, inner: CGFloat, outer: CGFloat) -> some ShapeStyle {
        let sat = seg.isDirectory ? 0.62 : 0.28
        let base = seg.ring == 1 ? 0.98 : 0.86 - seg.shade * 0.12
        return RadialGradient(
            colors: [
                Color(hue: seg.hue, saturation: sat * 0.85, brightness: base),
                Color(hue: (seg.hue + 0.05).truncatingRemainder(dividingBy: 1), saturation: sat + 0.15, brightness: base - 0.22),
            ],
            center: .center, startRadius: inner, endRadius: outer
        )
    }

    private func hit(_ p: CGPoint, in size: CGSize, hole: CGFloat, r1: (CGFloat, CGFloat), r2: (CGFloat, CGFloat), segments: [OrbitSegment]) -> String? {
        let dx = p.x - size.width / 2
        let dy = p.y - size.height / 2
        let d = hypot(dx, dy)
        var a = atan2(Double(dx), Double(-dy))
        if a < 0 { a += 2 * .pi }
        let ring: Int
        if d >= r1.0 && d <= r1.1 + 4 { ring = 1 }
        else if d >= r2.0 - 2 && d <= r2.1 + 12 { ring = 2 }
        else { return nil }
        return segments.first { $0.ring == ring && a >= $0.start && a < $0.end && $0.url != nil }?.id
    }

    /// Lays children around the inner ring and grandchildren around the outer ring.
    static func layout(_ nodes: [LensNode], total: Double) -> [OrbitSegment] {
        var out: [OrbitSegment] = []
        var angle = 0.0
        var other: Int64 = 0
        let full = 2 * Double.pi
        var i = 0
        for n in nodes {
            guard let s = n.size, s > 0 else { continue }
            let span = Double(s) / total * full
            if span < 0.03 { other += s; continue }
            let hue = (0.56 + Double(i) * 0.083).truncatingRemainder(dividingBy: 1)
            out.append(OrbitSegment(
                id: n.url.path, ring: 1, name: n.name, size: s, isDirectory: n.isDirectory,
                start: angle, end: angle + span, hue: hue, shade: 0, url: n.url, parent: nil, selected: n.selected
            ))
            // Outer ring: this folder's own children, within its slice.
            var a2 = angle
            for (j, c) in n.children.enumerated() {
                let cspan = Double(c.size) / Double(s) * span
                guard cspan > 0.012 else { continue }
                let curl = n.url.appendingPathComponent(c.name)
                out.append(OrbitSegment(
                    id: curl.path, ring: 2, name: c.name, size: c.size, isDirectory: c.isDirectory,
                    start: a2, end: a2 + cspan, hue: hue, shade: Double(j % 3), url: curl, parent: n.url, selected: false
                ))
                a2 += cspan
            }
            angle += span
            i += 1
        }
        if other > 0 {
            let span = Double(other) / total * full
            out.append(OrbitSegment(
                id: "__other", ring: 1, name: "Smaller items", size: other, isDirectory: false,
                start: angle, end: min(full, angle + span), hue: 0.62, shade: 0, url: nil, parent: nil, selected: false
            ))
        }
        return out
    }
}

private struct CenterLabel: View {
    let segment: OrbitSegment?
    let total: Int64
    let folder: URL?
    let canGoUp: Bool
    let loading: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let s = segment {
                Image(systemName: s.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hue: s.hue, saturation: 0.55, brightness: 1))
                Text(s.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(Fmt.bytes(s.size))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(total > 0 ? (Double(s.size) / Double(total)).formatted(.percent.precision(.fractionLength(1))) : "")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
                if s.isDirectory && s.url != nil {
                    Text("Click to open").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
            } else {
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Text(Fmt.bytes(total))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(loading ? "Measuring…" : (canGoUp ? "Click here to go up" : "Hover a ring to explore"))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }
        }
        .animation(.spring(response: 0.3), value: segment?.id)
        .animation(.spring(response: 0.4), value: total)
    }

    private var displayName: String {
        guard let folder else { return "" }
        if folder.path == "/" { return "Macintosh HD" }
        if folder.path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
        return folder.lastPathComponent
    }
}
