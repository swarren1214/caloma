import CryptoKit
import Foundation
import Security
import SwiftUI

/// The 4-digit parent PIN for Kiosk Mode. Kept in this iPad's keychain (never synced), as a
/// salted hash. It unlocks approvals on the wall and leaving Kiosk Mode; faces never do.
nonisolated enum ParentPIN {
    private static let service = "com.stephenwarren.caloma.kiosk"
    private static let account = "parentPIN"
    static let length = 4

    enum Attempt: Equatable {
        case accepted
        case wrong
        /// Too many wrong tries in a row; try again after this.
        case lockedOut(until: Date)
    }

    // Only touched from the PIN pad on the main thread.
    nonisolated(unsafe) private static var misses = 0
    nonisolated(unsafe) private static var lockedUntil: Date?

    static var isSet: Bool { stored() != nil }

    static func set(_ pin: String) {
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        if ok != errSecSuccess { salt = Data(UUID().uuidString.utf8.prefix(16)) }
        let value = salt + hash(pin, salt: salt)
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: value,
        ]
        SecItemAdd(query as CFDictionary, nil)
        misses = 0
        lockedUntil = nil
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Five wrong in a row locks the pad for 30 seconds, then a minute, and so on.
    static func attempt(_ pin: String) -> Attempt {
        if let lockedUntil, lockedUntil > .now { return .lockedOut(until: lockedUntil) }
        guard let stored = stored(), stored.count > 16 else { return .wrong }
        let salt = stored.prefix(16)
        let expected = stored.dropFirst(16)
        if hash(pin, salt: Data(salt)) == Data(expected) {
            misses = 0
            lockedUntil = nil
            return .accepted
        }
        misses += 1
        if misses >= 5 {
            let until = Date.now.addingTimeInterval(TimeInterval(30 * (misses - 4)))
            lockedUntil = until
            return .lockedOut(until: until)
        }
        return .wrong
    }

    private static func hash(_ pin: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }

    private static func stored() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

/// Four dots and a phone-style keypad: 1–9, then 0 and delete. Calls `onComplete` with the
/// four digits; return false to shake and clear.
struct PINPad: View {
    var title: String
    var tint: Color
    /// Big enough to hit without looking twice, on the wall or in a hand.
    var keySize: CGFloat = 84
    var onComplete: (String) -> Bool

    @State private var digits = ""
    @State private var shakes = 0

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete"]

    var body: some View {
        // Shrinks the keys to fit when the space is short (an iPad on its side, a small
        // window), rather than cutting off the bottom row.
        ViewThatFits(in: .vertical) {
            pad(keySize)
            pad(keySize * 0.8)
            pad(keySize * 0.66)
            pad(min(keySize, 48))
        }
        .sensoryFeedback(.error, trigger: shakes)
    }

    private func pad(_ keySize: CGFloat) -> some View {
        VStack(spacing: keySize * 0.28) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                ForEach(0..<ParentPIN.length, id: \.self) { index in
                    Circle()
                        .fill(index < digits.count ? tint : Color.clear)
                        .overlay(Circle().strokeBorder(index < digits.count ? tint : Color.secondary, lineWidth: 2))
                        .frame(width: 14, height: 14)
                }
            }
            .modifier(ShakeEffect(animatableData: CGFloat(shakes)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(digits.count) of \(ParentPIN.length) digits entered")

            // One container for all the glass, so the keys render together (and never melt into
            // each other: they're further apart than its spacing).
            GlassEffectContainer(spacing: 4) {
            Grid(horizontalSpacing: keySize * 0.3, verticalSpacing: keySize * 0.22) {
                ForEach(0..<4, id: \.self) { row in
                    GridRow {
                        ForEach(keys[(row * 3)..<(row * 3 + 3)], id: \.self) { key in
                            keyView(key, keySize: keySize)
                        }
                    }
                }
            }
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: String, keySize: CGFloat) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: keySize, height: keySize)
        } else if key == "delete" {
            Button {
                if !digits.isEmpty { digits.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: keySize * 0.32, weight: .medium))
                    .frame(width: keySize, height: keySize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Delete")
        } else {
            Button {
                type(key)
            } label: {
                Text(key)
                    .font(.system(size: keySize * 0.42, weight: .regular, design: .rounded))
                    .frame(width: keySize, height: keySize)
                    .contentShape(Circle())
                    // Liquid Glass keys that flex and shimmer under a finger, like the Lock Screen's.
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    private func type(_ key: String) {
        guard digits.count < ParentPIN.length else { return }
        digits += key
        guard digits.count == ParentPIN.length else { return }
        let entered = digits
        // Let the last dot fill before checking.
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            if !onComplete(entered) {
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                digits = ""
            }
        }
    }
}

/// Checks a PIN against `ParentPIN` and explains a lockout. Wraps `PINPad` for unlocking.
struct ParentPINPad: View {
    var title: String
    var tint: Color
    /// Big enough to hit without looking twice, on the wall or in a hand.
    var keySize: CGFloat = 84
    var onUnlock: () -> Void

    @State private var lockout: String?

    var body: some View {
        VStack(spacing: 6) {
            PINPad(title: title, tint: tint, keySize: keySize) { pin in
                switch ParentPIN.attempt(pin) {
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
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Choose a new PIN: type it, then type it again.
struct PINSetupSheet: View {
    var title = "Parent PIN"
    var prompt = "Choose a 4-digit PIN for the Family Board."
    var save: (String) -> Void = { ParentPIN.set($0) }
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var first: String?
    @State private var mismatch = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(first == nil ? prompt : "Type it again to be sure.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if mismatch {
                    Text("Those didn't match. Start again.")
                        .font(.footnote)
                        .foregroundStyle(Brand.late)
                }
                PINPad(title: first == nil ? "New" : "Confirm", tint: accent) { pin in
                    if let first {
                        guard pin == first else {
                            self.first = nil
                            mismatch = true
                            return false
                        }
                        save(pin)
                        onDone()
                        dismiss()
                        return true
                    }
                    first = pin
                    mismatch = false
                    return true
                }
                .id(first == nil ? "new" : "confirm")
                Spacer()
            }
            .padding(24)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// A sideways shake for a wrong PIN.
nonisolated struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}
