import AuthenticationServices
import SwiftUI

/// Family › Account: the shared Hearth account section (HearthAccount.swift) with Caloma's
/// Sign in with Apple, who's signed in, and Sign Out.
///
/// Signing in is optional (everything works without it, and the family syncs through iCloud
/// either way): it fills in your name and lets the other Hearth apps offer "Continue as Steve".
/// Signing out here only signs this device's Caloma out; the other Hearth apps stay signed in.
struct AccountSection: View {
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @Environment(\.colorScheme) private var colorScheme
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
                        errorMessage = error.localizedDescription
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
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
            Button("Sign Out", role: .destructive) { appleUserID = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your family and its data stay on this device and in iCloud.")
        }
        .alert("Couldn't sign in", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: appleUserID) { await checkStillSignedIn() }
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
