import CryptoKit
import Foundation
import OSLog
import Security
import SwiftData
import UIKit

/// This device's own ID: made once and kept in the Keychain on this device only (never synced),
/// so it survives deleting and reinstalling Caloma and the family's device list doesn't fill up
/// with copies of the same iPad.
nonisolated enum DeviceIdentity {
    private static let service = "com.stephenwarren.caloma.device"
    private static let account = "id"

    static let id: UUID = {
        switch read() {
        case let .found(saved):
            return saved
        case .missing:
            let new = UUID()
            save(new)
            return new
        case .locked:
            // Launched in the background before the first unlock: the Keychain can't be read
            // yet. A stand-in for this launch only; the real ID is untouched.
            return UUID()
        }
    }()

    private enum Lookup {
        case found(UUID)
        case missing
        case locked
    }

    private static func read() -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .locked }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
            return .missing
        }
        return .found(id)
    }

    private static func save(_ id: UUID) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(id.uuidString.utf8),
            // This device only: an iCloud Keychain copy would give a new iPad its old one's ID.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(item as CFDictionary)
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Keeps this device's row in the family's device list up to date.
@MainActor
enum DeviceRegistry {
    private static let log = Logger(subsystem: "com.stephenwarren.caloma", category: "intercom")

    /// How often `lastSeen` is written, so a board that's always on doesn't sync all day.
    private static let seenEvery: TimeInterval = 12 * 60 * 60

    /// This device's row, made if it isn't there yet. Called as Caloma starts.
    @discardableResult
    static func register(in context: ModelContext) -> HouseDevice {
        let me = DeviceIdentity.id
        var descriptor = FetchDescriptor<HouseDevice>(predicate: #Predicate { $0.id == me })
        descriptor.fetchLimit = 1
        let owner = UserDefaults.standard.string(forKey: SettingsKey.currentMember).flatMap(UUID.init(uuidString:))
        if let row = (try? context.fetch(descriptor))?.first {
            var changed = false
            if Date.now.timeIntervalSince(row.lastSeen) > seenEvery {
                row.lastSeen = .now
                changed = true
            }
            if row.kind == .phone, let owner, row.ownerID != owner {
                row.ownerID = owner
                if !row.named { row.name = defaultName(owner: owner, in: context) }
                changed = true
            }
            if changed {
                row.updatedAt = .now
                Persistence.save(context)
            }
            return row
        }
        let kind = DeviceKind.current
        let row = HouseDevice(id: me, name: defaultName(owner: kind == .phone ? owner : nil, in: context), kind: kind)
        row.model = UIDevice.current.model
        row.ownerID = kind == .phone ? owner : nil
        context.insert(row)
        Persistence.save(context)
        log.info("Registered this \(kind.label, privacy: .public) as \(me.uuidString, privacy: .public)")
        return row
    }

    /// The Family Board opened here: mark it as a board, so it shows under Family Boards.
    static func markBoard(in context: ModelContext) -> HouseDevice {
        let row = register(in: context)
        if !row.isBoard {
            row.isBoard = true
            if !row.named { row.name = "Family Board" }
            row.updatedAt = .now
            Persistence.save(context)
        }
        return row
    }

    static func rename(_ device: HouseDevice, to name: String, room: UUID?, in context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { device.name = trimmed }
        device.roomID = room
        device.named = true
        device.updatedAt = .now
        Persistence.save(context)
    }

    /// "Steve's iPhone", or just "iPhone" before anyone's been picked on this phone.
    private static func defaultName(owner: UUID?, in context: ModelContext) -> String {
        let model = UIDevice.current.model
        guard let owner else { return model }
        var descriptor = FetchDescriptor<Member>(predicate: #Predicate { $0.id == owner })
        descriptor.fetchLimit = 1
        guard let person = (try? context.fetch(descriptor))?.first, !person.name.isEmpty else { return model }
        return "\(person.name)'s \(model)"
    }
}

/// The family's intercom key: 32 random bytes made by the first device that needs it, kept in
/// a `FamilySetting` whose `secret` goes to iCloud encrypted end to end. Every device in the
/// family has it after a sync; devices on the same Wi-Fi from another household don't, so they
/// can't connect, and nothing sent between the family's devices can be read on the network.
@MainActor
enum HouseholdKey {
    static let settingKey = "intercom.householdKey"

    /// The key, made now if the family doesn't have one yet. Nil until this device has synced
    /// with the family once, so a new device never makes a second key over the family's.
    static func current(in context: ModelContext) -> SymmetricKey? {
        let id = FamilySetting.id(for: settingKey)
        var descriptor = FetchDescriptor<FamilySetting>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let row = (try? context.fetch(descriptor))?.first, let secret = row.secret, secret.count == 32 {
            return SymmetricKey(data: secret)
        }
        let sync = CloudSync.shared
        if sync.lastSynced == nil { return nil }
        if case .waiting = sync.location { return nil }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        if let row = (try? context.fetch(descriptor))?.first {
            row.secret = data
            row.updatedAt = .now
        } else {
            let row = FamilySetting(key: settingKey, value: "")
            row.secret = data
            context.insert(row)
        }
        Persistence.save(context)
        return key
    }

    /// The pre-shared key both ends of a connection use: derived from the household key, so the
    /// household key itself never goes into TLS.
    nonisolated static func connectionKey(from key: SymmetricKey) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: Data("caloma.intercom.v1".utf8), using: key)
        return Data(code)
    }

    /// A short fingerprint of the key, to show in Sync Details when two devices won't connect.
    nonisolated static func fingerprint(of key: SymmetricKey) -> String {
        let digest = SHA256.hash(data: connectionKey(from: key))
        return digest.prefix(3).map { String(format: "%02X", $0) }.joined()
    }
}
