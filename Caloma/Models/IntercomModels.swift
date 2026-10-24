import Foundation
import SwiftData
import UIKit

/// One of the family's iPhones and iPads running Caloma: what it's called, where it is, and
/// whether it's a Family Board. Each device writes its own row when Caloma starts (named by
/// `DeviceIdentity.id`), and syncs to everyone in the family like chores, so any parent can
/// rename a board or say which room it's in from Family › Devices.
///
/// The intercom finds devices on the home network by that same ID (see `IntercomService`).
@Model
final class HouseDevice {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var name: String = ""
    /// The room it's in; nil for phones, which go where their person goes.
    var roomID: UUID?
    var kindRaw: String = DeviceKind.phone.rawValue
    /// "iPad Pro", "iPhone": what kind of Apple device, for the list.
    var model: String = ""
    /// Who carries it (phones), from the person picked on that phone.
    var ownerID: UUID?
    /// The Family Board has been opened on it.
    var isBoard: Bool = false
    /// It takes intercom calls. Off: it stays in the list but can't be called.
    var takesCalls: Bool = true
    /// Someone chose the name (the board doesn't ask again).
    var named: Bool = false
    /// The last time Caloma ran on it (updated at most a couple of times a day).
    var lastSeen: Date = Date.now
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(id: UUID, name: String, kind: DeviceKind) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
    }

    var kind: DeviceKind {
        get { DeviceKind(rawValue: kindRaw) ?? .phone }
        set { kindRaw = newValue.rawValue }
    }

    /// The name to show: what the family called it, or the kind of device.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (isBoard ? "Family Board" : model.isEmpty ? kind.label : model) : trimmed
    }

    var symbol: String {
        isBoard ? "rectangle.inset.filled.and.person.filled" : kind.symbol
    }
}

nonisolated enum DeviceKind: String, CaseIterable, Sendable {
    case phone
    case pad

    var label: String {
        switch self {
        case .phone: "iPhone"
        case .pad: "iPad"
        }
    }

    var symbol: String {
        switch self {
        case .phone: "iphone"
        case .pad: "ipad.landscape"
        }
    }

    @MainActor static var current: DeviceKind {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }
}
