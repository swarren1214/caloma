import HomeKit
import SwiftUI

/// One thing to control in Apple Home: a light, switch, lock, garage door, thermostat, shade or
/// sensor. Read fresh from HomeKit each time the view draws.
struct HomeControl: Identifiable {
    enum Kind {
        case light, switchOrOutlet, fan, lock, garage, thermostat, shade
        case temperature, humidity, contact, motion
    }

    let id: UUID
    let accessoryID: UUID
    let name: String
    let room: UUID?
    let kind: Kind
    let reachable: Bool
    fileprivate let service: HMService

    var isSensor: Bool {
        switch kind {
        case .temperature, .humidity, .contact, .motion: true
        default: false
        }
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
    fileprivate let actionSet: HMActionSet
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
                return HomeScene(id: set.uniqueIdentifier, name: set.name, symbol: symbol, actionSet: set)
            }
    }

    /// Every room with something to control, then the rest of the home.
    var roomControls: [HomeRoomControls] {
        _ = revision
        guard let home else { return [] }
        let all = home.accessories.flatMap { accessory in
            accessory.services.compactMap { control(for: $0, of: accessory) }
        }
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

    private func control(for service: HMService, of accessory: HMAccessory) -> HomeControl? {
        let kind: HomeControl.Kind? = switch service.serviceType {
        case HMServiceTypeLightbulb: .light
        case HMServiceTypeSwitch, HMServiceTypeOutlet: .switchOrOutlet
        case HMServiceTypeFan: .fan
        case HMServiceTypeLockMechanism: .lock
        case HMServiceTypeGarageDoorOpener: .garage
        case HMServiceTypeThermostat: .thermostat
        case HMServiceTypeWindowCovering: .shade
        case HMServiceTypeTemperatureSensor: .temperature
        case HMServiceTypeHumiditySensor: .humidity
        case HMServiceTypeContactSensor: .contact
        case HMServiceTypeMotionSensor: .motion
        default: nil
        }
        guard let kind else { return nil }
        // Cameras' own motion sensors are covered by the camera tiles.
        if kind == .motion && !(accessory.cameraProfiles ?? []).isEmpty { return nil }
        let name = service.name.isEmpty ? accessory.name : service.name
        return HomeControl(id: service.uniqueIdentifier, accessoryID: accessory.uniqueIdentifier, name: name,
                           room: accessory.room?.uniqueIdentifier, kind: kind, reachable: accessory.isReachable, service: service)
    }

    // MARK: Reading

    func isOn(_ control: HomeControl) -> Bool {
        _ = revision
        switch control.kind {
        case .light, .switchOrOutlet:
            return bool(control.service, HMCharacteristicTypePowerState) ?? false
        case .fan:
            return bool(control.service, HMCharacteristicTypePowerState) ?? ((int(control.service, HMCharacteristicTypeActive) ?? 0) == 1)
        case .lock:
            return int(control.service, HMCharacteristicTypeCurrentLockMechanismState) == 1
        case .garage:
            // "On" means closed and safe, like a lock.
            return int(control.service, HMCharacteristicTypeCurrentDoorState) == 1
        case .thermostat:
            return (int(control.service, HMCharacteristicTypeCurrentHeatingCooling) ?? 0) != 0
        case .shade:
            return (int(control.service, HMCharacteristicTypeCurrentPosition) ?? 0) > 0
        case .contact:
            return int(control.service, HMCharacteristicTypeContactState) == 1
        case .motion:
            return bool(control.service, HMCharacteristicTypeMotionDetected) ?? false
        case .temperature, .humidity:
            return true
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
            if let level = int(service, HMCharacteristicTypeBrightness) { return "\(level)%" }
            return "On"
        case .switchOrOutlet, .fan:
            return isOn(control) ? "On" : "Off"
        case .lock:
            switch int(service, HMCharacteristicTypeCurrentLockMechanismState) {
            case 0?: return "Unlocked"
            case 1?: return "Locked"
            case 2?: return "Jammed"
            default: return "Unknown"
            }
        case .garage:
            switch int(service, HMCharacteristicTypeCurrentDoorState) {
            case 0?: return "Open"
            case 1?: return "Closed"
            case 2?: return "Opening"
            case 3?: return "Closing"
            case 4?: return "Stopped"
            default: return "Unknown"
            }
        case .thermostat:
            let now = double(service, HMCharacteristicTypeCurrentTemperature).map(Self.temperatureText) ?? "–"
            let target = double(service, HMCharacteristicTypeTargetTemperature).map(Self.temperatureText)
            switch int(service, HMCharacteristicTypeTargetHeatingCooling) {
            case 0?: return "\(now) · off"
            case 1?: return target.map { "\(now) · heat to \($0)" } ?? now
            case 2?: return target.map { "\(now) · cool to \($0)" } ?? now
            default: return target.map { "\(now) · set to \($0)" } ?? now
            }
        case .shade:
            let position = int(service, HMCharacteristicTypeCurrentPosition) ?? 0
            return position == 0 ? "Closed" : (position == 100 ? "Open" : "\(position)% open")
        case .temperature:
            return double(service, HMCharacteristicTypeCurrentTemperature).map(Self.temperatureText) ?? "–"
        case .humidity:
            return double(service, HMCharacteristicTypeCurrentRelativeHumidity).map { "\(Int($0.rounded()))%" } ?? "–"
        case .contact:
            return isOn(control) ? "Open" : "Closed"
        case .motion:
            return isOn(control) ? "Motion" : "Clear"
        }
    }

    func brightness(_ control: HomeControl) -> Double? {
        _ = revision
        return int(control.service, HMCharacteristicTypeBrightness).map(Double.init)
    }

    func targetTemperature(_ control: HomeControl) -> Double? {
        _ = revision
        return double(control.service, HMCharacteristicTypeTargetTemperature)
    }

    func shadePosition(_ control: HomeControl) -> Double? {
        _ = revision
        return int(control.service, HMCharacteristicTypeTargetPosition).map(Double.init)
    }

    /// Celsius in, the person's own unit out: "70°" in the US.
    static func temperatureText(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// One step on the thermostat: 1° in Fahrenheit, half a degree in Celsius.
    static var temperatureStep: Double {
        Locale.current.measurementSystem == .us ? 5.0 / 9.0 : 0.5
    }

    // MARK: Changing

    /// Tap on a tile: lights, switches and fans flip; locks lock or unlock; garages open or
    /// close; shades open fully or close.
    func toggle(_ control: HomeControl) async {
        let service = control.service
        switch control.kind {
        case .light, .switchOrOutlet:
            await write(service, HMCharacteristicTypePowerState, !isOn(control))
        case .fan:
            if characteristic(service, HMCharacteristicTypePowerState) != nil {
                await write(service, HMCharacteristicTypePowerState, !isOn(control))
            } else {
                await write(service, HMCharacteristicTypeActive, isOn(control) ? 0 : 1)
            }
        case .lock:
            await write(service, HMCharacteristicTypeTargetLockMechanismState, isOn(control) ? 0 : 1)
        case .garage:
            await write(service, HMCharacteristicTypeTargetDoorState, isOn(control) ? 0 : 1)
        case .shade:
            await write(service, HMCharacteristicTypeTargetPosition, isOn(control) ? 0 : 100)
        default:
            break
        }
    }

    func setBrightness(_ control: HomeControl, to level: Double) async {
        if !isOn(control) { await write(control.service, HMCharacteristicTypePowerState, true) }
        await write(control.service, HMCharacteristicTypeBrightness, Int(level.rounded()))
    }

    func setTargetTemperature(_ control: HomeControl, to celsius: Double) async {
        var value = (celsius * 2).rounded() / 2
        // Stay inside what the thermostat accepts (usually 10–38 °C).
        if let metadata = characteristic(control.service, HMCharacteristicTypeTargetTemperature)?.metadata {
            if let low = metadata.minimumValue?.doubleValue { value = max(value, low) }
            if let high = metadata.maximumValue?.doubleValue { value = min(value, high) }
        }
        await write(control.service, HMCharacteristicTypeTargetTemperature, value)
    }

    func setShadePosition(_ control: HomeControl, to position: Double) async {
        await write(control.service, HMCharacteristicTypeTargetPosition, Int(position.rounded()))
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

    private func characteristic(_ service: HMService, _ type: String) -> HMCharacteristic? {
        service.characteristics.first { $0.characteristicType == type }
    }

    private func bool(_ service: HMService, _ type: String) -> Bool? {
        (characteristic(service, type)?.value as? NSNumber)?.boolValue
    }

    private func int(_ service: HMService, _ type: String) -> Int? {
        (characteristic(service, type)?.value as? NSNumber)?.intValue
    }

    private func double(_ service: HMService, _ type: String) -> Double? {
        (characteristic(service, type)?.value as? NSNumber)?.doubleValue
    }

    private func write(_ service: HMService, _ type: String, _ value: Any) async {
        guard let target = characteristic(service, type) else { return }
        do {
            try await target.writeValue(value)
        } catch {
            // The tile shows the real state on the next update; nothing else to do.
        }
        revision += 1
    }

    /// Reads the values the tiles show, then redraws once.
    func refreshControls() async {
        guard let home else { return }
        let shown: Set<String> = [
            HMCharacteristicTypePowerState, HMCharacteristicTypeBrightness, HMCharacteristicTypeActive,
            HMCharacteristicTypeCurrentLockMechanismState, HMCharacteristicTypeCurrentDoorState,
            HMCharacteristicTypeCurrentTemperature, HMCharacteristicTypeTargetTemperature,
            HMCharacteristicTypeCurrentHeatingCooling, HMCharacteristicTypeTargetHeatingCooling,
            HMCharacteristicTypeCurrentPosition, HMCharacteristicTypeTargetPosition,
            HMCharacteristicTypeCurrentRelativeHumidity, HMCharacteristicTypeContactState, HMCharacteristicTypeMotionDetected,
        ]
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
