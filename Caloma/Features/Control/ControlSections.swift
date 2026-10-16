import HomeKit
import SwiftData
import SwiftUI

// The Control screen's newer sections: Safety (the security system and alarms), Air (fans,
// purifiers, humidifiers, heaters, air quality and filters), Water (the main valve, sprinkler
// zones and faucets), Buttons & Batteries, and accessories that open in Apple Home.

// MARK: - Safety

struct SafetySection: View {
    var controls: [HomeControl]
    var onEdit: (HomeControl) -> Void

    private let home = HomeBridge.shared

    var body: some View {
        let systems = controls.filter { $0.kind == .securitySystem }
        let alarms = controls.filter { $0.kind != .securitySystem }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Safety")
            ForEach(systems) { system in
                SecuritySystemCard(control: system)
                    .contextMenu {
                        Button("Edit Name, Room & Icon", systemImage: "pencil") { onEdit(system) }
                    }
            }
            if !alarms.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(alarms) { alarm in
                        AlarmTile(control: alarm)
                            .contextMenu {
                                Button("Edit Name, Room & Icon", systemImage: "pencil") { onEdit(alarm) }
                            }
                    }
                }
            }
        }
    }
}

/// The security system: its state, and Home, Away, Night and Off. Turning it off asks first.
struct SecuritySystemCard: View {
    var control: HomeControl

    @Environment(\.controlTouched) private var touched
    private let home = HomeBridge.shared
    @State private var confirmingOff = false
    @State private var sending: SecurityMode?

    var body: some View {
        let state = home.securityState(control)
        let target = home.securityTarget(control).flatMap(SecurityMode.init(rawValue:))
        let armed = home.isOn(control)
        let alarm = state == 4
        let tint = alarm ? ControlTheme.alarm : (armed ? ControlTheme.secure : ControlTheme.attention)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: armed || alarm ? "shield.lefthalf.filled" : "shield")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(control.name)
                        .font(.body.weight(.semibold))
                    Text(control.reachable ? home.state(control) : "No Response")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tint)
                }
                Spacer()
                if sending != nil { ProgressView() }
            }
            HStack(spacing: 4) {
                ForEach(SecurityMode.allCases) { mode in
                    let on = target == mode
                    Button {
                        if mode == .off && armed {
                            confirmingOff = true
                        } else {
                            set(mode)
                        }
                    } label: {
                        Text(mode.label)
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? AnyShapeStyle(mode == .off ? ControlTheme.attention : ControlTheme.secure) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 14, style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
            .disabled(!control.reachable || sending != nil)
        }
        .padding(14)
        .controlCard()
        .confirmationDialog("Turn off \(control.name)?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { set(.off) }
        }
    }

    private func set(_ mode: SecurityMode) {
        sending = mode
        touched()
        Task {
            await home.setSecurityMode(control, mode.rawValue)
            sending = nil
        }
    }
}

/// Smoke, carbon monoxide or leak: green and quiet when clear, red when it isn't.
struct AlarmTile: View {
    var control: HomeControl
    @Environment(\.styleBook) private var book
    @Environment(\.accent) private var accent
    private let home = HomeBridge.shared

    var body: some View {
        let alarming = home.isOn(control)
        let tint = !control.reachable ? Brand.late : (alarming ? ControlTheme.alarm : ControlTheme.secure)
        let look = DeviceLook(control: control, style: book.style(serviceID: control.id.uuidString, matchKey: control.matchKey), accent: accent)
        let state = home.state(control)
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: look.symbol(alarming))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(alarming ? .white : tint)
                .frame(width: 32, height: 32)
                .background(alarming ? tint : tint.opacity(0.18), in: Circle())
            Text(control.name)
                .font(.subheadline.weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(state)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .controlCard(cornerRadius: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(control.name), \(state)")
    }
}

// MARK: - Air

struct AirSection: View {
    var controls: [HomeControl]
    var filters: [FilterInfo]
    var onAdjust: (HomeControl) -> Void
    var onEdit: (HomeControl) -> Void

    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Air")
            if !controls.isEmpty {
                DeviceGrid {
                    ForEach(controls) { control in
                        DeviceTile(control: control, onAdjust: control.kind == .airQuality ? nil : { onAdjust(control) }, onEdit: { onEdit(control) })
                    }
                }
            }
            ForEach(filters, id: \.serviceID) { filter in
                Button {
                    router.tab = .homeCare
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ControlTheme.attention)
                            .frame(width: 36, height: 36)
                            .background(ControlTheme.attention.opacity(0.18), in: .rect(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(filter.level.map { "\(filter.accessoryName) filter at \(Int($0.rounded()))%" } ?? "\(filter.accessoryName) filter needs changing")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("In Home Care")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .controlCard(cornerRadius: 20)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Water

/// The main water valve, sprinkler zones and faucets, one row each.
struct WaterSection: View {
    var controls: [HomeControl]
    var onEdit: (HomeControl) -> Void

    @Environment(\.controlTouched) private var touched
    private let home = HomeBridge.shared
    @State private var busy: Set<UUID> = []

    /// How long Run sends a sprinkler zone.
    static let runSeconds = 10 * 60

    var body: some View {
        let mainsOff = controls.contains { $0.kind == .valve && home.valveType($0) == 0 && !home.isOn($0) }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Water")
            VStack(spacing: 0) {
                ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                    row(control, mainsOff: mainsOff)
                        .contextMenu {
                            Button("Edit Name, Room & Icon", systemImage: "pencil") { onEdit(control) }
                        }
                    if index < controls.count - 1 {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .controlCard()
        }
    }

    private func row(_ control: HomeControl, mainsOff: Bool) -> some View {
        let on = home.isOn(control)
        let isZone = control.kind == .valve && home.valveType(control) == 1
        let isMain = control.kind == .valve && home.valveType(control) == 0
        let blocked = isZone && mainsOff
        let tint: Color = isMain && !on ? ControlTheme.attention : ControlTheme.water
        let symbol = isZone ? "sprinkler.and.droplets" : (control.kind == .faucet ? "spigot.fill" : (isMain ? "pipe.and.drop" : "spigot"))
        let timed = home.hkCharacteristic(control.service, HMCharacteristicTypeSetDuration) != nil
        let action = isMain ? (on ? "Shut Off" : "Turn On") : (isZone ? (on ? "Stop" : (timed ? "Run 10 min" : "Run")) : (on ? "Off" : "On"))
        let state = blocked ? "Main water is off" : home.state(control)
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on && !isMain ? .white : tint)
                .frame(width: 38, height: 38)
                .background(on && !isMain ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.18)), in: .rect(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(control.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(state)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(blocked || (isMain && !on) ? ControlTheme.attention : (on ? tint : .secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if busy.contains(control.id) {
                ProgressView().frame(width: 76)
            } else if control.reachable {
                Button {
                    flip(control, on: on, isZone: isZone)
                } label: {
                    Text(action)
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(minWidth: 76, minHeight: 34)
                        .foregroundStyle(isMain && !on ? Color.white : Color.primary)
                        .background(isMain && !on ? AnyShapeStyle(ControlTheme.water) : AnyShapeStyle(Color.primary.opacity(0.09)), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(blocked)
                .opacity(blocked ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func flip(_ control: HomeControl, on: Bool, isZone: Bool) {
        busy.insert(control.id)
        touched()
        Task {
            if on {
                await home.setActive(control, false)
                // Closing the main valve stops the sprinklers too.
                if control.kind == .valve, home.valveType(control) == 0 {
                    for zone in controls where zone.kind == .valve && home.valveType(zone) == 1 && home.isOn(zone) {
                        await home.setActive(zone, false)
                    }
                }
            } else if isZone {
                await home.runValve(control, seconds: Self.runSeconds)
            } else {
                await home.setActive(control, true)
            }
            busy.remove(control.id)
        }
    }
}

// MARK: - Buttons & Batteries

/// Smart buttons and what each press does, then every battery, lowest first.
struct BatteriesSection: View {
    var buttons: [HomeControl]

    private let home = HomeBridge.shared

    var body: some View {
        let batteries = home.batteries
        let buttonAccessories = Set(buttons.map(\.accessoryID))
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Buttons & Batteries")
            VStack(spacing: 0) {
                ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                    let actions = home.buttonActions(button)
                    batteryRow(name: button.name,
                               detail: actions.isEmpty ? "No presses set up yet. Add them in the Home app." : actions.joined(separator: " · "),
                               symbol: "button.programmable",
                               info: home.battery(of: button.accessory))
                    if index < buttons.count - 1 || batteries.contains(where: { !buttonAccessories.contains($0.accessory.uniqueIdentifier) }) {
                        Divider().padding(.leading, 64)
                    }
                }
                let others = batteries.filter { !buttonAccessories.contains($0.accessory.uniqueIdentifier) }
                ForEach(Array(others.enumerated()), id: \.element.accessory.uniqueIdentifier) { index, item in
                    batteryRow(name: item.accessory.name,
                               detail: item.accessory.room?.name ?? "",
                               symbol: "battery.75percent",
                               info: item.info)
                    if index < others.count - 1 {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .controlCard()
        }
    }

    private func batteryRow(name: String, detail: String, symbol: String, info: BatteryInfo?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let info {
                BatteryGauge(info: info)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A small battery with its percentage, red when low.
struct BatteryGauge: View {
    var info: BatteryInfo

    var body: some View {
        let color: Color = info.low ? ControlTheme.alarm : ControlTheme.secure
        let level = Double(info.level ?? (info.low ? 10 : 100)) / 100
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(info.low ? color : Color.secondary, lineWidth: 1.5)
                    .frame(width: 26, height: 13)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, 20 * level), height: 7)
                    .padding(.leading, 3)
                if info.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 26)
                }
            }
            Text(info.level.map { "\($0)%" } ?? (info.low ? "Low" : "OK"))
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(info.low ? color : .secondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.level.map { "Battery \($0) percent\(info.low ? ", low" : "")" } ?? (info.low ? "Battery low" : "Battery OK"))
    }
}

// MARK: - Apple Home only

/// Accessories Caloma can't control (a TV, a speaker), as chips that open the Home app.
struct OtherAccessoriesSection: View {
    var accessories: [OtherAccessory]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Opens in Apple Home")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                ForEach(accessories) { accessory in
                    Button {
                        if let url = URL(string: "com.apple.home://") { openURL(url) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: accessory.symbol)
                                .font(.system(size: 14, weight: .semibold))
                            Text(accessory.name)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .controlCard(cornerRadius: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the Home app")
                }
            }
        }
    }
}

// MARK: - Filters in Home Care

/// A filter Apple Home says is wearing out becomes one Home Care task, never two.
enum FilterTasks {
    /// At 20% life or less, or when the accessory says to change it.
    nonisolated static func needsTask(level: Double?, needsChange: Bool) -> Bool {
        needsChange || (level.map { $0 <= 20 } ?? false)
    }

    /// Keyed by name and room rather than HomeKit's ID, so two parents' phones agree.
    nonisolated static func sourceKey(accessoryName: String, roomName: String) -> String {
        "filter:" + DeviceMatch.key(name: accessoryName, room: roomName, kind: "filter")
    }

    static func sync(_ filters: [FilterInfo], in context: ModelContext) {
        let due = filters.filter { needsTask(level: $0.level, needsChange: $0.needsChange) }
        guard !due.isEmpty else { return }
        let existing = Set(((try? context.fetch(FetchDescriptor<HomeTask>())) ?? []).map(\.sourceKey))
        var made = false
        for filter in due {
            let key = sourceKey(accessoryName: filter.accessoryName, roomName: filter.roomName)
            guard !existing.contains(key) else { continue }
            let soon = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
            let task = HomeTask(name: "Replace \(filter.accessoryName) filter", symbol: "air.purifier", area: .heatingAir,
                                intervalCount: 6, unit: .months, nextDue: soon, location: filter.roomName,
                                details: filter.level.map { "Apple Home says the filter is at \(Int($0.rounded()))%." } ?? "Apple Home says the filter needs changing.")
            task.sourceKey = key
            context.insert(task)
            made = true
        }
        if made { try? context.save() }
    }
}
