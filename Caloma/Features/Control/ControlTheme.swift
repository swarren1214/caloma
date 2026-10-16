import HomeKit
import SwiftUI
import UIKit

/// Control's look: the glow behind the screen tinted by the running scene, glass cards, and
/// tiles in three styles (tinted, solid, glow) that light up in their device's color.
enum ControlTheme {
    /// Lamp light.
    static let amber = Color(hex: 0xFFB020)
    /// Readable amber text, darker in light mode.
    static let amberText = Color(light: 0x8A5300, dark: 0xFFC34D)
    /// Locked, closed, armed, clear.
    static let secure = Color(hex: 0x1E9E6A)
    /// Unlocked, open: worth a look.
    static let attention = Color(light: 0xC46A00, dark: 0xFF9F0A)
    /// Smoke, carbon monoxide, water where it shouldn't be.
    static let alarm = Color(hex: 0xFF453A)
    static let water = Color(light: 0x0A7AFF, dark: 0x409CFF)
    static let air = Color(light: 0x0E8A8A, dark: 0x40C8E0)
    static let shades = Color(light: 0x5E5CE6, dark: 0x8E8CFF)
    static let warm = Color(hex: 0xFF7A1A)

    /// The 18 colors offered for a device, in the picker's order.
    static let palette: [(name: String, hex: UInt32)] = [
        ("Amber", 0xFFB020), ("Orange", 0xFF7A1A), ("Red", 0xFF453A), ("Rose", 0xE0284F), ("Green", 0x30C46B),
        ("Teal", 0x2EC4C4), ("Blue", 0x0A84FF), ("Indigo", 0x5E5CE6), ("Purple", 0xBF5AF2),
        ("Pink", 0xFF6FA8), ("Brown", 0xA2845E), ("Slate", 0x8E8E93), ("Mint", 0x63E6BE), ("Sky", 0x64D2FF),
        ("Lemon", 0xFFD60A), ("Coral", 0xFF8A65), ("Lavender", 0xB39DFF), ("Cloud", 0xE5E5EA),
    ]

    /// A scene's color: the one the family picked, else one that fits what it's for.
    static func color(for scene: HomeScene, style: DeviceStyle?) -> Color {
        if let picked = style?.color { return picked }
        switch scene.type {
        case HMActionSetTypeWakeUp: return Color(hex: 0xFF9F0A)
        case HMActionSetTypeSleep: return Color(hex: 0x30B0C7)
        case HMActionSetTypeHomeDeparture: return Color(hex: 0x8E8E93)
        case HMActionSetTypeHomeArrival: return Color(hex: 0x1E9E6A)
        default: break
        }
        let name = scene.name.lowercased()
        let has = { (words: [String]) in words.contains { name.contains($0) } }
        if has(["movie", "tv", "film", "show"]) { return Color(hex: 0x5E5CE6) }
        if has(["dinner", "cook", "kitchen", "breakfast", "lunch"]) { return Color(hex: 0xE8650F) }
        if has(["party", "fun", "dance"]) { return Color(hex: 0xFF6FA8) }
        if has(["read", "relax", "chill", "calm"]) { return Color(hex: 0x0E8A8A) }
        if has(["night", "bed", "sleep"]) { return Color(hex: 0x30B0C7) }
        if has(["morning", "wake"]) { return Color(hex: 0xFF9F0A) }
        return Color(hex: 0xAF52DE)
    }
}

extension Color {
    /// A color with its own light and dark mode values.
    init(light: UInt32, dark: UInt32) {
        let lightColor = UIColor(Color(hex: light))
        let darkColor = UIColor(Color(hex: dark))
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }

    /// Whether text on this color should be dark (lemon, cloud, mint) rather than white.
    var prefersDarkText: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.72
    }
}

extension EnvironmentValues {
    /// Called when someone changes a device by hand, so the running scene's glow lets go.
    @Entry var controlTouched: () -> Void = {}
}

// MARK: - A device's look

/// Everything a tile needs to draw a device: its symbols, color, style and photo, from the
/// family's style when there is one, else the kind's own.
struct DeviceLook {
    var symbolOn: String
    var symbolOff: String
    var color: Color
    var tileStyle: TileStyle
    var photo: Data?

    init(control: HomeControl, style: DeviceStyle?, accent: Color) {
        let defaults = Self.defaults(for: control.kind)
        if let custom = style?.symbol, !custom.isEmpty {
            symbolOn = custom
            symbolOff = custom
        } else {
            symbolOn = defaults.on
            symbolOff = defaults.off
        }
        color = style?.color ?? Self.defaultColor(for: control.kind, accent: accent)
        tileStyle = style?.tileStyle ?? .tinted
        photo = style?.photoData
    }

    func symbol(_ on: Bool) -> String { on ? symbolOn : symbolOff }

    static func defaults(for kind: HomeControl.Kind) -> (on: String, off: String) {
        switch kind {
        case .light: ("lightbulb.fill", "lightbulb")
        case .switchOrOutlet: ("poweroutlet.type.b.fill", "poweroutlet.type.b")
        case .fan: ("fan.fill", "fan")
        case .lock: ("lock.fill", "lock.open.fill")
        case .garage: ("door.garage.closed", "door.garage.open")
        case .thermostat: ("thermometer.medium", "thermometer.medium")
        case .shade: ("blinds.horizontal.open", "blinds.horizontal.closed")
        case .door: ("door.left.hand.open", "door.left.hand.closed")
        case .window: ("window.vertical.open", "window.vertical.closed")
        case .securitySystem: ("shield.lefthalf.filled", "shield")
        case .smoke: ("smoke.fill", "smoke")
        case .carbonMonoxide: ("carbon.monoxide.cloud.fill", "carbon.monoxide.cloud")
        case .leak: ("drop.triangle.fill", "drop")
        case .airPurifier: ("air.purifier.fill", "air.purifier")
        case .humidifier: ("humidifier.fill", "humidifier")
        case .heaterCooler: ("heater.vertical.fill", "heater.vertical")
        case .airQuality: ("aqi.medium", "aqi.medium")
        case .valve: ("spigot.fill", "spigot")
        case .faucet: ("spigot.fill", "spigot")
        case .button: ("button.programmable", "button.programmable")
        case .temperature: ("thermometer.medium", "thermometer.medium")
        case .humidity: ("humidity.fill", "humidity")
        case .contact: ("door.left.hand.open", "door.left.hand.closed")
        case .motion: ("figure.walk.motion", "figure.stand")
        case .occupancy: ("person.fill", "person")
        case .lightLevel: ("sun.max.fill", "sun.max")
        }
    }

    static func defaultColor(for kind: HomeControl.Kind, accent: Color) -> Color {
        switch kind {
        case .light: ControlTheme.amber
        case .switchOrOutlet: accent
        case .fan, .airPurifier, .airQuality: ControlTheme.air
        case .lock, .garage, .securitySystem: ControlTheme.secure
        case .thermostat, .heaterCooler: ControlTheme.warm
        case .shade, .door, .window: ControlTheme.shades
        case .smoke, .carbonMonoxide, .leak: ControlTheme.alarm
        case .humidifier, .valve, .faucet, .temperature, .humidity: ControlTheme.water
        case .button, .contact, .motion, .occupancy, .lightLevel: Color(hex: 0x8E8E93)
        }
    }
}

// MARK: - Surfaces

/// Glass behind a card, so the scene's glow shows through.
struct ControlCard: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
    }
}

extension View {
    func controlCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(ControlCard(cornerRadius: cornerRadius))
    }
}

/// The screen behind Control: grouped gray, with the running scene's color glowing down from
/// the top.
struct ControlBackdrop: View {
    var glow: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            if let glow {
                RadialGradient(colors: [glow.opacity(scheme == .dark ? 0.42 : 0.22), glow.opacity(0)],
                               center: UnitPoint(x: 0.5, y: -0.05), startRadius: 0, endRadius: 560)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.6), value: glow)
    }
}

/// A tile's background in its style: glass when off; a wash, a fill or a glow of its color
/// when on; a photo the family took, darkened so the words read. Lights fill from the bottom
/// as bright as they are.
struct TileSurface: ViewModifier {
    var on: Bool
    var look: DeviceLook
    /// 0–1: how much of a light's tile is filled.
    var level: Double?
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background { background }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: on ? 1 : 0.5)
            }
            .shadow(color: on && look.photo == nil ? look.color.opacity(look.tileStyle == .tinted ? 0.18 : 0.3) : .clear, radius: 14, y: 8)
            .animation(.smooth(duration: 0.3), value: on)
    }

    private var borderColor: Color {
        if look.photo != nil { return .white.opacity(0.15) }
        return on && look.tileStyle != .solid ? look.color.opacity(0.45) : Color.primary.opacity(0.07)
    }

    @ViewBuilder
    private var background: some View {
        if let photo = look.photo, let image = TilePhotos.image(photo) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .overlay {
                    LinearGradient(colors: [.black.opacity(on ? 0.05 : 0.35), .black.opacity(on ? 0.55 : 0.75)], startPoint: .top, endPoint: .bottom)
                }
                .saturation(on ? 1 : 0.4)
        } else if on {
            ZStack(alignment: .bottom) {
                switch look.tileStyle {
                case .solid:
                    look.color
                case .glow:
                    Rectangle().fill(.thinMaterial)
                    RadialGradient(colors: [look.color.opacity(0.42), look.color.opacity(0)], center: .topLeading, startRadius: 0, endRadius: 220)
                case .tinted:
                    Rectangle().fill(.thinMaterial)
                    look.color.opacity(0.14)
                }
                if let level, look.tileStyle != .solid {
                    GeometryReader { proxy in
                        LinearGradient(colors: [look.color.opacity(0.36), look.color.opacity(0.08)], startPoint: .bottom, endPoint: .top)
                            .frame(height: proxy.size.height * min(max(level, 0), 1))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .animation(.smooth(duration: 0.35), value: level)
                }
            }
        } else {
            Rectangle().fill(.thinMaterial)
        }
    }
}

extension View {
    func tileSurface(on: Bool, look: DeviceLook, level: Double? = nil, cornerRadius: CGFloat = 24) -> some View {
        modifier(TileSurface(on: on, look: look, level: level, cornerRadius: cornerRadius))
    }
}

/// The round icon on a tile: quiet when off, in the device's color when on, glowing in Glow.
struct DeviceIcon: View {
    var symbol: String
    var on: Bool
    var look: DeviceLook
    var size: CGFloat = 40

    var body: some View {
        let onFill = look.tileStyle == .solid || look.photo != nil
        let foreground: Color = {
            guard on else { return look.photo != nil ? .white : .secondary }
            if onFill { return look.tileStyle == .solid && look.color.prefersDarkText ? .black.opacity(0.75) : .white }
            if look.tileStyle == .glow { return look.color.prefersDarkText ? .black.opacity(0.75) : .white }
            return look.color
        }()
        let fill: Color = {
            guard on else { return look.photo != nil ? .white.opacity(0.18) : Color.primary.opacity(0.08) }
            if onFill { return look.tileStyle == .solid && look.color.prefersDarkText ? .black.opacity(0.1) : .white.opacity(0.25) }
            if look.tileStyle == .glow { return look.color }
            return look.color.opacity(0.2)
        }()
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .shadow(color: on && (look.tileStyle == .glow || look.color == ControlTheme.amber) && !onFill ? look.color.opacity(0.7) : .clear, radius: 11)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// Words on a tile: white over a photo or a solid color, else the usual.
struct TileText {
    var primary: Color
    var secondary: Color

    init(on: Bool, look: DeviceLook) {
        if look.photo != nil {
            primary = .white
            secondary = .white.opacity(0.8)
        } else if on && look.tileStyle == .solid {
            let dark = look.color.prefersDarkText
            primary = dark ? .black : .white
            secondary = dark ? .black.opacity(0.65) : .white.opacity(0.8)
        } else {
            primary = .primary
            secondary = .secondary
        }
    }
}

/// Decoded tile photos, so a redraw doesn't decode the JPEG again.
enum TilePhotos {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        return cache
    }()

    static func image(_ data: Data) -> UIImage? {
        let key = "\(data.count)-\(data.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
