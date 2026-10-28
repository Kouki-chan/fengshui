import SwiftUI
import UIKit

/// HealthBot colour schemes (DECISIONS D-23). Each theme is a five-colour palette, darkest to
/// lightest like a mood board, mapped onto roles that every screen uses: tint, surfaces, the
/// hero gradient and one colour per data family (heart, activity, sleep). Every role has a
/// light and a dark value, so text keeps its contrast in both appearances.
struct Theme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mood: String
    /// The palette as shown in Settings → Appearance (darkest → lightest).
    let swatches: [Color]
    /// Buttons, links, selection, the user's chat bubbles.
    let tint: Color
    /// A second highlight: badges, the live dot, chips.
    let highlight: Color
    let background: Color
    let surface: Color
    /// Text and icons placed on the hero gradient.
    let onHero: Color
    let heroStart: Color
    let heroEnd: Color
    let heart: Color
    let activity: Color
    let sleep: Color

    var heroGradient: LinearGradient {
        LinearGradient(colors: [heroStart, heroEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let all: [Theme] = [.lotus, .ocean, .sage, .ember, .midnight, .classic]
    static let `default` = Theme.lotus

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? .default }
}

extension Theme {
    /// From the lotus mood board: deep forest, teal, plum, rose, blush.
    static let lotus = Theme(
        id: "lotus", name: "Lotus", mood: "Forest, teal, plum, rose, blush",
        swatches: [.hex(0x1B2B28), .hex(0x23595C), .hex(0x87536E), .hex(0xD7809A), .hex(0xD8BFCC)],
        tint: .dynamic(0x23595C, 0xE493AC), highlight: .dynamic(0xB4557A, 0xE493AC),
        background: .dynamic(0xF6F0F3, 0x0F1A18), surface: .dynamic(0xFFFFFF, 0x1A2A27),
        onHero: .white, heroStart: .dynamic(0x23595C, 0x1F4E50), heroEnd: .dynamic(0x87536E, 0x6E4359),
        heart: .dynamic(0xC9617F, 0xE493AC), activity: .dynamic(0x23797C, 0x5BB5B3), sleep: .dynamic(0x87536E, 0xC08DAA))

    static let ocean = Theme(
        id: "ocean", name: "Ocean", mood: "Navy, deep blue, cerulean, aqua, mist",
        swatches: [.hex(0x0B1F33), .hex(0x1F4E79), .hex(0x2E86AB), .hex(0x5FC9C2), .hex(0xE6F0F2)],
        tint: .dynamic(0x1F6FA3, 0x6FD3CC), highlight: .dynamic(0x2E86AB, 0x6FD3CC),
        background: .dynamic(0xF0F5F8, 0x08141F), surface: .dynamic(0xFFFFFF, 0x10243A),
        onHero: .white, heroStart: .dynamic(0x1F4E79, 0x173B5C), heroEnd: .dynamic(0x2E86AB, 0x1F6C87),
        heart: .dynamic(0xD9534F, 0xF08A86), activity: .dynamic(0x1F8A84, 0x5FC9C2), sleep: .dynamic(0x3B5BA5, 0x8EA8E8))

    static let sage = Theme(
        id: "sage", name: "Sage", mood: "Pine, moss, sage, honey, linen",
        swatches: [.hex(0x1F2A1E), .hex(0x4A6B4F), .hex(0x8AA67E), .hex(0xD9A15B), .hex(0xEFE9DC)],
        tint: .dynamic(0x41634A, 0xAFCBA2), highlight: .dynamic(0xB57A2E, 0xE2B06E),
        background: .dynamic(0xF5F2EA, 0x121811), surface: .dynamic(0xFFFFFF, 0x1E281D),
        onHero: .white, heroStart: .dynamic(0x4A6B4F, 0x34503A), heroEnd: .dynamic(0x8AA67E, 0x5E7B53),
        heart: .dynamic(0xC0583A, 0xE58E70), activity: .dynamic(0x4A7B52, 0x9CC48E), sleep: .dynamic(0x6A6A9A, 0xA9A9D6))

    static let ember = Theme(
        id: "ember", name: "Ember", mood: "Espresso, brick, ember, apricot, sand",
        swatches: [.hex(0x2A1B17), .hex(0x8C3B2E), .hex(0xD1643B), .hex(0xF2A65A), .hex(0xF6E3D3)],
        tint: .dynamic(0xA9442A, 0xF2A65A), highlight: .dynamic(0xD1643B, 0xF2A65A),
        background: .dynamic(0xFAF3EC, 0x161010), surface: .dynamic(0xFFFFFF, 0x2A1E1A),
        onHero: .white, heroStart: .dynamic(0x8C3B2E, 0x6E2E24), heroEnd: .dynamic(0xD1643B, 0xA44E2E),
        heart: .dynamic(0xC2334D, 0xF0788C), activity: .dynamic(0xC56A1C, 0xF2A65A), sleep: .dynamic(0x6B4E8C, 0xB49AD6))

    static let midnight = Theme(
        id: "midnight", name: "Midnight", mood: "Ink, indigo, violet, lavender, haze",
        swatches: [.hex(0x14122B), .hex(0x3B2F7A), .hex(0x6C5CE7), .hex(0xA29BFE), .hex(0xE9E7FB)],
        tint: .dynamic(0x4F3FC9, 0xA9A2FF), highlight: .dynamic(0x6C5CE7, 0xA9A2FF),
        background: .dynamic(0xF3F2FB, 0x0C0B1A), surface: .dynamic(0xFFFFFF, 0x1A1833),
        onHero: .white, heroStart: .dynamic(0x3B2F7A, 0x2C2360), heroEnd: .dynamic(0x6C5CE7, 0x5246B8),
        heart: .dynamic(0xD6456E, 0xF58BAA), activity: .dynamic(0x1E8C93, 0x62D0C8), sleep: .dynamic(0x6C5CE7, 0xA9A2FF))

    /// Apple's system colours, for people who prefer the stock look.
    static let classic = Theme(
        id: "classic", name: "Classic", mood: "Standard iOS colours",
        swatches: [Color(.label), .blue, .green, .orange, Color(.systemGray5)],
        tint: .blue, highlight: .blue,
        background: Color(.systemGroupedBackground), surface: Color(.secondarySystemGroupedBackground),
        onHero: .white, heroStart: .blue, heroEnd: .indigo,
        heart: .red, activity: .green, sleep: .indigo)
}

extension Color {
    static func hex(_ rgb: UInt32) -> Color { Color(uiColor: .hex(rgb)) }

    /// One colour for light appearance, another for dark.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .hex(dark) : .hex(light) })
    }
}

extension UIColor {
    static func hex(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .default
}

/// The chosen theme and light/dark preference. A display preference only, so it lives in
/// UserDefaults rather than the health database.
@MainActor
@Observable
final class Appearance {
    enum Mode: String, CaseIterable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        var id: String { rawValue }
        var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    }

    static let themeKey = "appearance.theme"
    static let modeKey = "appearance.mode"
    private let defaults: UserDefaults

    var theme: Theme { didSet { defaults.set(theme.id, forKey: Self.themeKey) } }
    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Theme.named(defaults.string(forKey: Self.themeKey) ?? Theme.default.id)
        mode = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .system
    }
}
