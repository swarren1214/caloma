import HomeKit
import SwiftUI

/// The changes Caloma writes back to Apple Home: a device's name, its room, and what a plug or
/// switch shows as. Each throws, so the editor can say why one didn't stick.
extension HomeBridge {
    /// The home's rooms, in Apple Home's order, then the default room.
    var homeRooms: [HMRoom] {
        _ = revision
        guard let home else { return [] }
        return home.rooms + [home.roomForEntireHome()]
    }

    /// Whether this person may rename devices and move them between rooms. Apple Home only
    /// lets the home's owner and people it made administrators do that.
    var canEditHome: Bool {
        _ = revision
        guard let home else { return false }
        return home.homeAccessControl(for: home.currentUser).isAdministrator
    }

    /// Renames the service the tile shows, and the accessory too when that's all it does, so
    /// Siri and the Home app agree with Caloma.
    func rename(_ control: HomeControl, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != control.name else { return }
        try await homeKit { control.service.updateName(trimmed, completionHandler: $0) }
        let controls = control.accessory.services.filter { $0.isUserInteractive && $0.serviceType != HMServiceTypeAccessoryInformation && $0.serviceType != HMServiceTypeBattery }
        if controls.count <= 1 {
            try await homeKit { control.accessory.updateName(trimmed, completionHandler: $0) }
        }
        revision += 1
    }

    /// Moves the device (the whole accessory) to another room.
    func move(_ control: HomeControl, to roomID: UUID) async throws {
        guard let home, let room = homeRooms.first(where: { $0.uniqueIdentifier == roomID }) else { return }
        guard control.accessory.room?.uniqueIdentifier != roomID else { return }
        try await homeKit { home.assignAccessory(control.accessory, to: room, completionHandler: $0) }
        revision += 1
    }

    /// Adds a room to the home and hands it back.
    func addRoom(named name: String) async throws -> HMRoom? {
        guard let home else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let room: HMRoom = try await withCheckedThrowingContinuation { continuation in
            home.addRoom(withName: trimmed) { room, error in
                if let room {
                    continuation.resume(returning: room)
                } else {
                    continuation.resume(throwing: error ?? HMError(.genericError))
                }
            }
        }
        revision += 1
        return room
    }

    /// What a plug or switch controls, so scenes and "turn off the lights" include it.
    func setShowAs(_ control: HomeControl, _ kind: ShowAs) async throws {
        guard control.service.serviceType == HMServiceTypeOutlet || control.service.serviceType == HMServiceTypeSwitch else { return }
        try await homeKit { control.service.updateAssociatedServiceType(kind.serviceType, completionHandler: $0) }
        revision += 1
    }

    /// The Show As choice a plug or switch has now.
    func showAs(_ control: HomeControl) -> ShowAs? {
        _ = revision
        let type = control.service.serviceType
        guard type == HMServiceTypeOutlet || type == HMServiceTypeSwitch else { return nil }
        switch control.service.associatedServiceType {
        case HMServiceTypeLightbulb?: return .light
        case HMServiceTypeFan?, HMServiceTypeVentilationFan?: return .fan
        default: return type == HMServiceTypeSwitch ? .switch : .outlet
        }
    }

    /// Runs a HomeKit call that reports back through a completion handler, and waits for it.
    private func homeKit(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            call { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// A short reason an Apple Home change failed.
    static func describe(_ error: Error) -> String {
        if let error = error as? HMError, error.code == .insufficientPrivileges {
            return "Only the home's owner, or someone they made an admin in the Home app, can rename or move devices."
        }
        return error.localizedDescription
    }
}

/// What a plug or switch shows as.
enum ShowAs: String, CaseIterable, Identifiable {
    case light, fan, outlet, `switch`

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .fan: "Fan"
        case .outlet: "Outlet"
        case .switch: "Switch"
        }
    }

    var symbol: String {
        switch self {
        case .light: "lightbulb"
        case .fan: "fan"
        case .outlet: "powerplug"
        case .switch: "lightswitch.on"
        }
    }

    /// The associated service type Apple Home stores; nil puts it back to what it is.
    var serviceType: String? {
        switch self {
        case .light: HMServiceTypeLightbulb
        case .fan: HMServiceTypeFan
        case .outlet, .switch: nil
        }
    }
}
