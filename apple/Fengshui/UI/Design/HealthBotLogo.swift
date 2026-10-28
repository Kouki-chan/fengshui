import SwiftUI

/// The HealthBot mark: a heart-shaped bot head with an antenna, two eyes and a pulse-line smile.
/// Pure SwiftUI (no UIKit) so scripts/render_app_icon.sh can compile this file on the Mac and
/// render the app icons from the same drawing the app shows.
struct HealthBotMark: View {
    struct Colors {
        var heartTop: Color
        var heartBottom: Color
        var face: Color
        var stem: Color
        var bulb: Color

        static let lotus = Colors(heartTop: .rgb(0xF4C9D6), heartBottom: .rgb(0xD7809A), face: .rgb(0x1B2B28),
                                  stem: .rgb(0xD8BFCC), bulb: .rgb(0xE493AC))
        /// For the tinted icon: the system recolours it, so only lightness matters.
        static let mono = Colors(heartTop: .white, heartBottom: .rgb(0xD0D0D0), face: .rgb(0x202020),
                                 stem: .rgb(0xBDBDBD), bulb: .white)
    }

    var colors: Colors = .lotus

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack(alignment: .topLeading) {
                // Pins the stack to s × s so the offsets below are relative to the whole mark.
                Color.clear.frame(width: s, height: s)
                Capsule().fill(colors.stem)
                    .frame(width: s * 0.045, height: s * 0.17)
                    .offset(x: s * (0.5 - 0.0225), y: s * 0.13)
                Circle().fill(colors.bulb)
                    .frame(width: s * 0.12, height: s * 0.12)
                    .offset(x: s * 0.44, y: s * 0.06)
                HeartShape()
                    .fill(LinearGradient(colors: [colors.heartTop, colors.heartBottom], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.84, height: s * 0.72)
                    .offset(x: s * 0.08, y: s * 0.24)
                ForEach([0.355, 0.645], id: \.self) { x in
                    Capsule().fill(colors.face)
                        .frame(width: s * 0.075, height: s * 0.115)
                        .offset(x: s * (x - 0.0375), y: s * 0.44)
                }
                PulseLine()
                    .stroke(colors.face, style: StrokeStyle(lineWidth: s * 0.04, lineCap: .round, lineJoin: .round))
                    .frame(width: s * 0.40, height: s * 0.14)
                    .offset(x: s * 0.30, y: s * 0.585)
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A plump heart: wide lobes so it reads as a face, with a softened bottom point.
struct HeartShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.5, 0.17))
        path.addCurve(to: p(0.0, 0.30), control1: p(0.40, 0.00), control2: p(0.02, -0.02))
        path.addCurve(to: p(0.46, 0.97), control1: p(-0.02, 0.62), control2: p(0.30, 0.82))
        path.addQuadCurve(to: p(0.54, 0.97), control: p(0.5, 1.01))
        path.addCurve(to: p(1.0, 0.30), control1: p(0.70, 0.82), control2: p(1.02, 0.62))
        path.addCurve(to: p(0.5, 0.17), control1: p(0.98, -0.02), control2: p(0.60, 0.00))
        path.closeSubpath()
        return path
    }
}

/// A short ECG trace used as the mouth: flat, a small dip, a spike, a dip, flat.
struct PulseLine: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(Double, Double)] = [(0, 0.55), (0.30, 0.55), (0.40, 0.80), (0.52, 0.0), (0.64, 1.0), (0.72, 0.55), (1, 0.55)]
        var path = Path()
        for (i, q) in pts.enumerated() {
            let pt = CGPoint(x: r.minX + q.0 * r.width, y: r.minY + q.1 * r.height)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

/// The full app icon artwork (square, full bleed; the system applies the corner mask).
struct HealthBotIcon: View {
    enum Variant { case standard, dark, tinted, watch }
    var variant: Variant = .standard

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                background
                if variant != .tinted {
                    // A soft teal glow behind the heart.
                    RadialGradient(colors: [Color.rgb(0x4FA3A1).opacity(variant == .dark ? 0.28 : 0.45), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.55), startRadius: 0, endRadius: s * 0.5)
                }
                HealthBotMark(colors: variant == .tinted ? .mono : .lotus)
                    .frame(width: s * (variant == .watch ? 0.60 : 0.66))
                    .offset(y: -s * 0.015)
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder private var background: some View {
        switch variant {
        case .standard, .watch:
            LinearGradient(colors: [.rgb(0x2C6A6B), .rgb(0x163330)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .dark:
            LinearGradient(colors: [.rgb(0x18302C), .rgb(0x0B1412)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .tinted:
            Color.black
        }
    }
}

/// The mark on a rounded tile, for in-app headers (onboarding, Ask, Settings).
struct HealthBotLogo: View {
    var size: CGFloat = 64

    var body: some View {
        HealthBotIcon()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: size * 0.08, y: size * 0.04)
            .accessibilityLabel("HealthBot")
    }
}

extension Color {
    static func rgb(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
