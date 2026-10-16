import HomeKit
import SwiftUI

/// One thing to control (or watch) in Apple Home: a light, plug, lock, thermostat, purifier,
/// valve, alarm or sensor. Read fresh from HomeKit each time the view draws.
struct HomeControl: Identifiable {
    enum Kind: String, CaseIterable {
        case light, switchOrOutlet, fan, lock, garage, thermostat, shade, door, window
        case securitySystem, smoke, carbonMonoxide, leak
        case airPurifier, humidifier, heaterCooler, airQuality
        case valve, faucet
        case button
        case temperature, humidity, contact, motion, occupancy, lightLevel
    }

    let id: UUID
    let accessoryID: UUID
    let name: String
    let room: UUID?
    let roomName: String
    let kind: Kind
    let reachable: Bool
    let accessory: HMAccessory
    let service: HMService

    /// Sensors, alarms and buttons: shown, never flipped.
    var isSensor: Bool { kind.isReadOnly }
    var section: ControlSection { kind.section }
    /// What a style is matched on when HomeKit IDs differ between family members' devices.
    var matchKey: String { DeviceMatch.key(name: name, room: roomName, kind: kind.rawValue) }
}

/// Where a kind of device sits on the Control screen.
enum ControlSection: String, CaseIterable {
    case lights, plugs, doors, climate, safety, air, water, sensors, buttons
}

extension HomeControl.Kind {
    var isReadOnly: Bool {
        switch self {
        case .smoke, .carbonMonoxide, .leak, .airQuality, .button,
             .temperature, .humidity, .contact, .motion, .occupancy, .lightLevel: true
        default: false
        }
    }

    /// Locks, garage doors and the alarm: opening them up asks first.
    var isSecurable: Bool {
        switch self {
        case .lock, .garage, .securitySystem: true
        default: false
        }
    }

    /// What a parent can hand to kids: lights, plugs, fans, shades, purifiers and
    /// humidifiers. Never locks, doors, windows, alarms, water, heat or sensors.
    var isKidSafe: Bool {
        switch self {
        case .light, .switchOrOutlet, .fan, .shade, .airPurifier, .humidifier: true
        default: false
        }
    }

    /// Opening up, or shutting the water off: asks first from a tile.
    var asksFirst: Bool {
        switch self {
        case .lock, .garage, .securitySystem, .door, .window, .valve: true
        default: false
        }
    }

    var section: ControlSection {
        switch self {
        case .light: .lights
        case .switchOrOutlet, .shade, .door, .window: .plugs
        case .lock, .garage: .doors
        case .thermostat: .climate
        case .securitySystem, .smoke, .carbonMonoxide, .leak: .safety
        case .fan, .airPurifier, .humidifier, .heaterCooler, .airQuality: .air
        case .valve, .faucet: .water
        case .button: .buttons
        case .temperature, .humidity, .contact, .motion, .occupancy, .lightLevel: .sensors
        }
    }

    /// The kind's own name, for Show As and accessibility.
    var label: String {
        switch self {
        case .light: "Light"
        case .switchOrOutlet: "Outlet"
        case .fan: "Fan"
        case .lock: "Lock"
        case .garage: "Garage Door"
        case .thermostat: "Thermostat"
        case .shade: "Shade"
        case .door: "Door"
        case .window: "Window"
        case .securitySystem: "Security System"
        case .smoke: "Smoke Alarm"
        case .carbonMonoxide: "Carbon Monoxide Alarm"
        case .leak: "Leak Sensor"
        case .airPurifier: "Air Purifier"
        case .humidifier: "Humidifier"
        case .heaterCooler: "Heater or Cooler"
        case .airQuality: "Air Quality"
        case .valve: "Valve"
        case .faucet: "Faucet"
        case .button: "Button"
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .contact: "Contact Sensor"
        case .motion: "Motion Sensor"
        case .occupancy: "Occupancy Sensor"
        case .lightLevel: "Light Sensor"
        }
    }
}

/// The plain-text key a device style falls back on: name, room and kind.
nonisolated enum DeviceMatch {
    static func key(name: String, room: String, kind: String) -> String {
        [name, room, kind]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }
}

/// A room's controls, in the order Apple Home lists rooms.
struct HomeRoomControls: Identifiable {
    let id: String
    let name: String
    let controls: [HomeControl]
}

/// A scene from Apple Home ("Good Morning", "Movie Night").
struct HomeScene: Identifiable {
    let id: UUID
    let name: String
    let symbol: String
    /// HMActionSetType: wake up, sleep, leave, arrive or the family's own.
    let type: String
    /// How many devices it changes.
    let deviceCount: Int
    let actionSet: HMActionSet
}

/// A battery-powered accessory's charge.
struct BatteryInfo {
    let level: Int?
    let low: Bool
    let charging: Bool
}

/// A filter that wears out (an air purifier's, an HVAC unit's).
struct FilterInfo {
    let serviceID: UUID
    let accessoryName: String
    let roomName: String
    /// 0–100, when the accessory reports it.
    let level: Double?
    let needsChange: Bool
}

/// An accessory Caloma can't control, so it opens the Home app.
struct OtherAccessory: Identifiable {
    let id: UUID
    let name: String
    let symbol: String
}

extension HomeBridge {
    var homeTitle: String? {
        _ = revision
        return home?.name
    }

    // MARK: Lists

    var scenes: [HomeScene] {
        _ = revision
        return (home?.actionSets ?? [])
            .filter { $0.actionSetType != HMActionSetTypeTriggerOwned && !$0.actions.isEmpty }
            .map { set in
                let symbol = switch set.actionSetType {
                case HMActionSetTypeWakeUp: "sun.max.fill"
                case HMActionSetTypeSleep: "moon.fill"
                case HMActionSetTypeHomeDeparture: "figure.walk.departure"
                case HMActionSetTypeHomeArrival: "figure.walk.arrival"
                default: "sparkles"
                }
                let devices = Set(set.actions.compactMap { action in
                    (action as? HMCharacteristicWriteAction<NSNumber>)?.characteristic.service?.accessory?.uniqueIdentifier
                })
                return HomeScene(id: set.uniqueIdentifier, name: set.name, symbol: symbol, type: set.actionSetType,
                                 deviceCount: devices.count, actionSet: set)
            }
    }

    /// Every room with something to control, then the rest of the home.
    var roomControls: [HomeRoomControls] {
        _ = revision
        guard let home else { return [] }
        let all = allControls
        var rooms: [HomeRoomControls] = []
        for room in home.rooms + [home.roomForEntireHome()] {
            let isEntireHome = room == home.roomForEntireHome()
            let here = all.filter { $0.room == room.uniqueIdentifier || (isEntireHome && $0.room == nil) }
            if !here.isEmpty {
                rooms.append(HomeRoomControls(id: room.uniqueIdentifier.uuidString, name: room.name, controls: here))
            }
        }
        return rooms
    }

    /// Every control in the home, in accessory order.
    var allControls: [HomeControl] {
        _ = revision
        guard let home else { return [] }
        return home.accessories.flatMap { accessory in
            accessory.services.compactMap { control(for: $0, of: accessory) }
        }
    }

    /// The scenes a control is part of ("Dinner", "Good Morning").
    func scenes(containing control: HomeControl) -> [HomeScene] {
        scenes.filter { scene in
            scene.actionSet.actions.contains { action in
                (action as? HMCharacteristicWriteAction<NSNumber>)?.characteristic.service == control.service
            }
        }
    }

    private func control(for service: HMService, of accessory: HMAccessory) -> HomeControl? {
        var kind: HomeControl.Kind? = switch service.serviceType {
        case HMServiceTypeLightbulb: .light
        case HMServiceTypeSwitch, HMServiceTypeOutlet: .switchOrOutlet
        case HMServiceTypeFan, HMServiceTypeVentilationFan: .fan
        case HMServiceTypeLockMechanism: .lock
        case HMServiceTypeGarageDoorOpener: .garage
        case HMServiceTypeThermostat: .thermostat
        case HMServiceTypeWindowCovering: .shade
        case HMServiceTypeDoor: .door
        case HMServiceTypeWindow: .window
        case HMServiceTypeSecuritySystem: .securitySystem
        case HMServiceTypeSmokeSensor: .smoke
        case HMServiceTypeCarbonMonoxideSensor: .carbonMonoxide
        case HMServiceTypeLeakSensor: .leak
        case HMServiceTypeAirPurifier: .airPurifier
        case HMServiceTypeHumidifierDehumidifier: .humidifier
        case HMServiceTypeHeaterCooler: .heaterCooler
        case HMServiceTypeAirQualitySensor: .airQuality
        case HMServiceTypeValve: .valve
        case HMServiceTypeFaucet: .faucet
        case HMServiceTypeStatelessProgrammableSwitch: .button
        case HMServiceTypeTemperatureSensor: .temperature
        case HMServiceTypeHumiditySensor: .humidity
        case HMServiceTypeContactSensor: .contact
        case HMServiceTypeMotionSensor: .motion
        case HMServiceTypeOccupancySensor: .occupancy
        case HMServiceTypeLightSensor: .lightLevel
        default: nil
        }
        // Show As: a plug or switch the family marked as a light or a fan.
        if kind == .switchOrOutlet {
            switch service.associatedServiceType {
            case HMServiceTypeLightbulb?: kind = .light
            case HMServiceTypeFan?, HMServiceTypeVentilationFan?: kind = .fan
            default: break
            }
        }
        guard let kind else { return nil }
        // Cameras' own motion sensors are covered by the camera tiles.
        if kind == .motion && !(accessory.cameraProfiles ?? []).isEmpty { return nil }
        let name = service.name.isEmpty ? accessory.name : service.name
        return HomeControl(id: service.uniqueIdentifier, accessoryID: accessory.uniqueIdentifier, name: name,
                           room: accessory.room?.uniqueIdentifier, roomName: accessory.room?.name ?? "",
                           kind: kind, reachable: accessory.isReachable, accessory: accessory, service: service)
    }

    /// Accessories with a battery, lowest charge first.
    var batteries: [(accessory: HMAccessory, info: BatteryInfo)] {
        _ = revision
        return (home?.accessories ?? []).compactMap { accessory in
            battery(of: accessory).map { (accessory: accessory, info: $0) }
        }
        .sorted { ($0.info.level ?? 101) < ($1.info.level ?? 101) }
    }

    func battery(of accessory: HMAccessory) -> BatteryInfo? {
        _ = revision
        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeBattery }) else { return nil }
        let level = hkInt(service, HMCharacteristicTypeBatteryLevel)
        let low = hkInt(service, HMCharacteristicTypeStatusLowBattery) == 1
        let charging = hkInt(service, HMCharacteristicTypeChargingState) == 1
        return BatteryInfo(level: level, low: low || (level ?? 100) <= 20, charging: charging)
    }

    /// Every filter in the home that reports its life.
    var filters: [FilterInfo] {
        _ = revision
        return (home?.accessories ?? []).flatMap { accessory in
            accessory.services.filter { $0.serviceType == HMServiceTypeFilterMaintenance }.map { service in
                FilterInfo(serviceID: service.uniqueIdentifier, accessoryName: accessory.name,
                           roomName: accessory.room?.name ?? "",
                           level: hkDouble(service, HMCharacteristicTypeFilterLifeLevel),
                           needsChange: hkInt(service, HMCharacteristicTypeFilterChangeIndication) == 1)
            }
        }
    }

    /// Accessories with nothing Caloma can control (TVs, speakers, robot vacuums), except
    /// cameras, bridges and the hub itself.
    var otherAccessories: [OtherAccessory] {
        _ = revision
        let handled = Set(allControls.map(\.accessoryID))
        let plumbing: Set<String> = [HMServiceTypeAccessoryInformation, HMServiceTypeBattery, HMServiceTypeFilterMaintenance, HMServiceTypeLabel]
        return (home?.accessories ?? [])
            .filter { accessory in
                !handled.contains(accessory.uniqueIdentifier)
                    && (accessory.cameraProfiles ?? []).isEmpty
                    && accessory.category.categoryType != HMAccessoryCategoryTypeBridge
                    && accessory.category.categoryType != HMAccessoryCategoryTypeRangeExtender
                    && accessory.services.contains { $0.isUserInteractive && !plumbing.contains($0.serviceType) }
            }
            .map { accessory in
                let symbol = switch accessory.category.categoryType {
                case HMAccessoryCategoryTypeTelevision, HMAccessoryCategoryTypeTelevisionSetTopBox, HMAccessoryCategoryTypeTelevisionStreamingStick: "tv"
                case HMAccessoryCategoryTypeSpeaker: "hifispeaker"
                case HMAccessoryCategoryTypeAirPort: "wifi.router"
                default: "square.grid.2x2"
                }
                return OtherAccessory(id: accessory.uniqueIdentifier, name: accessory.name, symbol: symbol)
            }
    }

    // MARK: Reading

    func isOn(_ control: HomeControl) -> Bool {
        _ = revision
        let service = control.service
        switch control.kind {
        case .light, .switchOrOutlet:
            return hkBool(service, HMCharacteristicTypePowerState) ?? false
        case .fan:
            return hkBool(service, HMCharacteristicTypePowerState) ?? ((hkInt(service, HMCharacteristicTypeActive) ?? 0) == 1)
        case .lock:
            return hkInt(service, HMCharacteristicTypeCurrentLockMechanismState) == 1
        case .garage:
            // "On" means closed and safe, like a lock.
            return hkInt(service, HMCharacteristicTypeCurrentDoorState) == 1
        case .securitySystem:
            // "On" means armed. Disarmed (3) and triggered (4) aren't secure.
            return (0...2).contains(hkInt(service, HMCharacteristicTypeCurrentSecuritySystemState) ?? 3)
        case .thermostat:
            return (hkInt(service, HMCharacteristicTypeCurrentHeatingCooling) ?? 0) != 0
        case .shade, .door, .window:
            return (hkInt(service, HMCharacteristicTypeCurrentPosition) ?? 0) > 0
        case .smoke:
            return hkInt(service, HMCharacteristicTypeSmokeDetected) == 1
        case .carbonMonoxide:
            return hkInt(service, HMCharacteristicTypeCarbonMonoxideDetected) == 1
        case .leak:
            return hkInt(service, HMCharacteristicTypeLeakDetected) == 1
        case .airPurifier, .humidifier, .heaterCooler, .valve, .faucet:
            return hkInt(service, HMCharacteristicTypeActive) == 1
        case .contact:
            return hkInt(service, HMCharacteristicTypeContactState) == 1
        case .motion:
            return hkBool(service, HMCharacteristicTypeMotionDetected) ?? false
        case .occupancy:
            return hkInt(service, HMCharacteristicTypeOccupancyDetected) == 1
        case .button:
            return false
        case .temperature, .humidity, .airQuality, .lightLevel:
            return true
        }
    }

    /// An alarm going off right now: smoke, carbon monoxide, water, or the security system.
    func isAlarming(_ control: HomeControl) -> Bool {
        switch control.kind {
        case .smoke, .carbonMonoxide, .leak: isOn(control)
        case .securitySystem: securityState(control) == 4
        default: false
        }
    }

    /// "On · 60%", "Locked", "Closing", "71° · heating to 70°".
    func state(_ control: HomeControl) -> String {
        _ = revision
        guard control.reachable else { return "No Response" }
        let service = control.service
        switch control.kind {
        case .light:
            guard isOn(control) else { return "Off" }
            if let level = hkInt(service, HMCharacteristicTypeBrightness) { return "\(level)%" }
            return "On"
        case .switchOrOutlet:
            return isOn(control) ? "On" : "Off"
        case .fan:
            guard isOn(control) else { return "Off" }
            if let speed = fanSpeed(control) { return "\(FanSpeed.nearest(to: speed).label) · \(Int(speed.rounded()))%" }
            return "On"
        case .lock:
            switch hkInt(service, HMCharacteristicTypeCurrentLockMechanismState) {
            case 0?: return "Unlocked"
            case 1?: return "Locked"
            case 2?: return "Jammed"
            default: return "Unknown"
            }
        case .garage:
            switch hkInt(service, HMCharacteristicTypeCurrentDoorState) {
            case 0?: return "Open"
            case 1?: return "Closed"
            case 2?: return "Opening"
            case 3?: return "Closing"
            case 4?: return "Stopped"
            default: return "Unknown"
            }
        case .securitySystem:
            return SecurityMode.stateLabel(securityState(control))
        case .thermostat:
            let now = hkDouble(service, HMCharacteristicTypeCurrentTemperature).map(Self.temperatureText) ?? "–"
            let target = hkDouble(service, HMCharacteristicTypeTargetTemperature).map(Self.temperatureText)
            switch hkInt(service, HMCharacteristicTypeTargetHeatingCooling) {
            case 0?: return "\(now) · off"
            case 1?: return target.map { "\(now) · heat to \($0)" } ?? now
            case 2?: return target.map { "\(now) · cool to \($0)" } ?? now
            default: return target.map { "\(now) · set to \($0)" } ?? now
            }
        case .shade, .door, .window:
            let position = hkInt(service, HMCharacteristicTypeCurrentPosition) ?? 0
            return position == 0 ? "Closed" : (position == 100 ? "Open" : "\(position)% open")
        case .smoke:
            return isOn(control) ? "Smoke detected" : "Clear"
        case .carbonMonoxide:
            return isOn(control) ? "CO detected" : "Clear"
        case .leak:
            return isOn(control) ? "Water found" : "Dry"
        case .airPurifier:
            guard isOn(control) else { return "Off" }
            let auto = hkInt(service, HMCharacteristicTypeTargetAirPurifierState) == 1
            if let speed = fanSpeed(control), !auto { return "On · \(Int(speed.rounded()))%" }
            return auto ? "Auto" : "On"
        case .humidifier:
            let room = hkDouble(service, HMCharacteristicTypeCurrentRelativeHumidity).map { "\(Int($0.rounded()))%" }
            guard isOn(control) else { return room.map { "Off · room at \($0)" } ?? "Off" }
            if let target = humidityTarget(control) { return "On · to \(Int(target.rounded()))%" }
            return "On"
        case .heaterCooler:
            let now = hkDouble(service, HMCharacteristicTypeCurrentTemperature).map(Self.temperatureText) ?? "–"
            guard isOn(control) else { return "\(now) · off" }
            switch hkInt(service, HMCharacteristicTypeCurrentHeaterCoolerState) {
            case 2?: return "\(now) · heating"
            case 3?: return "\(now) · cooling"
            default: return "\(now) · idle"
            }
        case .airQuality:
            return AirQuality.label(hkInt(service, HMCharacteristicTypeAirQuality))
        case .valve:
            let isOpen = isOn(control)
            if valveType(control) == 1 {
                guard isOpen else { return "Off" }
                if let left = valveRemaining(control), left > 0 { return "Running · \(Self.minutesText(left)) left" }
                return "Running"
            }
            return isOpen ? "Open · water on" : "Closed · water off"
        case .faucet:
            return isOn(control) ? "On" : "Off"
        case .button:
            return "Smart button"
        case .temperature:
            return hkDouble(service, HMCharacteristicTypeCurrentTemperature).map(Self.temperatureText) ?? "–"
        case .humidity:
            return hkDouble(service, HMCharacteristicTypeCurrentRelativeHumidity).map { "\(Int($0.rounded()))%" } ?? "–"
        case .contact:
            return isOn(control) ? "Open" : "Closed"
        case .motion:
            return isOn(control) ? "Motion" : "Clear"
        case .occupancy:
            return isOn(control) ? "Occupied" : "Empty"
        case .lightLevel:
            return hkDouble(service, HMCharacteristicTypeCurrentLightLevel).map { "\(Int($0.rounded())) lux" } ?? "–"
        }
    }

    nonisolated static func minutesText(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded(.up))) min"
    }

    func brightness(_ control: HomeControl) -> Double? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeBrightness).map(Double.init)
    }

    func targetTemperature(_ control: HomeControl) -> Double? {
        _ = revision
        return hkDouble(control.service, HMCharacteristicTypeTargetTemperature)
    }

    func currentTemperature(_ control: HomeControl) -> Double? {
        _ = revision
        return hkDouble(control.service, HMCharacteristicTypeCurrentTemperature)
    }

    /// The thermostat's range in Celsius, from its metadata (usually 10–38 °C).
    func temperatureRange(_ control: HomeControl) -> ClosedRange<Double> {
        let metadata = hkCharacteristic(control.service, HMCharacteristicTypeTargetTemperature)?.metadata
        let low = metadata?.minimumValue?.doubleValue ?? 10
        let high = metadata?.maximumValue?.doubleValue ?? 32
        return low < high ? low...high : 10...32
    }

    /// 0 off, 1 heat, 2 cool, 3 auto.
    func thermostatMode(_ control: HomeControl) -> Int? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeTargetHeatingCooling)
    }

    /// 0 off, 1 heating, 2 cooling.
    func thermostatActivity(_ control: HomeControl) -> Int? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeCurrentHeatingCooling)
    }

    func shadePosition(_ control: HomeControl) -> Double? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeTargetPosition).map(Double.init)
    }

    /// Rotation speed, 0–100, for fans and purifiers.
    func fanSpeed(_ control: HomeControl) -> Double? {
        _ = revision
        return hkDouble(control.service, HMCharacteristicTypeRotationSpeed)
    }

    /// Color temperature in mireds, when the light has one.
    func colorTemperature(_ control: HomeControl) -> Double? {
        _ = revision
        return hkDouble(control.service, HMCharacteristicTypeColorTemperature)
    }

    /// The light's warmest-to-coolest range in mireds.
    func colorTemperatureRange(_ control: HomeControl) -> ClosedRange<Double>? {
        guard let metadata = hkCharacteristic(control.service, HMCharacteristicTypeColorTemperature)?.metadata else { return nil }
        let low = metadata.minimumValue?.doubleValue ?? 140
        let high = metadata.maximumValue?.doubleValue ?? 500
        return low < high ? low...high : nil
    }

    /// The security system's current state: 0 home, 1 away, 2 night, 3 off, 4 alarm.
    func securityState(_ control: HomeControl) -> Int? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeCurrentSecuritySystemState)
    }

    /// 0 home, 1 away, 2 night, 3 off.
    func securityTarget(_ control: HomeControl) -> Int? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeTargetSecuritySystemState)
    }

    /// 0 generic (a main shutoff), 1 irrigation, 2 shower, 3 faucet.
    func valveType(_ control: HomeControl) -> Int? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeValveType)
    }

    func valveRemaining(_ control: HomeControl) -> Int? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeRemainingDuration)
    }

    func humidityTarget(_ control: HomeControl) -> Double? {
        _ = revision
        let mode = hkInt(control.service, HMCharacteristicTypeTargetHumidifierDehumidifierState)
        if mode == 2 { return hkDouble(control.service, HMCharacteristicTypeDehumidifierThreshold) }
        return hkDouble(control.service, HMCharacteristicTypeHumidifierThreshold)
            ?? hkDouble(control.service, HMCharacteristicTypeDehumidifierThreshold)
    }

    /// 0 auto, 1 heat, 2 cool.
    func heaterCoolerMode(_ control: HomeControl) -> Int? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeTargetHeaterCoolerState)
    }

    func heaterCoolerTarget(_ control: HomeControl) -> Double? {
        _ = revision
        if heaterCoolerMode(control) == 2 { return hkDouble(control.service, HMCharacteristicTypeCoolingThreshold) }
        return hkDouble(control.service, HMCharacteristicTypeHeatingThreshold)
            ?? hkDouble(control.service, HMCharacteristicTypeCoolingThreshold)
    }

    func airQuality(_ control: HomeControl) -> Int? {
        _ = revision
        return hkInt(control.service, HMCharacteristicTypeAirQuality)
    }

    /// What each press of a smart button does, from the family's Home automations:
    /// "Single press: Bedtime".
    func buttonActions(_ control: HomeControl) -> [String] {
        _ = revision
        guard let home else { return [] }
        let inputs = Set(control.service.characteristics.filter { $0.characteristicType == HMCharacteristicTypeInputEvent }.map(\.uniqueIdentifier))
        var lines: [(Int, String)] = []
        for case let trigger as HMEventTrigger in home.triggers where trigger.isEnabled {
            for event in trigger.events {
                guard let pressEvent = event as? HMCharacteristicEvent<NSNumber>,
                      inputs.contains(pressEvent.characteristic.uniqueIdentifier) else { continue }
                let press = pressEvent.triggerValue?.intValue ?? 0
                let what = trigger.actionSets.map(\.name).joined(separator: ", ")
                guard !what.isEmpty else { continue }
                let word = switch press {
                case 0: "Single press"
                case 1: "Double press"
                case 2: "Long press"
                default: "Press"
                }
                lines.append((press, "\(word): \(what)"))
            }
        }
        return lines.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Whether temperatures show in Fahrenheit: the same choice the formatter makes from the
    /// region and the person's Temperature setting, so steps, rounding and display agree.
    nonisolated static let usesFahrenheit: Bool = {
        Measurement(value: 100, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
            .contains("212")
    }()

    /// Celsius in, the person's own unit out: "70°" in Fahrenheit, "21.5°" in Celsius.
    nonisolated static func temperatureText(_ celsius: Double) -> String {
        let measurement = Measurement(value: celsius, unit: UnitTemperature.celsius)
        if usesFahrenheit {
            return measurement.converted(to: .fahrenheit)
                .formatted(.measurement(width: .narrow, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        return measurement.formatted(.measurement(width: .narrow, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// One step on the thermostat: 1° in Fahrenheit, half a degree in Celsius.
    nonisolated static var temperatureStep: Double {
        usesFahrenheit ? 5.0 / 9.0 : 0.5
    }

    // MARK: Changing

    /// Tap on a tile: lights, switches and fans flip; locks lock or unlock; garages open or
    /// close; shades, doors and windows open fully or close; purifiers, humidifiers, heaters,
    /// valves and faucets turn on or off.
    func toggle(_ control: HomeControl) async {
        let service = control.service
        switch control.kind {
        case .light, .switchOrOutlet:
            await hkWrite(service, HMCharacteristicTypePowerState, !isOn(control))
        case .fan:
            if hkCharacteristic(service, HMCharacteristicTypePowerState) != nil {
                await hkWrite(service, HMCharacteristicTypePowerState, !isOn(control))
            } else {
                await hkWrite(service, HMCharacteristicTypeActive, isOn(control) ? 0 : 1)
            }
        case .lock:
            await hkWrite(service, HMCharacteristicTypeTargetLockMechanismState, isOn(control) ? 0 : 1)
        case .garage:
            await hkWrite(service, HMCharacteristicTypeTargetDoorState, isOn(control) ? 0 : 1)
        case .shade, .door, .window:
            await hkWrite(service, HMCharacteristicTypeTargetPosition, isOn(control) ? 0 : 100)
        case .airPurifier, .humidifier, .heaterCooler, .valve, .faucet:
            await setActive(control, !isOn(control))
        default:
            break
        }
    }

    func setActive(_ control: HomeControl, _ active: Bool) async {
        await hkWrite(control.service, HMCharacteristicTypeActive, active ? 1 : 0)
    }

    func setBrightness(_ control: HomeControl, to level: Double) async {
        if level <= 0 {
            await hkWrite(control.service, HMCharacteristicTypePowerState, false)
            return
        }
        if !isOn(control) { await hkWrite(control.service, HMCharacteristicTypePowerState, true) }
        await hkWrite(control.service, HMCharacteristicTypeBrightness, Int(level.rounded()))
    }

    func setPower(_ control: HomeControl, _ on: Bool) async {
        await hkWrite(control.service, HMCharacteristicTypePowerState, on)
    }

    func setColorTemperature(_ control: HomeControl, mireds: Double) async {
        var value = mireds
        if let range = colorTemperatureRange(control) { value = min(max(value, range.lowerBound), range.upperBound) }
        if !isOn(control) { await hkWrite(control.service, HMCharacteristicTypePowerState, true) }
        await hkWrite(control.service, HMCharacteristicTypeColorTemperature, Int(value.rounded()))
    }

    /// Fan or purifier speed, 0–100. Zero turns it off.
    func setFanSpeed(_ control: HomeControl, to percent: Double) async {
        let service = control.service
        let on = percent > 0
        if hkCharacteristic(service, HMCharacteristicTypePowerState) != nil {
            await hkWrite(service, HMCharacteristicTypePowerState, on)
        } else if hkCharacteristic(service, HMCharacteristicTypeActive) != nil {
            await hkWrite(service, HMCharacteristicTypeActive, on ? 1 : 0)
        }
        if on {
            if control.kind == .airPurifier { await hkWrite(service, HMCharacteristicTypeTargetAirPurifierState, 0) }
            await hkWrite(service, HMCharacteristicTypeRotationSpeed, percent.rounded())
        }
    }

    func setPurifierAuto(_ control: HomeControl, _ auto: Bool) async {
        if !isOn(control) { await setActive(control, true) }
        await hkWrite(control.service, HMCharacteristicTypeTargetAirPurifierState, auto ? 1 : 0)
    }

    func setHumidityTarget(_ control: HomeControl, to percent: Double) async {
        let type = hkInt(control.service, HMCharacteristicTypeTargetHumidifierDehumidifierState) == 2
            ? HMCharacteristicTypeDehumidifierThreshold : HMCharacteristicTypeHumidifierThreshold
        if !isOn(control) { await setActive(control, true) }
        await hkWrite(control.service, type, percent.rounded())
    }

    /// 0 auto, 1 heat, 2 cool.
    func setHeaterCoolerMode(_ control: HomeControl, _ mode: Int) async {
        if !isOn(control) { await setActive(control, true) }
        await hkWrite(control.service, HMCharacteristicTypeTargetHeaterCoolerState, mode)
    }

    func setHeaterCoolerTarget(_ control: HomeControl, to celsius: Double) async {
        let type = heaterCoolerMode(control) == 2 ? HMCharacteristicTypeCoolingThreshold : HMCharacteristicTypeHeatingThreshold
        await hkWrite(control.service, type, (celsius * 2).rounded() / 2)
    }

    /// 0 off, 1 heat, 2 cool, 3 auto.
    func setThermostatMode(_ control: HomeControl, _ mode: Int) async {
        await hkWrite(control.service, HMCharacteristicTypeTargetHeatingCooling, mode)
    }

    func setTargetTemperature(_ control: HomeControl, to celsius: Double) async {
        let metadata = hkCharacteristic(control.service, HMCharacteristicTypeTargetTemperature)?.metadata
        let step = (metadata?.stepValue?.doubleValue).flatMap { $0 > 0 ? $0 : nil } ?? 0.1
        let snap = { (value: Double) in (value / step).rounded() * step }
        var value: Double
        if HomeBridge.usesFahrenheit {
            // A whole degree Fahrenheit, then the thermostat's own step (often 0.1 °C).
            value = snap(((celsius * 9 / 5 + 32).rounded() - 32) * 5 / 9)
        } else {
            value = snap((celsius * 2).rounded() / 2)
        }
        // A coarse step can snap straight back to where it was; go one step the way asked.
        if let current = targetTemperature(control), abs(value - current) < 0.001, abs(celsius - current) > 0.001 {
            value = current + (celsius > current ? step : -step)
        }
        // Stay inside what the thermostat accepts (usually 10–38 °C).
        if let metadata {
            if let low = metadata.minimumValue?.doubleValue { value = max(value, low) }
            if let high = metadata.maximumValue?.doubleValue { value = min(value, high) }
        }
        await hkWrite(control.service, HMCharacteristicTypeTargetTemperature, value)
    }

    /// Locks or unlocks, closes or opens a garage door, arms (Home) or disarms the alarm: an
    /// explicit direction rather than a flip, so a state that changed a moment ago can't turn
    /// "lock" into "unlock".
    func setSecured(_ control: HomeControl, _ secured: Bool) async {
        switch control.kind {
        case .lock:
            await hkWrite(control.service, HMCharacteristicTypeTargetLockMechanismState, secured ? 1 : 0)
        case .garage:
            await hkWrite(control.service, HMCharacteristicTypeTargetDoorState, secured ? 1 : 0)
        case .securitySystem:
            await hkWrite(control.service, HMCharacteristicTypeTargetSecuritySystemState, secured ? 0 : 3)
        default:
            break
        }
    }

    /// 0 home, 1 away, 2 night, 3 off.
    func setSecurityMode(_ control: HomeControl, _ mode: Int) async {
        await hkWrite(control.service, HMCharacteristicTypeTargetSecuritySystemState, mode)
    }

    func setShadePosition(_ control: HomeControl, to position: Double) async {
        await hkWrite(control.service, HMCharacteristicTypeTargetPosition, Int(position.rounded()))
    }

    /// Runs a sprinkler zone (or opens any valve) for a while, when the valve takes a duration.
    func runValve(_ control: HomeControl, seconds: Int?) async {
        if let seconds, hkCharacteristic(control.service, HMCharacteristicTypeSetDuration) != nil {
            await hkWrite(control.service, HMCharacteristicTypeSetDuration, seconds)
        }
        await setActive(control, true)
    }

    /// Closes every main shutoff and stops every sprinkler: the leak alert's one button.
    func shutOffWater() async {
        for control in allControls where control.kind == .valve || control.kind == .faucet {
            if isOn(control) || (control.kind == .valve && valveType(control) == 0) {
                await setActive(control, false)
            }
        }
    }

    func run(_ scene: HomeScene) async -> Bool {
        guard let home else { return false }
        do {
            try await home.executeActionSet(scene.actionSet)
            revision += 1
            return true
        } catch {
            return false
        }
    }

    // MARK: Characteristics

    func hkCharacteristic(_ service: HMService, _ type: String) -> HMCharacteristic? {
        service.characteristics.first { $0.characteristicType == type }
    }

    func hkBool(_ service: HMService, _ type: String) -> Bool? {
        (hkCharacteristic(service, type)?.value as? NSNumber)?.boolValue
    }

    func hkInt(_ service: HMService, _ type: String) -> Int? {
        (hkCharacteristic(service, type)?.value as? NSNumber)?.intValue
    }

    func hkDouble(_ service: HMService, _ type: String) -> Double? {
        (hkCharacteristic(service, type)?.value as? NSNumber)?.doubleValue
    }

    func hkWrite(_ service: HMService, _ type: String, _ value: Any) async {
        guard let target = hkCharacteristic(service, type) else { return }
        do {
            try await target.writeValue(value)
        } catch {
            // The tile shows the real state on the next update; nothing else to do.
        }
        revision += 1
    }

    /// Every characteristic type a tile, sheet or alert shows.
    static let shownCharacteristics: Set<String> = [
        HMCharacteristicTypePowerState, HMCharacteristicTypeBrightness, HMCharacteristicTypeActive,
        HMCharacteristicTypeColorTemperature, HMCharacteristicTypeRotationSpeed,
        HMCharacteristicTypeCurrentLockMechanismState, HMCharacteristicTypeCurrentDoorState,
        HMCharacteristicTypeCurrentTemperature, HMCharacteristicTypeTargetTemperature,
        HMCharacteristicTypeCurrentHeatingCooling, HMCharacteristicTypeTargetHeatingCooling,
        HMCharacteristicTypeCurrentPosition, HMCharacteristicTypeTargetPosition,
        HMCharacteristicTypeCurrentRelativeHumidity, HMCharacteristicTypeContactState, HMCharacteristicTypeMotionDetected,
        HMCharacteristicTypeCurrentSecuritySystemState, HMCharacteristicTypeTargetSecuritySystemState,
        HMCharacteristicTypeSmokeDetected, HMCharacteristicTypeCarbonMonoxideDetected, HMCharacteristicTypeLeakDetected,
        HMCharacteristicTypeCurrentAirPurifierState, HMCharacteristicTypeTargetAirPurifierState,
        HMCharacteristicTypeFilterLifeLevel, HMCharacteristicTypeFilterChangeIndication,
        HMCharacteristicTypeCurrentHumidifierDehumidifierState, HMCharacteristicTypeTargetHumidifierDehumidifierState,
        HMCharacteristicTypeHumidifierThreshold, HMCharacteristicTypeDehumidifierThreshold,
        HMCharacteristicTypeCurrentHeaterCoolerState, HMCharacteristicTypeTargetHeaterCoolerState,
        HMCharacteristicTypeHeatingThreshold, HMCharacteristicTypeCoolingThreshold,
        HMCharacteristicTypeAirQuality, HMCharacteristicTypeInUse, HMCharacteristicTypeValveType,
        HMCharacteristicTypeRemainingDuration, HMCharacteristicTypeOccupancyDetected, HMCharacteristicTypeCurrentLightLevel,
        HMCharacteristicTypeBatteryLevel, HMCharacteristicTypeStatusLowBattery, HMCharacteristicTypeChargingState,
    ]

    /// Reads the values the tiles show, then redraws once.
    func refreshControls() async {
        guard let home else { return }
        let shown = Self.shownCharacteristics
        let reads = home.accessories.filter(\.isReachable).flatMap(\.services).flatMap(\.characteristics).filter {
            shown.contains($0.characteristicType) && $0.properties.contains(HMCharacteristicPropertyReadable)
        }
        // All at once; a home has dozens of these.
        await withTaskGroup(of: Void.self) { group in
            for characteristic in reads {
                group.addTask { try? await characteristic.readValue() }
            }
        }
        revision += 1
    }
}

/// The four fan speeds on a fan's buttons, as percentages.
nonisolated enum FanSpeed: Int, CaseIterable, Identifiable {
    case off = 0, low = 33, medium = 66, high = 100

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Med"
        case .high: "High"
        }
    }

    /// The speed a percentage reads as: 1–33 low, 34–66 medium, above that high.
    static func nearest(to percent: Double) -> FanSpeed {
        switch percent {
        case ..<1: .off
        case ..<34: .low
        case ..<67: .medium
        default: .high
        }
    }
}

/// The security system's modes, in the order of its buttons.
nonisolated enum SecurityMode: Int, CaseIterable, Identifiable {
    case home = 0, away = 1, night = 2, off = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .home: "Home"
        case .away: "Away"
        case .night: "Night"
        case .off: "Off"
        }
    }

    static func stateLabel(_ state: Int?) -> String {
        switch state {
        case 0?: "Armed · Home"
        case 1?: "Armed · Away"
        case 2?: "Armed · Night"
        case 3?: "Disarmed"
        case 4?: "Alarm going off"
        default: "Unknown"
        }
    }
}

nonisolated enum AirQuality {
    static func label(_ value: Int?) -> String {
        switch value {
        case 1?: "Excellent"
        case 2?: "Good"
        case 3?: "Fair"
        case 4?: "Inferior"
        case 5?: "Poor"
        default: "Unknown"
        }
    }

    /// Fair or worse.
    static func isPoor(_ value: Int?) -> Bool { (value ?? 0) >= 3 }
}
