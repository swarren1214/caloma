import SwiftData
import SwiftUI

/// The Home card on a parent's wall screen: locks, garage doors, the alarm and the thermostat from Apple
/// Home, all of them working. Locking up and closing the garage are one tap. Unlocking a door,
/// opening the garage or disarming the alarm takes the parent PIN (once per visit), because a face on the
/// wall is never proof enough to open the house. The thermostat steps a degree at a time and
/// sends the new setting once the taps stop.
struct KioskHomeControls: View {
    @Environment(KioskSession.self) private var session
    /// Devices the family hid in Control stay off the wall too.
    @Query private var styles: [DeviceStyle]

    /// Writes in flight, by control.
    @State private var busy: Set<UUID> = []
    /// The lock or garage waiting on the parent PIN to unlock or open.
    @State private var asking: HomeControl?
    /// Where the thermostat is being set to, before it's sent.
    @State private var pendingTarget: Double?

    private static let green = Color(hex: 0x1E9E6A)
    private static let teal = Color(hex: 0x30B0C7)

    private var bridge: HomeBridge { .shared }

    var body: some View {
        let book = StyleBook(styles)
        // Only devices that answer: the full sheet lists the rest under Not Responding.
        let all = bridge.roomControls.flatMap(\.controls).filter { $0.reachable && !(book.style(serviceID: $0.id.uuidString, matchKey: $0.matchKey)?.hidden ?? false) }
        let secure = all.filter { $0.kind == .lock } + all.filter { $0.kind == .garage } + all.filter { $0.kind == .securitySystem }
        let thermostat = all.first { $0.kind == .thermostat }
        VStack(spacing: 10) {
            if !secure.isEmpty {
                // Two across when there's room, one when the card is narrow (portrait).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                    ForEach(secure) { control in
                        secureTile(control)
                    }
                }
            }
            if let thermostat {
                thermostatRow(thermostat)
            }
        }
        .sheet(item: $asking) { control in
            pinSheet(control)
        }
    }

    // MARK: Locks and garage doors

    private func secureTile(_ control: HomeControl) -> some View {
        // Locked, closed, or an alarm that's armed or going off (so it reads "Disarm").
        let secured = control.kind == .securitySystem ? (bridge.securityState(control) ?? 3) != 3 : bridge.isOn(control)
        let state = control.reachable ? bridge.state(control) : "Not responding"
        let tint = secured ? Self.green : Brand.waiting
        let isLock = control.kind == .lock
        let isAlarm = control.kind == .securitySystem
        let action = isAlarm ? (secured ? "Disarm" : "Arm") : (isLock ? (secured ? "Unlock" : "Lock") : (secured ? "Open" : "Close"))
        let needsPIN = secured && !session.isUnlocked
        let working = busy.contains(control.id)
        return Button {
            if secured && !session.isUnlocked {
                asking = control
            } else {
                set(control, secured: !secured)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if working {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        Image(systemName: isAlarm ? (secured ? "shield.lefthalf.filled" : "shield") : (isLock ? (secured ? "lock.fill" : "lock.open.fill") : (secured ? "door.garage.closed" : "door.garage.open")))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(control.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(state)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secured ? Color.secondary : Brand.waiting)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                if control.reachable {
                    HStack(spacing: 4) {
                        if needsPIN {
                            Image(systemName: "key.fill")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(action)
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(secured ? Color.primary : .white)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 30)
                    .background(secured ? AnyShapeStyle(Color(.secondarySystemFill)) : AnyShapeStyle(Brand.waiting), in: Capsule())
                }
            }
            .padding(10)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!control.reachable || working)
        .accessibilityLabel("\(control.name), \(state)")
        .accessibilityHint(needsPIN ? "\(action), asks for the parent PIN" : action)
    }

    private func set(_ control: HomeControl, secured: Bool) {
        busy.insert(control.id)
        Task {
            await bridge.setSecured(control, secured)
            busy.remove(control.id)
        }
    }

    private func pinSheet(_ control: HomeControl) -> some View {
        let verb = control.kind == .securitySystem ? "disarm" : (control.kind == .lock ? "unlock" : "open")
        return NavigationStack {
            VStack(spacing: 16) {
                if ParentPIN.isSet {
                    ParentPINPad(title: "Enter the parent PIN to \(verb) \(control.name)", tint: Brand.waiting) {
                        asking = nil
                        session.unlock()
                        set(control, secured: false)
                    }
                } else {
                    ContentUnavailableView(
                        "Set a Parent PIN First",
                        systemImage: "key.fill",
                        description: Text("Unlocking doors, opening the garage and turning off the alarm from the wall take the parent PIN. Set one in Family › Family Board.")
                    )
                }
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { asking = nil }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Thermostat

    private func thermostatRow(_ control: HomeControl) -> some View {
        let target = pendingTarget ?? bridge.targetTemperature(control)
        let state = control.reachable ? bridge.state(control) : "Not responding"
        let info = HStack(spacing: 10) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Self.teal)
                .frame(width: 34, height: 34)
                .background(Self.teal.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(control.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        let stepper = HStack(spacing: 10) {
            if control.reachable, let target {
                stepButton("minus", label: "Cooler") { step(from: target, by: -1) }
                Text(HomeBridge.temperatureText(target))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText(value: target))
                    .frame(minWidth: 56)
                    .accessibilityLabel("Set to \(HomeBridge.temperatureText(target))")
                stepButton("plus", label: "Warmer") { step(from: target, by: 1) }
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                info
                Spacer(minLength: 6)
                stepper
            }
            VStack(alignment: .leading, spacing: 8) {
                info
                stepper
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
        .task(id: pendingTarget) {
            // Sent once the taps stop, so five quick taps are one change, not five.
            guard let value = pendingTarget else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await bridge.setTargetTemperature(control, to: value)
            if pendingTarget == value { pendingTarget = nil }
        }
    }

    private func step(from target: Double, by direction: Double) {
        let next = min(max(target + direction * HomeBridge.temperatureStep, 10), 38)
        withAnimation(.snappy) { pendingTarget = next }
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 40, height: 40)
                .background(Color(.secondarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
