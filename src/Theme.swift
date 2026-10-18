import Cocoa
import SwiftUI

// Theme
// -----
// Verbaline's one look, used by every window and panel: warm and roomy like a notebook, not a control panel.
// Light mode is a warm cream page with soft beige cards; dark mode uses the menu bar panel's dark greys.
// Verbaline's two colours carry meaning everywhere: teal = Verbaline / the other person ("Them"),
// violet = you ("You", your toggles). Big numbers and titles use the serif (New York); small labels
// are UPPERCASE, small, spaced out and grey. See docs/design-system.md for the rules.
//
//     Theme.page / .card / .raised / .line       backgrounds and hairlines
//     Theme.text / .dim / .faint                  text, from strongest to weakest
//     Theme.teal* / .violet* / .red / .amber      accents (each with a soft background and readable text)
//     Theme.title(size) / .number(size)           serif fonts
//     Theme.caption                               the small spaced-out label font
//     .themeCard() / .themeCaption()              view helpers

enum Theme {
    // MARK: surfaces
    static let page   = dynamic(light: 0xFAF8F3, dark: 0x1C1C1E)
    static let card   = dynamic(light: 0xF1EEE6, dark: 0x2A2A2D)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x323236)   // inputs, buttons on a card
    static let line   = dynamic(light: 0xE4E0D6, dark: 0x3A3A3C)

    // MARK: text
    static let text  = dynamic(light: 0x2C2C2A, dark: 0xF2F2F2)
    static let dim   = dynamic(light: 0x6B6A64, dark: 0xA1A1A6)
    static let faint = dynamic(light: 0x8F8E88, dark: 0x8F8F94)

    // MARK: accents
    static let teal       = dynamic(light: 0x0F6E56, dark: 0x5DCAA5)   // "Them", links, Verbaline's mark
    static let tealSoft   = dynamic(light: 0xE1F5EE, dark: 0x04342C)
    static let tealOnSoft = dynamic(light: 0x085041, dark: 0x9FE1CB)
    static let violet       = dynamic(light: 0x534AB7, dark: 0xCECBF6) // "You"
    static let violetSoft   = dynamic(light: 0xEEEDFE, dark: 0x26215C)
    static let violetOnSoft = dynamic(light: 0x3C3489, dark: 0xCECBF6)
    static let red   = dynamic(light: 0xE24B4A, dark: 0xE24B4A)        // recording dot, errors
    static let amber = dynamic(light: 0xBA7517, dark: 0xEF9F27)        // warnings

    // MARK: logo (fixed colours for the app icon file; the in-app mark uses teal/violet above)
    static let logoPage   = rgb(0xFAF8F3)
    static let logoLine   = rgb(0xE4E0D6)
    static let logoV      = rgb(0x0F6E56)
    static let logoBars   = rgb(0x534AB7)

    // MARK: shape and spacing
    static let cardRadius: CGFloat = 14
    static let windowRadius: CGFloat = 18
    static let gap: CGFloat = 12
    static let pad: CGFloat = 18

    // MARK: type
    static func title(_ size: CGFloat = 26) -> Font { .system(size: size, design: .serif) }
    static func number(_ size: CGFloat = 30) -> Font { .system(size: size, design: .serif) }
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 11, weight: .medium)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// A soft rounded card on the page.
    func themeCard(padding: CGFloat = 16) -> some View {
        self.padding(padding).background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

extension Text {
    /// Small spaced-out grey label, Wispr-style: "DOWN PAYMENT", "WORDS PER MINUTE".
    func themeCaption() -> some View {
        self.font(Theme.caption).kerning(0.9).foregroundColor(Theme.dim).textCase(.uppercase)
    }
}

// MARK: Insights calendar
// Five shades for "how much did I dictate that day": none, then light → deep teal.
extension Theme {
    static let heat: [Color] = [
        dynamic(light: 0xE4E0D6, dark: 0x3A3A3C),
        dynamic(light: 0x9FE1CB, dark: 0x085041),
        dynamic(light: 0x5DCAA5, dark: 0x0F6E56),
        dynamic(light: 0x1D9E75, dark: 0x1D9E75),
        dynamic(light: 0x0F6E56, dark: 0x5DCAA5),
    ]
    /// The day number printed on each shade, readable on it.
    static let heatText: [Color] = [
        dynamic(light: 0x8F8E88, dark: 0x8F8F94),
        dynamic(light: 0x085041, dark: 0x9FE1CB),
        dynamic(light: 0x04342C, dark: 0xE1F5EE),
        dynamic(light: 0xFFFFFF, dark: 0xFFFFFF),
        dynamic(light: 0xFFFFFF, dark: 0x04342C),
    ]
}
