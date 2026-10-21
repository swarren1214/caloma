import Foundation
import SwiftData

/// Family-wide settings (what points are called, approvals, streak bonus, allowance, the
/// Family Board, that the family has been set up) stay in UserDefaults for the screens, and are
/// mirrored into `FamilySetting` records so they sync to everyone in the family. A person's own
/// settings follow them to their other devices through `PersonalSettings`. Device settings
/// (notifications, Kid View, which Apple Home and cameras, photos on this device, passcodes and
/// faces kept on this device) stay on the device. See AGENT.md › Settings.
@MainActor
final class SharedSettings {
    static let shared = SharedSettings()

    static let keys: [String] = [
        SettingsKey.pointName, SettingsKey.customPointName, SettingsKey.approvalsByDefault,
        SettingsKey.streakBonus, SettingsKey.allowanceOn, SettingsKey.centsPer100, SettingsKey.payday,
        SettingsKey.splitSpend, SettingsKey.splitSave, SettingsKey.splitGive,
        SettingsKey.familyName, SettingsKey.rotationMakeUp, SettingsKey.familySetUp,
        SettingsKey.importedHomeRooms,
        // The Family Board: set up from anyone's Family settings, shown on the wall iPad.
        SettingsKey.kioskIdleSeconds, SettingsKey.kioskShowsFamily, SettingsKey.kioskKeepAwake,
        SettingsKey.kioskDoorbell, SettingsKey.kioskChime, SettingsKey.kioskLockBiometrics,
        SettingsKey.kioskDims, SettingsKey.kioskDimMinutes, SettingsKey.kioskMatchLight,
        SettingsKey.kioskScreensaver, SettingsKey.kioskScreensaverMinutes,
        SettingsKey.kioskScreensaverPhotoSeconds, SettingsKey.kioskScreensaverShuffle,
        SettingsKey.kioskScreensaverZoom, SettingsKey.kioskScreensaverStyle,
        SettingsKey.kioskScreensaverWakeOnMotion, SettingsKey.kioskScreensaverWakeTo,
        SettingsKey.kioskScreensaverNight, SettingsKey.kioskScreensaverWidgets,
        SettingsKey.kioskScreensaverWallpapers, SettingsKey.kioskScreensaverSkipScreenshots,
    ]

    private var container: ModelContainer?
    /// Each key's value as last sent or received, so only real changes go up.
    private var lastSeen: [String: String] = [:]
    private var applying = false
    private let defaults = UserDefaults.standard

    private init() {}

    func start(with container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        let context = container.mainContext
        pull(from: context)
        pushMissing(in: context)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SharedSettings.shared.push() }
        }
    }

    /// Sends any family setting that changed on this device.
    func push() {
        guard !applying, let context = container?.mainContext else { return }
        var changed = false
        for key in Self.keys {
            guard let value = encode(key), value != lastSeen[key] else { continue }
            upsert(key: key, value: value, in: context)
            lastSeen[key] = value
            changed = true
        }
        if changed { Persistence.save(context) }
    }

    /// Takes the family's settings from the records (after a sync, or on joining a family).
    func pull(from context: ModelContext) {
        let rows = (try? context.fetch(FetchDescriptor<FamilySetting>())) ?? []
        // If two rows somehow share a key, the newest wins.
        var latest: [String: FamilySetting] = [:]
        for row in rows where Self.keys.contains(row.key) {
            if let existing = latest[row.key], existing.updatedAt >= row.updatedAt { continue }
            latest[row.key] = row
        }
        applying = true
        for (key, row) in latest where row.value != encode(key) {
            decode(row.value, into: key)
        }
        for (key, row) in latest { lastSeen[key] = row.value }
        applying = false
    }

    /// Settings whose records were deleted in iCloud (Erase All Data on another device): they
    /// go back to their defaults here too, so this device doesn't send them up again.
    func forget(_ removedKeys: [String]) {
        applying = true
        for key in removedKeys where Self.keys.contains(key) {
            defaults.removeObject(forKey: key)
            lastSeen[key] = nil
        }
        applying = false
    }

    /// The first time: every family setting this device has, so the records exist.
    private func pushMissing(in context: ModelContext) {
        let rows = (try? context.fetch(FetchDescriptor<FamilySetting>())) ?? []
        let have = Set(rows.map(\.key))
        var changed = false
        for key in Self.keys where !have.contains(key) {
            guard let value = encode(key) else { continue }
            upsert(key: key, value: value, in: context)
            lastSeen[key] = value
            changed = true
        }
        if changed { Persistence.save(context) }
    }

    private func upsert(key: String, value: String, in context: ModelContext) {
        let id = FamilySetting.id(for: key)
        var descriptor = FetchDescriptor<FamilySetting>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let row = try? context.fetch(descriptor).first {
            row.value = value
            row.updatedAt = .now
        } else {
            context.insert(FamilySetting(key: key, value: value))
        }
    }

    /// "b:1", "i:500", "s:stars", "a:[\"Kitchen\"]", or nil when the setting has never been set.
    private func encode(_ key: String) -> String? {
        switch defaults.object(forKey: key) {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "b:" + (number.boolValue ? "1" : "0") }
            return "i:\(number.intValue)"
        case let string as String:
            return "s:" + string
        case let strings as [String]:
            guard let data = try? JSONEncoder().encode(strings) else { return nil }
            return "a:" + String(decoding: data, as: UTF8.self)
        default:
            return nil
        }
    }

    private func decode(_ value: String, into key: String) {
        let body = String(value.dropFirst(2))
        switch value.prefix(2) {
        case "b:": defaults.set(body == "1", forKey: key)
        case "i:": defaults.set(Int(body) ?? 0, forKey: key)
        case "s:": defaults.set(body, forKey: key)
        case "a:":
            if let strings = try? JSONDecoder().decode([String].self, from: Data(body.utf8)) {
                defaults.set(strings, forKey: key)
            }
        default: break
        }
    }
}
