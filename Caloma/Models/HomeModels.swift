import Foundation
import SwiftData
import SwiftUI

/// How the family dressed up one Apple Home device (or scene) in Caloma: its icon, color, tile
/// style and photo, and where it shows. Apple Home can't store these, so Caloma does, and it
/// syncs to everyone in the family like chores.
///
/// Found by `serviceID` first. HomeKit's IDs can differ between family members' devices, so
/// `matchKey` (name, room and kind) is the fallback, refreshed whenever Caloma renames or moves
/// the device.
@Model
final class DeviceStyle {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    /// HMHome.uniqueIdentifier, as this device saw it.
    var homeID: String = ""
    /// HMService.uniqueIdentifier (or HMActionSet's, for a scene).
    var serviceID: String = ""
    /// "front door|entry|lock"
    var matchKey: String = ""
    /// An SF Symbol; empty means the kind's own.
    var symbol: String = ""
    /// "#RRGGBB"; empty means the kind's own.
    var colorHex: String = ""
    var tileStyleRaw: String = TileStyle.tinted.rawValue
    @Attribute(.externalStorage) var photoData: Data?
    /// Left out of Control (and everywhere else).
    var hidden: Bool = false
    /// Kids can use it in Kid View and on the wall iPad.
    var kidsAllowed: Bool = false
    /// A shortcut on the Home tab.
    var pinnedToHome: Bool = false
    var sortOrder: Int = 0
    var updatedAt: Date = Date.now

    init(homeID: String, serviceID: String, matchKey: String) {
        self.homeID = homeID
        self.serviceID = serviceID
        self.matchKey = matchKey
    }

    var tileStyle: TileStyle {
        get { TileStyle(rawValue: tileStyleRaw) ?? .tinted }
        set { tileStyleRaw = newValue.rawValue }
    }

    var color: Color? { Color(hexString: colorHex) }

    /// Nothing set: no reason to keep the record.
    var isEmpty: Bool {
        symbol.isEmpty && colorHex.isEmpty && tileStyle == .tinted && photoData == nil && !hidden && !kidsAllowed && !pinnedToHome
    }
}

/// How a device's tile looks when it's on.
nonisolated enum TileStyle: String, CaseIterable, Identifiable, Sendable {
    /// A wash of its color.
    case tinted
    /// Filled with its color.
    case solid
    /// Dark glass with its color glowing through.
    case glow

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Every style, indexed for the tiles: by service ID, then by match key. The newest wins
/// when two match.
struct StyleBook {
    private var byService: [String: DeviceStyle] = [:]
    private var byKey: [String: DeviceStyle] = [:]

    init(_ styles: [DeviceStyle] = []) {
        for style in styles.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if !style.serviceID.isEmpty { byService[style.serviceID] = style }
            if !style.matchKey.isEmpty { byKey[style.matchKey] = style }
        }
    }

    func style(serviceID: String, matchKey: String) -> DeviceStyle? {
        byService[serviceID] ?? byKey[matchKey]
    }
}

extension EnvironmentValues {
    /// The family's device styles, for every tile on screen.
    @Entry var styleBook = StyleBook()
}
