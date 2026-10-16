import HomeKit
import SwiftUI

/// One device as a tile: its icon lit when it's on, its name and state, in the family's style.
/// A tap flips it; the slider button (or touch and hold) opens its controls, and touch and
/// hold also offers Edit.
struct DeviceTile: View {
    var control: HomeControl
    var onAdjust: (() -> Void)?
    var onEdit: () -> Void

    @Environment(\.styleBook) private var book
    @Environment(\.accent) private var accent
    @Environment(\.controlTouched) private var touched
    private let home = HomeBridge.shared
    @State private var busy = false
    @State private var confirming = false
    /// What the confirm dialog will do, fixed when it was asked.
    @State private var pendingOn: Bool?

    var body: some View {
        let on = home.isOn(control)
        let look = DeviceLook(control: control, style: book.style(serviceID: control.id.uuidString, matchKey: control.matchKey), accent: accent)
        let text = TileText(on: on, look: look)
        let level: Double? = control.kind == .light ? (on ? (home.brightness(control) ?? 100) / 100 : 0) : nil
        let state = home.state(control)
        Button(action: flip) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    DeviceIcon(symbol: look.symbol(on), on: on, look: look)
                    Spacer()
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 10)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(text.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(state)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(stateColor(on: on, look: look, text: text))
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 124)
            .tileSurface(on: on, look: look, level: level)
            .opacity(control.reachable ? 1 : 0.55)
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(KidPressStyle())
        .overlay(alignment: .topTrailing) {
            if let onAdjust, !busy, control.reachable {
                Button(action: onAdjust) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(text.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Adjust \(control.name)")
            }
        }
        .contextMenu {
            if let onAdjust {
                Button("Adjust", menuIcon: "slider.horizontal.3", action: onAdjust)
            }
            Button("Edit Name, Room & Icon", menuIcon: "pencil", action: onEdit)
        }
        .sensoryFeedback(.selection, trigger: on)
        // A lock, garage or alarm pinned somewhere asks before opening up, as in Doors.
        .alert(confirmTitle, isPresented: $confirming) {
            Button(confirmVerb) {
                if let target = pendingOn { send(target) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityLabel("\(control.name), \(state)")
        .accessibilityAddTraits(control.isSensor ? [] : .isButton)
        .accessibilityAction(named: "Edit", onEdit)
    }

    private func stateColor(on: Bool, look: DeviceLook, text: TileText) -> Color {
        if !control.reachable { return Brand.late }
        if home.isAlarming(control) { return ControlTheme.alarm }
        if on, control.kind == .light, look.photo == nil, look.tileStyle != .solid { return ControlTheme.amberText }
        return text.secondary
    }

    /// Locks and alarms are "on" when secure; opening them up asks. Doors and windows ask
    /// before opening, the water valve before shutting off.
    private func needsConfirm(target: Bool) -> Bool {
        switch control.kind {
        case .lock, .garage, .securitySystem: !target
        case .door, .window: target
        case .valve: !target
        default: false
        }
    }

    private var confirmTitle: String {
        switch control.kind {
        case .lock: "Unlock \(control.name)?"
        case .securitySystem: "Turn off \(control.name)?"
        case .valve: "Shut off \(control.name)?"
        default: "Open \(control.name)?"
        }
    }

    private var confirmVerb: String {
        switch control.kind {
        case .lock: "Unlock"
        case .securitySystem: "Turn Off"
        case .valve: "Shut Off"
        default: "Open"
        }
    }

    private func flip() {
        guard !control.isSensor, control.reachable, !busy else { return }
        let target = !home.isOn(control)
        if control.kind.asksFirst && needsConfirm(target: target) {
            pendingOn = target
            confirming = true
        } else {
            send(target)
        }
    }

    private func send(_ target: Bool) {
        busy = true
        touched()
        Task {
            switch control.kind {
            case .lock, .garage, .securitySystem:
                await home.setSecured(control, target)
            case .door, .window:
                await home.setShadePosition(control, to: target ? 100 : 0)
            case .valve, .faucet, .airPurifier, .humidifier, .heaterCooler:
                await home.setActive(control, target)
            default:
                if home.isOn(control) != target { await home.toggle(control) }
            }
            busy = false
        }
    }
}

/// The tile grid every section uses: two across on iPhone, more on iPad.
struct DeviceGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 150 : 180), spacing: 10)], spacing: 10) {
            content()
        }
    }
}

// MARK: - Doors

/// Locks and garage doors, one row each with its own button. Locking up and closing are one
/// tap; unlocking or opening asks first in an alert.
struct DoorsCard: View {
    var controls: [HomeControl]
    var onEdit: (HomeControl) -> Void

    @Environment(\.styleBook) private var book
    @Environment(\.accent) private var accent
    @Environment(\.controlTouched) private var touched
    private let home = HomeBridge.shared
    @State private var asking: UUID?
    @State private var busy: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                row(control)
                if index < controls.count - 1 {
                    Divider().padding(.leading, 64)
                }
            }
        }
        .controlCard()
        .alert(askingTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: controls.first(where: { $0.id == asking })) { control in
            Button(control.kind == .lock ? "Unlock" : "Open") {
                set(control, secured: false)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Unlocking or opening asks first.
    private var askingTitle: String {
        guard let control = controls.first(where: { $0.id == asking }) else { return "" }
        return control.kind == .lock ? "Unlock \(control.name)?" : "Open the \(control.name)?"
    }

    private func row(_ control: HomeControl) -> some View {
        let secured = home.isOn(control)
        let tint = secured ? ControlTheme.secure : ControlTheme.attention
        let isLock = control.kind == .lock
        let look = DeviceLook(control: control, style: book.style(serviceID: control.id.uuidString, matchKey: control.matchKey), accent: accent)
        let action = isLock ? (secured ? "Unlock" : "Lock") : (secured ? "Open" : "Close")
        let state = home.state(control)
        return HStack(spacing: 12) {
            Image(systemName: look.symbol(secured))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.18), in: .rect(cornerRadius: 12, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(control.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(state)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(control.reachable ? tint : Brand.late)
            }
            Spacer(minLength: 8)
            if busy.contains(control.id) {
                ProgressView()
                    .frame(width: 76)
            } else if control.reachable {
                Button {
                    if secured {
                        asking = asking == control.id ? nil : control.id
                    } else {
                        set(control, secured: true)
                    }
                } label: {
                    Text(action)
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(minWidth: 76, minHeight: 34)
                        .foregroundStyle(secured ? Color.primary : .white)
                        .background(secured ? AnyShapeStyle(Color.primary.opacity(0.09)) : AnyShapeStyle(ControlTheme.secure), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .contextMenu {
            Button("Edit Name, Room & Icon", menuIcon: "pencil") { onEdit(control) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit") { onEdit(control) }
    }

    private func set(_ control: HomeControl, secured: Bool) {
        busy.insert(control.id)
        touched()
        Task {
            await home.setSecured(control, secured)
            busy.remove(control.id)
        }
    }
}

// MARK: - Alarms

/// Smoke, carbon monoxide, water or the alarm going off, at the top of Control. A leak offers
/// to shut off the water when the home has a main valve.
struct AlarmBanner: View {
    var control: HomeControl
    var canShutOffWater: Bool

    private let home = HomeBridge.shared
    @State private var dismissed = false
    @State private var shutting = false
    @State private var shutOff = false
    @State private var appeared = false

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: DeviceLook.defaults(for: control.kind).on)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(ControlTheme.alarm, in: Circle())
                        .symbolEffect(.pulse, options: .repeat(.continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        Text("\(control.name)\(control.roomName.isEmpty ? "" : " · \(control.roomName)")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if shutOff {
                    Label("Main water is off. Turn it back on in Water, below.", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ControlTheme.secure)
                } else {
                    HStack(spacing: 8) {
                        if control.kind == .leak && canShutOffWater {
                            Button {
                                shutting = true
                                Task {
                                    await home.shutOffWater()
                                    shutting = false
                                    withAnimation(.snappy) { shutOff = true }
                                }
                            } label: {
                                Group {
                                    if shutting { ProgressView().tint(.white) } else { Text("Shut Off Water") }
                                }
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(.white)
                                .background(ControlTheme.alarm, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(shutting)
                        }
                        Button("Dismiss") {
                            withAnimation(.snappy) { dismissed = true }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Color.primary.opacity(0.09), in: Capsule())
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .background(ControlTheme.alarm.opacity(0.14), in: .rect(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(ControlTheme.alarm.opacity(0.5), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .sensoryFeedback(.warning, trigger: appeared) { _, new in new }
            .onAppear { appeared = true }
        }
    }

    private var title: String {
        switch control.kind {
        case .smoke: "Smoke detected"
        case .carbonMonoxide: "Carbon monoxide detected"
        case .leak: "Water where it shouldn't be"
        default: "The alarm is going off"
        }
    }
}

// MARK: - Sensors

/// A sensor as a small chip: a dot, its name and reading.
struct SensorChip: View {
    var control: HomeControl
    private let home = HomeBridge.shared

    var body: some View {
        let on = home.isOn(control)
        let dot: Color = switch control.kind {
        case .contact, .motion, .occupancy: on ? ControlTheme.attention : ControlTheme.secure
        case .temperature, .humidity: ControlTheme.water
        default: Color(hex: 0x8E8E93)
        }
        let state = home.state(control)
        HStack(spacing: 7) {
            Circle().fill(control.reachable ? dot : Brand.late).frame(width: 8, height: 8)
            Text(control.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(state)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .controlCard(cornerRadius: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(control.name), \(state)")
    }
}
