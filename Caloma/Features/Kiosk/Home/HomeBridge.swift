import AudioToolbox
import HomeKit
import SwiftUI

/// Something to show on the wall: a doorbell press, or motion on a camera the family chose.
struct DoorbellEvent: Identifiable, Equatable {
    let id = UUID()
    /// The doorbell or camera accessory.
    let accessoryID: UUID
    let name: String
    let byMotion: Bool
    let at = Date.now
}

/// A camera in Apple Home, for choosing which ones show on the wall.
struct HomeCamera: Identifiable, Hashable {
    let id: UUID
    let name: String
    let room: String
    let isDoorbell: Bool
}

/// One of the family's Apple Homes, for the picker.
struct HomeName: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// One line of the adult screen's Home card: the front door lock, the garage, the thermostat.
struct HomeStatusItem: Identifiable {
    let id: UUID
    let name: String
    let symbol: String
    let state: String
    let needsAttention: Bool
}

/// Caloma's view of the family's Apple Home: doorbells and their cameras for Kiosk Mode, plus
/// locks, garage doors and thermostats for the Home card. Only works with HomeKit accessories;
/// Ring and Nest doorbells need their own apps.
@Observable
final class HomeBridge: NSObject {
    static let shared = HomeBridge()

    /// nil until HomeKit answers.
    private(set) var authorized: Bool?
    private(set) var homeNames: [HomeName] = []
    /// Goes up when any value Caloma shows changes, so views redraw.
    private(set) var revision = 0

    /// Set by Kiosk Mode while it's showing.
    @ObservationIgnored var onDoorbell: ((DoorbellEvent) -> Void)?

    @ObservationIgnored private var manager: HMHomeManager?
    @ObservationIgnored private var lastMotion: [UUID: Date] = [:]

    func start() {
        guard manager == nil else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
    }

    // MARK: The home

    var home: HMHome? {
        guard let homes = manager?.homes, !homes.isEmpty else { return nil }
        let saved = UserDefaults.standard.string(forKey: SettingsKey.kioskHomeID).flatMap(UUID.init(uuidString:))
        return homes.first { $0.uniqueIdentifier == saved } ?? homes.first
    }

    func chooseHome(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: SettingsKey.kioskHomeID)
        subscribe()
        revision += 1
    }

    private func accessories(with serviceType: String) -> [(HMAccessory, HMService)] {
        (home?.accessories ?? []).flatMap { accessory in
            accessory.services.filter { $0.serviceType == serviceType }.map { (accessory, $0) }
        }
    }

    /// Every camera in the home, doorbells first.
    var cameras: [HomeCamera] {
        _ = revision
        return (home?.accessories ?? [])
            .filter { !($0.cameraProfiles ?? []).isEmpty }
            .map { accessory in
                HomeCamera(id: accessory.uniqueIdentifier, name: accessory.name, room: accessory.room?.name ?? "",
                           isDoorbell: accessory.services.contains { $0.serviceType == HMServiceTypeDoorbell })
            }
            .sorted { ($0.isDoorbell ? 0 : 1, $0.name) < ($1.isDoorbell ? 0 : 1, $1.name) }
    }

    /// Cameras that pop up on the wall when they see motion (Family › Kiosk Mode › Cameras).
    var motionCameraIDs: Set<UUID> {
        get {
            _ = revision
            let saved = UserDefaults.standard.stringArray(forKey: SettingsKey.kioskMotionCameras) ?? []
            return Set(saved.compactMap(UUID.init(uuidString:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: SettingsKey.kioskMotionCameras)
            revision += 1
        }
    }

    var doorbellNames: [String] {
        _ = revision
        return accessories(with: HMServiceTypeDoorbell).map { $0.0.name }
    }

    /// The camera for a doorbell: its own, or a camera in the same room.
    func cameraProfile(for accessoryID: UUID) -> HMCameraProfile? {
        guard let accessory = home?.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) else { return nil }
        if let own = accessory.cameraProfiles?.first { return own }
        return home?.accessories.first { $0.room == accessory.room && !($0.cameraProfiles ?? []).isEmpty }?.cameraProfiles?.first
    }

    /// The lock nearest a doorbell: one in the same room, else the only one.
    func lockID(near accessoryID: UUID) -> UUID? {
        let locks = accessories(with: HMServiceTypeLockMechanism).map { $0.0 }
        let room = home?.accessories.first { $0.uniqueIdentifier == accessoryID }?.room
        return (locks.first { $0.room == room } ?? (locks.count == 1 ? locks.first : nil))?.uniqueIdentifier
    }

    func unlock(_ lockID: UUID) async -> Bool {
        guard let accessory = home?.accessories.first(where: { $0.uniqueIdentifier == lockID }),
              let target = accessory.services.flatMap(\.characteristics).first(where: { $0.characteristicType == HMCharacteristicTypeTargetLockMechanismState }) else { return false }
        do {
            try await target.writeValue(NSNumber(value: HMCharacteristicValueLockMechanismState.unsecured.rawValue))
            return true
        } catch {
            return false
        }
    }

    // MARK: Status for the Home card

    var statusItems: [HomeStatusItem] {
        _ = revision
        var items: [HomeStatusItem] = []
        for (accessory, service) in accessories(with: HMServiceTypeLockMechanism) {
            let state = intValue(service, HMCharacteristicTypeCurrentLockMechanismState)
            let label = switch state {
            case 0?: "Unlocked"
            case 1?: "Locked"
            case 2?: "Jammed"
            default: "Unknown"
            }
            items.append(HomeStatusItem(id: service.uniqueIdentifier, name: accessory.name, symbol: state == 1 ? "lock.fill" : "lock.open.fill", state: label, needsAttention: state != 1))
        }
        for (accessory, service) in accessories(with: HMServiceTypeGarageDoorOpener) {
            let state = intValue(service, HMCharacteristicTypeCurrentDoorState)
            let label = switch state {
            case 0?: "Open"
            case 1?: "Closed"
            case 2?: "Opening"
            case 3?: "Closing"
            case 4?: "Stopped"
            default: "Unknown"
            }
            items.append(HomeStatusItem(id: service.uniqueIdentifier, name: accessory.name, symbol: "door.garage.closed", state: label, needsAttention: state != 1))
        }
        for (accessory, service) in accessories(with: HMServiceTypeThermostat).prefix(1) {
            let current = doubleValue(service, HMCharacteristicTypeCurrentTemperature)
            let mode = intValue(service, HMCharacteristicTypeCurrentHeatingCooling)
            var label = current.map { Measurement(value: $0, unit: UnitTemperature.celsius).formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))) } ?? "–"
            if mode == 1 { label += " · heating" } else if mode == 2 { label += " · cooling" }
            items.append(HomeStatusItem(id: service.uniqueIdentifier, name: accessory.name, symbol: "thermometer.medium", state: label, needsAttention: false))
        }
        return items
    }

    private func characteristic(_ service: HMService, _ type: String) -> HMCharacteristic? {
        service.characteristics.first { $0.characteristicType == type }
    }

    private func intValue(_ service: HMService, _ type: String) -> Int? {
        (characteristic(service, type)?.value as? NSNumber)?.intValue
    }

    private func doubleValue(_ service: HMService, _ type: String) -> Double? {
        (characteristic(service, type)?.value as? NSNumber)?.doubleValue
    }

    // MARK: Updates

    /// Asks every accessory Caloma cares about to report changes, and reads where they are now.
    private func subscribe() {
        guard let home else { return }
        let watched: Set<String> = [
            HMCharacteristicTypeInputEvent, HMCharacteristicTypeMotionDetected,
            HMCharacteristicTypeCurrentLockMechanismState, HMCharacteristicTypeCurrentDoorState,
            HMCharacteristicTypeCurrentTemperature, HMCharacteristicTypeCurrentHeatingCooling,
        ]
        for accessory in home.accessories {
            accessory.delegate = self
            for service in accessory.services {
                for characteristic in service.characteristics where watched.contains(characteristic.characteristicType) {
                    guard characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) else { continue }
                    characteristic.enableNotification(true) { _ in }
                    if characteristic.characteristicType != HMCharacteristicTypeInputEvent,
                       characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                        characteristic.readValue { [weak self] _ in
                            Task { @MainActor in self?.revision += 1 }
                        }
                    }
                }
            }
        }
        revision += 1
    }

    private func changed(_ characteristic: HMCharacteristic, of accessory: HMAccessory, in service: HMService) {
        let defaults = UserDefaults.standard
        let showDoorbell = defaults.object(forKey: SettingsKey.kioskDoorbell) as? Bool ?? true
        switch characteristic.characteristicType {
        case HMCharacteristicTypeInputEvent where service.serviceType == HMServiceTypeDoorbell:
            guard showDoorbell else { return }
            ring(DoorbellEvent(accessoryID: accessory.uniqueIdentifier, name: accessory.name, byMotion: false))
        case HMCharacteristicTypeMotionDetected:
            // Motion from a camera the family picked, at most every two minutes per camera.
            // (Apple doesn't share Secure Video's person, animal or package alerts with apps,
            // so this is the camera's own motion sensor.)
            guard (characteristic.value as? NSNumber)?.boolValue == true,
                  !(accessory.cameraProfiles ?? []).isEmpty,
                  motionCameraIDs.contains(accessory.uniqueIdentifier) else {
                revision += 1
                return
            }
            if let last = lastMotion[accessory.uniqueIdentifier], Date.now.timeIntervalSince(last) < 120 { return }
            lastMotion[accessory.uniqueIdentifier] = .now
            ring(DoorbellEvent(accessoryID: accessory.uniqueIdentifier, name: accessory.name, byMotion: true))
        default:
            revision += 1
        }
    }

    private func ring(_ event: DoorbellEvent) {
        guard let onDoorbell else { return }
        // The chime is for the doorbell; motion slides in quietly.
        if !event.byMotion, UserDefaults.standard.object(forKey: SettingsKey.kioskChime) as? Bool ?? true {
            AudioServicesPlaySystemSound(1013)
        }
        onDoorbell(event)
    }
}

extension HomeBridge: HMHomeManagerDelegate, HMAccessoryDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.homeNames = manager.homes.map { HomeName(id: $0.uniqueIdentifier, name: $0.name) }
            self.authorized = manager.authorizationStatus.contains(.authorized)
            self.subscribe()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in
            self.authorized = status.contains(.authorized)
        }
    }

    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        Task { @MainActor in
            self.changed(characteristic, of: accessory, in: service)
        }
    }
}
