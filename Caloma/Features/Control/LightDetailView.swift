import HomeKit
import SwiftUI

/// One light, big: drag the pill up and down for brightness, pick a warmth from candle to
/// daylight, turn it on or off. The screen glows as bright and as warm as the light.
struct LightDetailView: View {
    var control: HomeControl
    var onEdit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlTouched) private var touched
    @Environment(\.colorScheme) private var scheme
    private let home = HomeBridge.shared

    /// 0–100; 0 is off.
    @State private var level: Double = 0
    @State private var lastOn: Double = 100
    @State private var dragStart: Double?
    @State private var mireds: Double?
    @State private var loaded = false

    private static let pillHeight: CGFloat = 340

    var body: some View {
        let hasBrightness = home.brightness(control) != nil
        let range = home.colorTemperatureRange(control)
        let tone = Warmth.nearest(toMireds: mireds).color
        let scenes = home.scenes(containing: control).map(\.name)
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 4) {
                        Text(level > 0 ? "\(Int(level.rounded()))%" : "Off")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: level))
                        if range != nil {
                            let warmth = Warmth.nearest(toMireds: mireds)
                            Text("\(warmth.name) · \(Int(warmth.kelvin)) K")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)

                    if hasBrightness {
                        pill(tone: tone)
                    }

                    if let range {
                        warmthRow(range: range)
                    }

                    HStack(spacing: 10) {
                        Button(action: power) {
                            Label(level > 0 ? "Turn Off" : "Turn On", systemImage: "power")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .foregroundStyle(level > 0 ? Color(.systemBackground) : Color(hex: 0x3A2500))
                                .background(level > 0 ? AnyShapeStyle(Color.primary) : AnyShapeStyle(ControlTheme.amber), in: .rect(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        if !scenes.isEmpty {
                            Label("In \(scenes.formatted(.list(type: .and)))", systemImage: "sparkles")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                .controlCard(cornerRadius: 20)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background {
                ZStack {
                    Color(.systemGroupedBackground)
                    RadialGradient(colors: [tone.opacity(level > 0 ? (scheme == .dark ? 0.2 : 0.12) + level / 300 : 0), tone.opacity(0)],
                                   center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 420)
                        .animation(.smooth(duration: 0.4), value: level)
                }
                .ignoresSafeArea()
            }
            .navigationTitle(control.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            guard !loaded else { return }
            loaded = true
            level = home.isOn(control) ? (home.brightness(control) ?? 100) : 0
            if level > 0 { lastOn = level }
            mireds = home.colorTemperature(control)
        }
    }

    // MARK: Brightness

    private func pill(tone: Color) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(.thinMaterial)
            Rectangle()
                .fill(tone)
                .frame(height: Self.pillHeight * level / 100)
            Image(systemName: level > 0 ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(level > 8 ? Color(hex: 0x3A2500).opacity(0.75) : Color.secondary)
                .padding(.bottom, 22)
        }
        .frame(width: 144, height: Self.pillHeight)
        .clipShape(.rect(cornerRadius: 44, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: tone.opacity(level > 0 ? 0.25 + level / 400 : 0), radius: 34, y: 10)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStart ?? level
                    if dragStart == nil { dragStart = start }
                    level = min(max(start - Double(drag.translation.height / Self.pillHeight) * 100, 0), 100).rounded()
                }
                .onEnded { _ in
                    dragStart = nil
                    send()
                }
        )
        .animation(.interactiveSpring, value: level)
        .sensoryFeedback(.selection, trigger: Int(level / 10))
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue(level > 0 ? "\(Int(level)) percent" : "Off")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: level = min(level + 10, 100)
            case .decrement: level = max(level - 10, 0)
            @unknown default: break
            }
            send()
        }
    }

    private func send() {
        let value = level
        if value > 0 { lastOn = value }
        touched()
        Task { await home.setBrightness(control, to: value) }
    }

    private func power() {
        if level > 0 {
            lastOn = level
            withAnimation(.smooth) { level = 0 }
            touched()
            Task { await home.setPower(control, false) }
        } else {
            withAnimation(.smooth) { level = lastOn }
            touched()
            Task {
                await home.setPower(control, true)
                if home.brightness(control) != nil { await home.setBrightness(control, to: lastOn) }
            }
        }
    }

    // MARK: Warmth

    private func warmthRow(range: ClosedRange<Double>) -> some View {
        let current = Warmth.nearest(toMireds: mireds)
        return VStack(alignment: .leading, spacing: 12) {
            Text("WARMTH")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            HStack {
                ForEach(Warmth.presets.filter { range.contains($0.mireds) || abs($0.mireds - range.lowerBound) < 25 || abs($0.mireds - range.upperBound) < 25 }) { warmth in
                    let on = warmth.id == current.id
                    Button {
                        let value = min(max(warmth.mireds, range.lowerBound), range.upperBound)
                        withAnimation(.smooth) { mireds = value }
                        if level == 0 { level = lastOn }
                        touched()
                        Task { await home.setColorTemperature(control, mireds: value) }
                    } label: {
                        Circle()
                            .fill(warmth.color)
                            .frame(width: 48, height: 48)
                            .overlay { Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1) }
                            .padding(4)
                            .overlay { Circle().strokeBorder(on ? Color.primary : .clear, lineWidth: 2.5) }
                            .scaleEffect(on ? 1.04 : 1)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(warmth.name), \(Int(warmth.kelvin)) Kelvin")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(16)
        .controlCard()
    }
}

/// The warmth presets, candle to daylight.
nonisolated struct Warmth: Identifiable, Sendable {
    let name: String
    let kelvin: Double
    let hex: UInt32

    var id: String { name }
    var mireds: Double { Self.mireds(kelvin: kelvin) }
    var color: Color { Color(hex: hex) }

    static let presets: [Warmth] = [
        Warmth(name: "Candle", kelvin: 2200, hex: 0xFF9A3C),
        Warmth(name: "Warm", kelvin: 2700, hex: 0xFFB020),
        Warmth(name: "Soft", kelvin: 3000, hex: 0xFFD27A),
        Warmth(name: "Neutral", kelvin: 4000, hex: 0xFFEFD6),
        Warmth(name: "Daylight", kelvin: 5000, hex: 0xDCEBFF),
    ]

    /// HomeKit's color temperature is in mireds: a million over the Kelvin.
    static func mireds(kelvin: Double) -> Double { 1_000_000 / kelvin }
    static func kelvin(mireds: Double) -> Double { 1_000_000 / mireds }

    /// The preset closest to a light's color temperature; Warm when it doesn't say.
    static func nearest(toMireds mireds: Double?) -> Warmth {
        guard let mireds, mireds > 0 else { return presets[1] }
        let target = Self.kelvin(mireds: mireds)
        return presets.min { abs($0.kelvin - target) < abs($1.kelvin - target) } ?? presets[1]
    }
}
