import CryptoKit
import LocalAuthentication
import Security
import SwiftUI

/// Optional locks on people's screens in Kiosk Mode. A locked profile asks for that person's
/// own 4-digit passcode (or the iPad's Face ID or Touch ID, when allowed) before it opens,
/// whether they tapped their picture or their face was recognized. Passcodes are kept in this
/// iPad's keychain as salted hashes, never synced.
nonisolated enum ProfileLock {
    private static let service = "com.stephenwarren.caloma.kiosk.profile"

    // Only touched from the main thread.
    nonisolated(unsafe) private static var misses: [UUID: Int] = [:]
    nonisolated(unsafe) private static var lockedUntil: [UUID: Date] = [:]

    /// Family › Kiosk Mode › Profile Locks.
    static func isLocked(_ memberID: UUID, defaults: UserDefaults = .standard) -> Bool {
        let ids = defaults.stringArray(forKey: SettingsKey.kioskLockedProfiles) ?? []
        return ids.contains(memberID.uuidString) && hasPasscode(memberID)
    }

    static func setLocked(_ locked: Bool, for memberID: UUID, defaults: UserDefaults = .standard) {
        var ids = Set(defaults.stringArray(forKey: SettingsKey.kioskLockedProfiles) ?? [])
        if locked { ids.insert(memberID.uuidString) } else { ids.remove(memberID.uuidString) }
        defaults.set(Array(ids), forKey: SettingsKey.kioskLockedProfiles)
        if !locked { clear(memberID) }
    }

    /// Face ID or Touch ID can stand in for the passcode (on unless turned off).
    static var allowsBiometrics: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.kioskLockBiometrics) as? Bool ?? true
    }

    /// "Face ID", "Touch ID", or nil when this iPad has neither set up.
    static var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    static func hasPasscode(_ memberID: UUID) -> Bool { stored(memberID) != nil }

    static func setPasscode(_ pin: String, for memberID: UUID) {
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        if ok != errSecSuccess { salt = Data(UUID().uuidString.utf8.prefix(16)) }
        clear(memberID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: memberID.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: salt + hash(pin, salt: salt),
        ]
        SecItemAdd(query as CFDictionary, nil)
        misses[memberID] = nil
        lockedUntil[memberID] = nil
    }

    static func clear(_ memberID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: memberID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Every profile passcode, for Erase All.
    static func clearAll(defaults: UserDefaults = .standard) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        defaults.removeObject(forKey: SettingsKey.kioskLockedProfiles)
    }

    /// Five wrong in a row locks that profile for 30 seconds, then a minute, and so on.
    static func attempt(_ pin: String, for memberID: UUID) -> ParentPIN.Attempt {
        if let until = lockedUntil[memberID], until > .now { return .lockedOut(until: until) }
        guard let stored = stored(memberID), stored.count > 16 else { return .wrong }
        let salt = Data(stored.prefix(16))
        if hash(pin, salt: salt) == Data(stored.dropFirst(16)) {
            misses[memberID] = nil
            lockedUntil[memberID] = nil
            return .accepted
        }
        let count = (misses[memberID] ?? 0) + 1
        misses[memberID] = count
        if count >= 5 {
            let until = Date.now.addingTimeInterval(TimeInterval(30 * (count - 4)))
            lockedUntil[memberID] = until
            return .lockedOut(until: until)
        }
        return .wrong
    }

    private static func hash(_ pin: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }

    private static func stored(_ memberID: UUID) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: memberID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

/// "Hi, Ella": their picture and their passcode pad. Tries Face ID or Touch ID first when it's
/// allowed, with "Use Passcode" to fall back.
struct ProfileUnlockSheet: View {
    var member: Member
    var onUnlock: () -> Void
    var onCancel: () -> Void

    @State private var lockout: String?
    @State private var triedBiometrics = false

    private var color: Color { member.color.color }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                MemberAvatar(member, size: 96)
                    .padding(5)
                    .overlay(Circle().strokeBorder(color, lineWidth: 5))
                Text("Hi, \(member.name)")
                    .font(.title.bold())
                PINPad(title: "Enter your passcode", tint: color) { pin in
                    switch ProfileLock.attempt(pin, for: member.id) {
                    case .accepted:
                        lockout = nil
                        onUnlock()
                        return true
                    case .wrong:
                        lockout = nil
                        return false
                    case .lockedOut(let until):
                        lockout = "Too many tries. Wait until \(until.formatted(date: .omitted, time: .standard))."
                        return false
                    }
                }
                if let lockout {
                    Text(lockout)
                        .font(.footnote)
                        .foregroundStyle(Brand.late)
                }
                if ProfileLock.allowsBiometrics, let name = ProfileLock.biometryName {
                    Button("Use \(name)") { useBiometrics() }
                        .font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .tint(color)
        .task {
            guard !triedBiometrics else { return }
            triedBiometrics = true
            if ProfileLock.allowsBiometrics, ProfileLock.biometryName != nil {
                useBiometrics()
            }
        }
    }

    private func useBiometrics() {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return }
        Task {
            // A cancel or "Use Passcode" just leaves the passcode pad showing.
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Open \(member.name)'s screen")) ?? false
            if ok { onUnlock() }
        }
    }
}
