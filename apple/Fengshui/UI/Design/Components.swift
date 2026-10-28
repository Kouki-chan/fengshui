import Charts
import SwiftUI
import UIKit

/// Shared building blocks for the HealthBot look (DECISIONS D-23): rounded cards on a tinted
/// background, small uppercase section headers, stat tiles and a gradient hero.

struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: .rect(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct SectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    var systemImage: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(tint ?? theme.tint) }
            Text(title).textCase(.uppercase)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A titled block on a card screen: header + content.
struct CardSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, systemImage: systemImage, tint: tint)
            content
        }
    }
}

/// A metric with an optional sparkline.
struct StatTile: View {
    @Environment(\.theme) private var theme
    let title: String
    let value: String
    let unit: String
    let caption: String
    var systemImage: String?
    var series: [DataSnapshot.Point] = []
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption.weight(.semibold)).foregroundStyle(tint)
                }
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if series.count > 1 {
                Sparkline(points: series, tint: tint).frame(height: 24)
            }
            Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// A tiny line chart with a soft area fill; no axes.
struct Sparkline: View {
    let points: [DataSnapshot.Point]
    let tint: Color

    var body: some View {
        Chart(points, id: \.ts) { p in
            AreaMark(x: .value("Time", Date(timeIntervalSince1970: p.ts)), y: .value("Value", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", Date(timeIntervalSince1970: p.ts)), y: .value("Value", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

/// Rounded capsule label, e.g. "In bed 23:00".
struct Chip: View {
    let text: String
    var systemImage: String?
    var foreground: Color = .primary
    var background: Color = Color(.tertiarySystemFill)

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(background, in: .capsule)
    }
}

/// Icon in a rounded square, for list rows and empty states.
struct IconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The themed screen background behind a ScrollView of cards.
    func themedBackground() -> some View { modifier(ThemedBackground()) }

    /// Lists and forms: hide the system background and use the theme's (rows keep their cards).
    func themedList() -> some View { modifier(ThemedList()) }

    /// Text-entry screens: a Done button above the keyboard, and dragging the content hides it.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }.fontWeight(.semibold)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Resigns whichever text field has focus (the public responder-chain call; no private API).
@MainActor func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private struct ThemedBackground: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View { content.background(theme.background.ignoresSafeArea()) }
}

private struct ThemedList: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(theme.background.ignoresSafeArea())
    }
}

/// Three dots that pulse while HealthBot is thinking.
struct TypingIndicator: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().frame(width: 7, height: 7)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .foregroundStyle(.secondary)
        .onAppear { on = true }
        .accessibilityLabel("HealthBot is thinking")
    }
}
