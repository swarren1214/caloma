import HomeKit
import SwiftUI

/// The thermostat, big: a dial with the target and a dot for where the house is now, a degree
/// at a time with minus and plus, Heat, Cool, Auto and Off, and every room's temperature.
struct ClimateView: View {
    var control: HomeControl

    @Environment(\.controlTouched) private var touched
    private let home = HomeBridge.shared
    /// Where the target is being set to, before it's sent.
    @State private var pendingTarget: Double?

    private struct Mode {
        let value: Int
        let name: String
        let color: Color
    }

    private static let modes: [Mode] = [
        Mode(value: 1, name: "Heat", color: Color(hex: 0xFF6A1A)),
        Mode(value: 2, name: "Cool", color: Color(hex: 0x0A84FF)),
        Mode(value: 3, name: "Auto", color: Color(hex: 0x1E9E6A)),
        Mode(value: 0, name: "Off", color: Color(hex: 0x8E8E93)),
    ]

    var body: some View {
        let range = home.temperatureRange(control)
        let target = pendingTarget ?? home.targetTemperature(control) ?? range.lowerBound
        let current = home.currentTemperature(control)
        let mode = home.thermostatMode(control) ?? 0
        let color = Self.modes.first { $0.value == mode }?.color ?? Color(hex: 0x8E8E93)
        ScrollView {
            VStack(spacing: 22) {
                dial(target: target, current: current, range: range, mode: mode, color: color)
                modePicker(mode: mode)
                rooms
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { ControlBackdrop(glow: mode == 0 ? nil : color) }
        .navigationTitle(control.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: pendingTarget) {
            // Sent once the taps stop, so five quick taps are one change, not five.
            guard let value = pendingTarget else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            touched()
            await home.setTargetTemperature(control, to: value)
            if pendingTarget == value { pendingTarget = nil }
        }
    }

    // MARK: Dial

    private func dial(target: Double, current: Double?, range: ClosedRange<Double>, mode: Int, color: Color) -> some View {
        let size: CGFloat = 280
        let radius = Double(size / 2 - 14)
        let center = CGPoint(x: size / 2, y: size / 2)
        let fraction = DialMath.fraction(target, in: range)
        let knob = DialMath.point(fraction: fraction, radius: radius, center: center)
        let now = current.map { DialMath.point(fraction: DialMath.fraction($0, in: range), radius: radius, center: center) }
        let off = mode == 0
        let activity = switch home.thermostatActivity(control) {
        case 1?: "HEATING TO"
        case 2?: "COOLING TO"
        default: off ? "OFF" : "SET TO"
        }
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .trim(from: 0, to: DialMath.sweep)
                    .stroke(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: radius * 2, height: radius * 2)
                Circle()
                    .trim(from: 0, to: off ? 0 : DialMath.sweep * fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 22, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: radius * 2, height: radius * 2)
                    .animation(.smooth(duration: 0.35), value: fraction)
                if let now {
                    Circle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 8, height: 8)
                        .position(now)
                }
                if !off {
                    Circle()
                        .fill(.white)
                        .frame(width: 30, height: 30)
                        .overlay { Circle().strokeBorder(color, lineWidth: 4) }
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .position(knob)
                        .animation(.smooth(duration: 0.35), value: fraction)
                }
                VStack(spacing: 2) {
                    Text(activity)
                        .font(.caption.weight(.heavy))
                        .tracking(1)
                        .foregroundStyle(off ? Color.secondary : color)
                    Text(HomeBridge.temperatureText(target))
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: target))
                        .opacity(off ? 0.35 : 1)
                    Text("Inside now \(current.map(HomeBridge.temperatureText) ?? "–")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Target \(HomeBridge.temperatureText(target)), inside now \(current.map(HomeBridge.temperatureText) ?? "unknown")")
            .accessibilityAdjustableAction { direction in
                step(from: target, by: direction == .increment ? 1 : -1, range: range)
            }

            HStack(spacing: 96) {
                stepButton("minus", label: "Cooler", tint: Color(hex: 0x0A84FF)) { step(from: target, by: -1, range: range) }
                stepButton("plus", label: "Warmer", tint: Color(hex: 0xFF6A1A)) { step(from: target, by: 1, range: range) }
            }
            .padding(.top, -34)
            .disabled(off || !control.reachable)
        }
    }

    private func step(from target: Double, by direction: Double, range: ClosedRange<Double>) {
        let next = min(max(target + direction * HomeBridge.temperatureStep, range.lowerBound), range.upperBound)
        withAnimation(.snappy) { pendingTarget = next }
    }

    private func stepButton(_ symbol: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 60, height: 60)
                .controlCard(cornerRadius: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func modePicker(mode: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Self.modes, id: \.value) { item in
                let on = item.value == mode
                Button {
                    touched()
                    Task { await home.setThermostatMode(control, item.value) }
                } label: {
                    Text(item.name)
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? AnyShapeStyle(item.color) : AnyShapeStyle(Color.clear), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .controlCard(cornerRadius: 24)
        .disabled(!control.reachable)
    }

    // MARK: Rooms

    /// Every room with a temperature: its thermostat or sensor, and its humidity when known.
    private var rooms: some View {
        let readings = roomReadings()
        return Group {
            if !readings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Around the House")
                    VStack(spacing: 0) {
                        ForEach(Array(readings.enumerated()), id: \.element.room) { index, reading in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(reading.room)
                                        .font(.body.weight(.semibold))
                                    if let humidity = reading.humidity {
                                        Text("Humidity \(Int(humidity.rounded()))%")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(width: 72, height: 6)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(reading.temperature >= 18.5 ? Color(hex: 0xFF8A3D) : Color(hex: 0x0A84FF))
                                            .frame(width: 72 * DialMath.fraction(reading.temperature, in: 10...26), height: 6)
                                    }
                                    .accessibilityHidden(true)
                                Text(HomeBridge.temperatureText(reading.temperature))
                                    .font(.headline)
                                    .monospacedDigit()
                                    .frame(minWidth: 48, alignment: .trailing)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                            if index < readings.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .controlCard()
                }
            }
        }
    }

    private struct RoomReading {
        let room: String
        let temperature: Double
        let humidity: Double?
    }

    private func roomReadings() -> [RoomReading] {
        home.roomControls.compactMap { room in
            let temperature = room.controls.lazy.compactMap { control -> Double? in
                switch control.kind {
                case .thermostat, .temperature, .heaterCooler: home.currentTemperature(control)
                default: nil
                }
            }.first
            guard let temperature else { return nil }
            let humidity = room.controls.lazy.compactMap { control -> Double? in
                guard control.kind == .humidity || control.kind == .humidifier else { return nil }
                return home.hkDouble(control.service, HMCharacteristicTypeCurrentRelativeHumidity)
            }.first
            return RoomReading(room: room.name, temperature: temperature, humidity: humidity)
        }
    }
}

/// The climate dial's geometry: a 270° arc from the lower left, round to the lower right.
nonisolated enum DialMath {
    /// How much of the circle the arc covers.
    static let sweep = 0.75

    /// Where a value sits on the arc, 0–1, clamped to the range.
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    /// The point on the arc for a fraction, measured clockwise from 135° (screen coordinates,
    /// y down).
    static func point(fraction: Double, radius: Double, center: CGPoint) -> CGPoint {
        let angle = (135 + fraction * 270) * .pi / 180
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}
