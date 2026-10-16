import HomeKit
import SwiftData
import SwiftUI

/// Control: the family's Apple Home in Caloma. The running scene's color glows behind it. At
/// the top, climate, lights and doors at a glance; then scenes, a room filter, and every
/// light, plug, shade, door, camera, alarm, air and water device, each in the family's own
/// icon and color. A tap flips a tile; touch and hold (or its slider button) for more, and to
/// rename it, move it or restyle it.
struct ControlView: View {
    @Environment(\.accent) private var accent
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var styles: [DeviceStyle]
    @AppStorage(SettingsKey.controlScene) private var activeSceneID = ""
    private let home = HomeBridge.shared

    @State private var room = Self.everything
    @State private var openCamera: HomeCamera?
    @State private var sheet: ControlSheet?
    @State private var ranScene: UUID?

    private static let everything = "all"

    /// Lets go of the scene glow when someone changes a device by hand.
    private var clearScene: ControlTouch {
        ControlTouch(id: "control") { activeSceneID = "" }
    }

    var body: some View {
        let book = StyleBook(styles)
        let scenes = home.scenes
        let active = scenes.first { $0.id.uuidString == activeSceneID }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if home.authorized == false {
                    EmptyCard(symbol: "house.slash", title: "Caloma can't see your home", message: "Allow Caloma to use your Home data in Settings › Privacy & Security › HomeKit.")
                } else if home.authorized == true && home.homeNames.isEmpty {
                    EmptyCard(symbol: "homekit", title: "No home set up yet", message: "Add your lights, locks and cameras in the Home app, and they'll show here.")
                } else {
                    content(book: book, scenes: scenes, active: active)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background {
            ControlBackdrop(glow: active.map { ControlTheme.color(for: $0, style: book.style(serviceID: $0.id.uuidString, matchKey: "")) })
        }
        .navigationTitle(home.homeTitle ?? "Control")
        .navigationBarTitleDisplayMode(.large)
        .environment(\.styleBook, book)
        .environment(\.controlTouched, clearScene)
        .toolbar {
            if home.homeNames.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Home", selection: Binding(get: { home.home?.uniqueIdentifier ?? home.homeNames[0].id }, set: { home.chooseHome($0) })) {
                            ForEach(home.homeNames) { Text($0.name).tag($0.id) }
                        }
                    } label: {
                        Label("Choose Home", systemImage: "house")
                    }
                }
            }
        }
        .task {
            // Values are read as soon as Apple Home hands over the homes.
            home.start()
        }
        .task(id: home.revision) {
            // A worn-out filter becomes a Home Care task, once things settle.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            FilterTasks.sync(home.filters, in: context)
        }
        .refreshable {
            await home.refreshControls()
            // Device names, icons and pins are family data in iCloud.
            await CloudSync.shared.syncNow()
        }
        .fullScreenCover(item: $openCamera) { camera in
            CameraFullScreen(camera: camera)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .light(let control):
                LightDetailView(control: control) { self.sheet = .edit(control) }
                    .environment(\.styleBook, book)
                    .environment(\.controlTouched, clearScene)
            case .adjust(let control):
                DeviceAdjustSheet(control: control) { self.sheet = .edit(control) }
                    .environment(\.controlTouched, clearScene)
                    .presentationDetents([.medium])
            case .edit(let control):
                EditDeviceView(control: control)
            }
        }
    }

    @ViewBuilder
    private func content(book: StyleBook, scenes: [HomeScene], active: HomeScene?) -> some View {
        let visible = home.allControls.filter { !(book.style(serviceID: $0.id.uuidString, matchKey: $0.matchKey)?.hidden ?? false) }
        let rooms = home.roomControls
        let inRoom: Set<UUID>? = room == Self.everything ? nil : Set(rooms.first { $0.id == room }?.controls.map(\.id) ?? [])
        // Devices Apple Home has but that aren't answering wait at the bottom, under Not
        // Responding, instead of showing controls that can't do anything.
        let working = visible.filter(\.reachable)
        let offline = visible.filter { !$0.reachable && (inRoom?.contains($0.id) ?? true) }
        let shown = working.filter { inRoom?.contains($0.id) ?? true }
        let alarming = working.filter { home.isAlarming($0) }
        let hasMainValve = working.contains { $0.kind == .valve && home.valveType($0) == 0 }

        ForEach(alarming) { control in
            AlarmBanner(control: control, canShutOffWater: hasMainValve)
        }

        StatusStrip(
            climate: working.first { $0.kind == .thermostat },
            lights: working.filter { $0.kind == .light },
            securables: working.filter { $0.kind == .lock || $0.kind == .garage || $0.kind == .securitySystem },
            onAllOff: allOff
        )

        if !scenes.isEmpty {
            scenesRow(scenes, book: book)
        }

        if rooms.count > 1 {
            roomChips(rooms, visible: visible)
        }

        let lights = shown.filter { $0.section == .lights }
        if !lights.isEmpty {
            DeviceGrid {
                ForEach(lights) { control in
                    DeviceTile(control: control, onAdjust: adjustAction(control), onEdit: { sheet = .edit(control) })
                }
            }
        }

        let plugs = shown.filter { $0.section == .plugs }
        if !plugs.isEmpty {
            DeviceGrid {
                ForEach(plugs) { control in
                    DeviceTile(control: control, onAdjust: adjustAction(control), onEdit: { sheet = .edit(control) })
                }
            }
        }

        // The status strip covers one thermostat; more, or a room's own, show here.
        let thermostats = shown.filter { $0.section == .climate }
        if thermostats.count > 1 || (room != Self.everything && !thermostats.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Climate")
                DeviceGrid {
                    ForEach(thermostats) { thermostat in
                        NavigationLink {
                            ClimateView(control: thermostat)
                                .environment(\.controlTouched, clearScene)
                        } label: {
                            ThermostatTile(control: thermostat)
                        }
                        .buttonStyle(KidPressStyle())
                        .contextMenu {
                            Button("Edit Name, Room & Icon", menuIcon: "pencil") { sheet = .edit(thermostat) }
                        }
                    }
                }
            }
        }

        let doors = shown.filter { $0.section == .doors }
        if !doors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Doors")
                DoorsCard(controls: doors) { sheet = .edit($0) }
            }
        }

        let cameras = home.cameras.filter { camera in
            room == Self.everything || rooms.first { $0.id == room }?.name == camera.room
        }
        if !cameras.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Cameras")
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(cameras) { camera in
                            Button {
                                openCamera = camera
                            } label: {
                                CameraSnapshotTile(camera: camera)
                            }
                            .buttonStyle(KidPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -16)
            }
        }

        let safety = shown.filter { $0.section == .safety }
        if !safety.isEmpty {
            SafetySection(controls: safety) { sheet = .edit($0) }
        }

        let air = shown.filter { $0.section == .air }
        let filters = room == Self.everything ? home.filters.filter { FilterTasks.needsTask(level: $0.level, needsChange: $0.needsChange) } : []
        if !air.isEmpty || !filters.isEmpty {
            AirSection(controls: air, filters: filters, onAdjust: { sheet = .adjust($0) }, onEdit: { sheet = .edit($0) })
        }

        let water = shown.filter { $0.section == .water }
        if !water.isEmpty {
            WaterSection(controls: water) { sheet = .edit($0) }
        }

        let sensors = shown.filter { $0.section == .sensors }
        if !sensors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Sensors")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    ForEach(sensors) { SensorChip(control: $0) }
                }
            }
        }

        if !offline.isEmpty {
            NotRespondingSection(controls: offline) { sheet = .edit($0) }
        }

        if room == Self.everything {
            let buttons = working.filter { $0.section == .buttons }
            if !buttons.isEmpty || !home.batteries.isEmpty {
                BatteriesSection(buttons: buttons)
            }
            let others = home.otherAccessories
            if !others.isEmpty {
                OtherAccessoriesSection(accessories: others)
            }
            // Hidden devices stay one tap from coming back.
            let hidden = home.allControls.filter { book.style(serviceID: $0.id.uuidString, matchKey: $0.matchKey)?.hidden ?? false }
            if !hidden.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(hidden) { control in
                            Button {
                                sheet = .edit(control)
                            } label: {
                                HStack {
                                    Text(control.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(control.roomName)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .font(.subheadline)
                                .padding(.vertical, 10)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } label: {
                    Text("Hidden (\(hidden.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .controlCard()
            }
        }

        if visible.isEmpty && scenes.isEmpty && home.cameras.isEmpty {
            EmptyCard(symbol: "lightswitch.off", title: "Nothing to control yet", message: "Lights, locks, thermostats and cameras you add in the Home app show here.")
        }
    }

    /// What the slider button opens: the light screen, or a sheet for the rest.
    private func adjustAction(_ control: HomeControl) -> (() -> Void)? {
        switch control.kind {
        case .light:
            guard home.brightness(control) != nil || home.colorTemperature(control) != nil else { return nil }
            return { sheet = .light(control) }
        case .shade, .door, .window, .fan, .airPurifier, .humidifier, .heaterCooler:
            return { sheet = .adjust(control) }
        default:
            return nil
        }
    }

    private func allOff() {
        activeSceneID = ""
        Task {
            for light in home.allControls where light.kind == .light && home.isOn(light) {
                await home.setPower(light, false)
            }
        }
    }

    // MARK: Scenes

    private func scenesRow(_ scenes: [HomeScene], book: StyleBook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Scenes")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(scenes) { scene in
                        let style = book.style(serviceID: scene.id.uuidString, matchKey: "")
                        ScenePill(scene: scene,
                                  color: ControlTheme.color(for: scene, style: style),
                                  symbol: style.map(\.symbol).flatMap { $0.isEmpty ? nil : $0 } ?? scene.symbol,
                                  isActive: activeSceneID == scene.id.uuidString,
                                  justRan: ranScene == scene.id) {
                            run(scene)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)
        }
    }

    private func run(_ scene: HomeScene) {
        Task {
            if await home.run(scene) {
                withAnimation(.smooth) {
                    activeSceneID = scene.id.uuidString
                    ranScene = scene.id
                }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.snappy) { if ranScene == scene.id { ranScene = nil } }
            }
        }
    }

    // MARK: Rooms

    private func roomChips(_ rooms: [HomeRoomControls], visible: [HomeControl]) -> some View {
        let visibleIDs = Set(visible.map(\.id))
        let lightsOn = { (controls: [HomeControl]) in
            controls.filter { visibleIDs.contains($0.id) && $0.kind == .light && home.isOn($0) }.count
        }
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                RoomChip(title: "Everything", count: lightsOn(visible), isOn: room == Self.everything) {
                    withAnimation(.snappy) { room = Self.everything }
                }
                ForEach(rooms) { item in
                    RoomChip(title: item.name, count: lightsOn(item.controls), isOn: room == item.id) {
                        withAnimation(.snappy) { room = item.id }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -16)
        .padding(.top, -10)
    }
}

/// Which sheet Control has up.
enum ControlSheet: Identifiable {
    case light(HomeControl)
    case adjust(HomeControl)
    case edit(HomeControl)

    var id: String {
        switch self {
        case .light(let control): "light-\(control.id)"
        case .adjust(let control): "adjust-\(control.id)"
        case .edit(let control): "edit-\(control.id)"
        }
    }
}

// MARK: - At a glance

/// Climate, lights and doors across the top: tap Climate for the thermostat, Lights to turn
/// every light off.
private struct StatusStrip: View {
    var climate: HomeControl?
    var lights: [HomeControl]
    var securables: [HomeControl]
    var onAllOff: () -> Void

    @Environment(\.controlTouched) private var touched
    private let home = HomeBridge.shared

    var body: some View {
        let onCount = lights.filter { home.isOn($0) }.count
        let unsecured = securables.filter { !home.isOn($0) }
        HStack(alignment: .top, spacing: 8) {
            if let climate {
                NavigationLink {
                    ClimateView(control: climate)
                        .environment(\.controlTouched, touched)
                } label: {
                    climateCell(climate)
                }
                .buttonStyle(KidPressStyle())
            }
            if !lights.isEmpty {
                Button(action: onAllOff) {
                    cell(title: "LIGHTS", symbol: "lightbulb.fill", tint: ControlTheme.amberText,
                         big: "\(onCount)", detail: onCount > 0 ? "Tap for all off" : "All off")
                }
                .buttonStyle(KidPressStyle())
                .disabled(onCount == 0)
                .accessibilityLabel("\(onCount) lights on")
                .accessibilityHint(onCount > 0 ? "Turns every light off" : "")
            }
            if !securables.isEmpty {
                cell(title: "DOORS", symbol: "shield.lefthalf.filled", tint: unsecured.isEmpty ? ControlTheme.secure : ControlTheme.attention,
                     big: unsecured.isEmpty ? "Secure" : "\(unsecured.count) open", detail: unsecured.isEmpty ? "All locked" : unsecured.map(\.name).joined(separator: ", "),
                     bigSize: unsecured.isEmpty ? 22 : 24)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private func climateCell(_ control: HomeControl) -> some View {
        let now = home.currentTemperature(control).map(HomeBridge.temperatureText) ?? "–"
        let target = home.targetTemperature(control).map(HomeBridge.temperatureText)
        let activity = switch home.thermostatActivity(control) {
        case 1?: "Heating"
        case 2?: "Cooling"
        default: "Idle"
        }
        return cell(title: "CLIMATE", symbol: "thermometer.medium", tint: ControlTheme.warm,
                    big: target ?? now, detail: "\(activity) · in \(now)")
    }

    private func cell(title: String, symbol: String, tint: Color, big: String, detail: String, bigSize: CGFloat = 32) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Text(big)
                .font(.system(size: bigSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minHeight: 36, alignment: .leading)
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCard()
    }
}

/// A scene: its icon on a wash of its color, filled with it while it's the one running.
private struct ScenePill: View {
    var scene: HomeScene
    var color: Color
    var symbol: String
    var isActive: Bool
    var justRan: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: justRan ? "checkmark" : symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isActive ? .white : color)
                    .frame(width: 42, height: 42)
                    .background(isActive ? Color.white.opacity(0.22) : color.opacity(0.2), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(scene.name)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(scene.deviceCount == 1 ? "1 device" : "\(scene.deviceCount) devices")
                        .font(.caption)
                        .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
                }
                .foregroundStyle(isActive ? Color.white : Color.primary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .frame(height: 58)
            .background {
                if isActive {
                    Capsule().fill(color)
                } else {
                    Capsule().fill(.thinMaterial)
                }
            }
            .overlay { Capsule().strokeBorder(Color.primary.opacity(isActive ? 0 : 0.07), lineWidth: 0.5) }
            .shadow(color: isActive ? color.opacity(0.45) : .clear, radius: 12, y: 6)
        }
        .buttonStyle(KidPressStyle())
        .sensoryFeedback(.success, trigger: justRan) { _, new in new }
        .accessibilityLabel(scene.name)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A room to filter by, with how many of its lights are on.
private struct RoomChip: View {
    var title: String
    var count: Int
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: 0x3A2500))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(ControlTheme.amber, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
            .background(isOn ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(title), \(count) lights on" : title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Adjust

/// Shade, door or window position; fan or purifier speed; humidity; or a heater's mode and
/// setting. Lights have their own screen.
struct DeviceAdjustSheet: View {
    var control: HomeControl
    var onEdit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlTouched) private var touched
    private let home = HomeBridge.shared
    @State private var value: Double = 0
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(home.state(control))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                switch control.kind {
                case .shade, .door, .window:
                    slider(range: 0...100, symbol: "arrow.up.and.down") { await home.setShadePosition(control, to: $0) }
                    big(value == 0 ? "Closed" : "\(Int(value))% open")
                case .fan:
                    fanSpeeds
                case .airPurifier:
                    purifier
                case .humidifier:
                    slider(range: 20...80, symbol: "humidity") { await home.setHumidityTarget(control, to: $0) }
                    big("\(Int(value))%")
                    Text("Target humidity").foregroundStyle(.secondary)
                case .heaterCooler:
                    heaterCooler
                default:
                    EmptyView()
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle(control.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            switch control.kind {
            case .shade, .door, .window: value = home.shadePosition(control) ?? 0
            case .fan, .airPurifier: value = home.isOn(control) ? (home.fanSpeed(control) ?? 100) : 0
            case .humidifier: value = home.humidityTarget(control) ?? 45
            case .heaterCooler: value = home.heaterCoolerTarget(control) ?? 21
            default: break
            }
        }
    }

    private func big(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 44, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    private var fanSpeeds: some View {
        let current = FanSpeed.nearest(to: value)
        return HStack(spacing: 8) {
            ForEach(FanSpeed.allCases) { speed in
                let on = speed == current
                Button {
                    withAnimation(.snappy) { value = Double(speed.rawValue) }
                    touched()
                    Task { await home.setFanSpeed(control, to: Double(speed.rawValue)) }
                } label: {
                    VStack(spacing: 6) {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(1...3, id: \.self) { bar in
                                RoundedRectangle(cornerRadius: 2)
                                    .frame(width: 4, height: CGFloat(4 + bar * 5))
                                    .opacity(speed.rawValue >= bar * 33 ? 1 : 0.25)
                            }
                        }
                        .frame(height: 20, alignment: .bottom)
                        Text(speed.label)
                            .font(.subheadline.weight(.bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? AnyShapeStyle(ControlTheme.air) : AnyShapeStyle(Color(.tertiarySystemFill)), in: .rect(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fan \(speed.label)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var purifier: some View {
        VStack(spacing: 18) {
            let auto = home.hkInt(control.service, HMCharacteristicTypeTargetAirPurifierState) == 1 && home.isOn(control)
            Picker("Mode", selection: Binding(get: { auto }, set: { newValue in
                touched()
                Task { await home.setPurifierAuto(control, newValue) }
            })) {
                Text("Auto").tag(true)
                Text("Manual").tag(false)
            }
            .pickerStyle(.segmented)
            if !auto {
                fanSpeeds
            }
        }
    }

    private var heaterCooler: some View {
        VStack(spacing: 18) {
            Picker("Mode", selection: Binding(get: { home.heaterCoolerMode(control) ?? 1 }, set: { mode in
                touched()
                Task {
                    await home.setHeaterCoolerMode(control, mode)
                    value = home.heaterCoolerTarget(control) ?? value
                }
            })) {
                Text("Heat").tag(1)
                Text("Cool").tag(2)
                Text("Auto").tag(0)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 28) {
                stepButton("minus") { value -= HomeBridge.temperatureStep }
                big(HomeBridge.temperatureText(value))
                    .frame(minWidth: 140)
                stepButton("plus") { value += HomeBridge.temperatureStep }
            }
        }
    }

    private func stepButton(_ symbol: String, change: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { change() }
            let target = value
            touched()
            Task { await home.setHeaterCoolerTarget(control, to: target) }
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 60, height: 60)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Warmer" : "Cooler")
    }

    private func slider(range: ClosedRange<Double>, symbol: String, apply: @escaping (Double) async -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Slider(value: $value, in: range, step: 1, onEditingChanged: { editing in
                guard !editing else { return }
                let level = value
                touched()
                Task { await apply(level) }
            })
        }
        .padding(.horizontal, 8)
    }
}

/// A thermostat as a tile: its reading, opening the climate screen.
private struct ThermostatTile: View {
    var control: HomeControl

    @Environment(\.styleBook) private var book
    @Environment(\.accent) private var accent
    private let home = HomeBridge.shared

    var body: some View {
        let on = home.thermostatActivity(control).map { $0 != 0 } ?? false
        let look = DeviceLook(control: control, style: book.style(serviceID: control.id.uuidString, matchKey: control.matchKey), accent: accent)
        let text = TileText(on: on, look: look)
        VStack(alignment: .leading, spacing: 8) {
            DeviceIcon(symbol: look.symbol(on), on: on, look: look)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(control.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(text.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(home.state(control))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(text.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 124)
        .tileSurface(on: on, look: look)
        .opacity(control.reachable ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}
