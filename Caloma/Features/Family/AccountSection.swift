import AuthenticationServices
import SwiftUI

/// Profile › Account: the shared Hearth account section (HearthAccount.swift) with Caloma's
/// Sign in with Apple, who's signed in, and Sign Out.
///
/// Signing in is optional (everything works without it, and the family syncs through iCloud
/// either way): it fills in your name and lets the other Hearth apps offer "Continue as Steve".
/// One sign-in for the Hearth apps: signed in with Apple in another Hearth app on this device
/// means signed in here too, and Sign Out signs out of all of them.
struct AccountSection: View {
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @State private var confirmsSignOut = false
    @State private var errorMessage: String?

    /// The name and email Apple shared, kept for the Hearth apps (Apple only sends them once).
    private var identity: HearthSharedAppleID? {
        guard !appleUserID.isEmpty, let shared = HearthAccounts.appleID(), shared.userID == appleUserID else { return nil }
        return shared
    }

    var body: some View {
        Section {
            HearthAccountSection(
                app: .caloma,
                profile: appleUserID.isEmpty ? nil : HearthAccountProfile(name: identity?.fullName, email: identity?.email),
                pitch: "Optional: your family syncs through iCloud either way. Signing in adds your name and lets your other Hearth apps recognize you."
            ) {
                CalomaAppleSignInButton { errorMessage = $0 }
            } onSignOut: {
                confirmsSignOut = true
            }
            .hearthAccountSectionRow()
        } header: {
            Text("Account")
        } footer: {
            if !appleUserID.isEmpty {
                Text("Your family keeps syncing through iCloud whether or not you're signed in.")
            }
        }
        .alert("Sign out of Caloma?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) {
                appleUserID = ""
                HearthAccounts.signOutEverywhere()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out of your other Hearth apps on this device too. Your family and its data stay on this device and in iCloud.")
        }
        .alert("Couldn't sign in", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: appleUserID) { await checkStillSignedIn() }
        .task { followSharedSignIn() }
        .onReceive(NotificationCenter.default.publisher(for: Hearth.didChange)) { _ in followSharedSignIn() }
    }

    /// The same person as the other Hearth apps: their Apple sign-in when there is one, and
    /// signed out when they signed out (everywhere) in another app.
    private func followSharedSignIn() {
        guard !ScreenshotMode.isOn else { return }
        let sharedKey = "hearth.caloma.appleIDShared"
        if let shared = HearthAccounts.appleID() {
            if shared.userID != appleUserID { appleUserID = shared.userID }
            UserDefaults.standard.set(true, forKey: sharedKey)
        } else if !appleUserID.isEmpty {
            if UserDefaults.standard.bool(forKey: sharedKey) {
                // It was shared and now it's gone: signed out in another Hearth app.
                if HearthAccounts.session() == nil {
                    appleUserID = ""
                    UserDefaults.standard.set(false, forKey: sharedKey)
                }
            } else {
                // Signed in before the apps shared a sign-in: share it now.
                HearthAccounts.saveAppleID(HearthSharedAppleID(userID: appleUserID, fullName: nil, email: nil, updatedBy: .caloma))
                if HearthAccounts.appleID()?.userID == appleUserID { UserDefaults.standard.set(true, forKey: sharedKey) }
            }
        }
    }

    /// Someone can stop using Sign in with Apple for Caloma in Settings › Apple Account; then
    /// this device is signed out too.
    private func checkStillSignedIn() async {
        guard !appleUserID.isEmpty else { return }
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleUserID)
        if state == .revoked || state == .notFound {
            appleUserID = ""
        }
    }
}

/// Caloma's Sign in with Apple: no server account, so it only keeps the Apple ID on this device
/// and shares the name with the other Hearth apps ("Continue as Steve"). Profile › Account and
/// onboarding's Welcome both use it.
struct CalomaAppleSignInButton: View {
    var onError: (String) -> Void
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
                appleUserID = credential.user
                let fullName = credential.fullName
                    .map { $0.formatted() }
                    .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                HearthAccounts.saveAppleID(HearthSharedAppleID(userID: credential.user, fullName: fullName, email: credential.email, updatedBy: .caloma))
            case .failure(let error as ASAuthorizationError) where error.code == .canceled:
                break
            case .failure(let error):
                onError(FriendlyError.message(for: error, doing: "sign you in with Apple"))
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
    }
}
