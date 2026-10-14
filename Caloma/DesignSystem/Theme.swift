import SwiftUI

/// Keys for settings stored with @AppStorage. Keep every key here so views stay in sync.
nonisolated enum SettingsKey {
    /// Onboarding has been finished.
    static let onboarded = "onboarding.done"
    /// The starter home care tasks have been added (first launch).
    static let seeded = "data.seeded"
    /// The parent this device belongs to.
    static let currentMember = "family.currentMember"
    /// The Sign in with Apple user, when they chose to sign in.
    static let appleUserID = "account.appleUserID"
    /// What the family calls points: a `PointName` raw value.
    static let pointName = "points.name"
    /// The word used when `pointName` is `.custom`.
    static let customPointName = "points.customName"
    /// New chores need a parent's OK before points land.
    static let approvalsByDefault = "points.approvalsByDefault"
    /// +10 for every 7 days in a row of finished chores.
    static let streakBonus = "points.streakBonus"
    /// Points turn into allowance on payday.
    static let allowanceOn = "allowance.on"
    /// Cents paid for every 100 points.
    static let centsPer100 = "allowance.centsPer100"
    /// 1 = Sunday … 7 = Saturday.
    static let payday = "allowance.payday"
    static let splitSpend = "allowance.split.spend"
    static let splitSave = "allowance.split.save"
    static let splitGive = "allowance.split.give"
    /// The accent color as "#RRGGBB".
    static let accentHex = "appearance.accent"
    /// Kid View was open when the app last closed, so it opens again.
    static let kidViewOpen = "kidView.open"
    /// The kid Kid View last showed.
    static let kidViewMember = "kidView.member"
    /// What the family calls itself, for the sharing invitation ("The Warrens").
    static let familyName = "family.name"
    /// Remind about home care tasks before they're due.
    static let homeReminders = "homeCare.reminders"
    /// Notify parents when a chore or reward needs their OK (on unless turned off).
    static let approvalAlerts = "approvals.alerts"
}

/// Caloma's colors, from the Tend designs on the Claude Design canvas.
nonisolated enum Brand {
    /// The default accent, the rose of the app icon's gradient, deep enough for white text.
    /// People can pick another in Family › Accent Color.
    static let defaultAccentHex: UInt32 = 0xE0284F
    static var defaultAccent: Color { Color(hex: defaultAccentHex) }

    /// The accent choices in Family, in order.
    static let accents: [AccentChoice] = [
        AccentChoice(name: "Rose", hex: 0xE0284F),
        AccentChoice(name: "Green", hex: 0x1E9E6A), AccentChoice(name: "Teal", hex: 0x0E8A8A),
        AccentChoice(name: "Blue", hex: 0x0A7AFF), AccentChoice(name: "Indigo", hex: 0x5E5CE6),
        AccentChoice(name: "Pink", hex: 0xC2185B),
        AccentChoice(name: "Orange", hex: 0xE8650F),
    ]

    /// The gold of stars, everywhere points show.
    static let star = Color(hex: 0xF5A623)
    /// The brighter gold kids see.
    static let starBright = Color(hex: 0xFFCC00)
    /// "Waiting for OK" and things due soon.
    static let waiting = Color(hex: 0xC46A00)
    /// Overdue home care.
    static let late = Color(hex: 0xD93B30)
}

nonisolated struct AccentChoice: Hashable, Sendable {
    var name: String
    var hex: UInt32
}

extension EnvironmentValues {
    /// The family's accent color (Family › Accent Color).
    @Entry var accent: Color = Brand.defaultAccent
}

/// A person's color: their avatar, a kid's column on the chore board and the whole of Kid
/// View. One of the presets, or a custom color someone picked, saved as "#RRGGBB". The raw
/// value is what's stored, so the preset names saved before ("blue", "purple"…) read the same.
nonisolated struct KidColor: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard Self.presetHex[rawValue] != nil || Self.parseHex(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(preset: String) { rawValue = preset }

    /// A custom color.
    init(hex: UInt32) { rawValue = hexString(hex) }

    static let blue = KidColor(preset: "blue")
    static let purple = KidColor(preset: "purple")
    static let orange = KidColor(preset: "orange")
    static let green = KidColor(preset: "green")
    static let pink = KidColor(preset: "pink")
    static let teal = KidColor(preset: "teal")
    static let indigo = KidColor(preset: "indigo")
    static let red = KidColor(preset: "red")
    /// Gray, for anyone who'd rather not have a color. Parents used to start out gray.
    static let gray = KidColor(preset: "gray")

    /// The presets handed out to kids, in order. Teal and pink come last, since parents get
    /// those first.
    static let allCases: [KidColor] = [.blue, .purple, .orange, .green, .indigo, .red, .pink, .teal]
    /// The presets handed out to parents, in order.
    static let parentCases: [KidColor] = [.teal, .pink, .indigo, .red]
    /// Every preset a profile can pick, gray included.
    static let swatches: [KidColor] = allCases + [.gray]

    var id: String { rawValue }
    var isCustom: Bool { Self.presetHex[rawValue] == nil }
    var name: String { isCustom ? "Custom" : rawValue.capitalized }
    var hex: UInt32 { Self.presetHex[rawValue] ?? Self.parseHex(rawValue) ?? 0x8E8E93 }
    var color: Color { Color(hex: hex) }

    /// The colors handed out as kids are added, so siblings start out different.
    static func next(after used: [KidColor]) -> KidColor {
        allCases.first { !used.contains($0) } ?? allCases[used.count % allCases.count]
    }

    /// The next color for someone joining the family, different from everyone else's.
    static func next(for role: MemberRole, after used: [KidColor]) -> KidColor {
        let order = role == .kid ? allCases : parentCases + allCases.filter { !parentCases.contains($0) }
        return order.first { !used.contains($0) } ?? order[used.count % order.count]
    }

    private static let presetHex: [String: UInt32] = [
        "blue": 0x0A84FF, "purple": 0xAF52DE, "orange": 0xFF9F0A, "green": 0x1E9E6A,
        "pink": 0xE0457B, "teal": 0x0E8A8A, "indigo": 0x5E5CE6, "red": 0xD93B30, "gray": 0x8E8E93,
    ]

    private static func parseHex(_ raw: String) -> UInt32? {
        guard raw.hasPrefix("#"), raw.count == 7 else { return nil }
        return UInt32(raw.dropFirst(), radix: 16)
    }
}

/// What the family calls points. Each has its own symbol.
nonisolated enum PointName: String, CaseIterable, Identifiable, Sendable {
    case points, stars, coins, custom

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .coins: "dollarsign.circle.fill"
        default: "star.fill"
        }
    }
}

/// The family's word for points, read from settings: "stars", "coins", or their own.
nonisolated struct PointWords: Sendable {
    var plural: String
    var symbol: String

    /// "Stars", for titles.
    var title: String { plural.prefix(1).uppercased() + plural.dropFirst() }

    /// "1 star", "15 stars".
    func count(_ n: Int) -> String {
        let singular = plural.hasSuffix("s") ? String(plural.dropLast()) : plural
        return "\(n.formatted()) \(abs(n) == 1 ? singular : plural)"
    }

    static func current(_ defaults: UserDefaults = .standard) -> PointWords {
        let name = PointName(rawValue: defaults.string(forKey: SettingsKey.pointName) ?? "") ?? .stars
        if name == .custom {
            let custom = (defaults.string(forKey: SettingsKey.customPointName) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return PointWords(plural: custom.isEmpty ? "points" : custom, symbol: name.symbol)
        }
        return PointWords(plural: name.rawValue, symbol: name.symbol)
    }
}

extension Color {
    nonisolated init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Reads "#RRGGBB".
    nonisolated init?(hexString: String) {
        guard hexString.hasPrefix("#"), hexString.count == 7, let value = UInt32(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value)
    }
}

extension Color {
    /// The color as 0xRRGGBB in sRGB, for saving a color someone picked.
    var hexValue: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return (channel(r) << 16) | (channel(g) << 8) | channel(b)
    }
}

/// "#1E9E6A" for a hex value, for storing the accent.
nonisolated func hexString(_ value: UInt32) -> String {
    String(format: "#%06X", value & 0xFFFFFF)
}
