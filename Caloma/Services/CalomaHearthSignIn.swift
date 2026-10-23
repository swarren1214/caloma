import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import OSLog
import Security

/// Signing in to a Hearth account from Caloma. Caloma used to only borrow a sign-in another Hearth
/// app made, and its own Sign in with Apple stayed on this device, so someone who only used
/// Caloma never had a Hearth account, and so never got their household organizer's Hearth+
/// (the Hearth API shares it with accounts, `HearthHouseholdServer`).
///
/// Now Caloma's Sign in with Apple also trades Apple's identity token for a Hearth (Supabase)
/// session and shares it with every Hearth app (`HearthAccounts`), as Hearken and Sated do.
/// Caloma still never refreshes the session itself: it borrows it while it's good, and the apps
/// with an API client keep it fresh (one refresh token, spent by one app at a time).
@MainActor
@Observable
final class CalomaHearthSignIn {
    static let shared = CalomaHearthSignIn()

    private(set) var isSigningIn = false
    var errorMessage: String?
    @ObservationIgnored private var nonce: String?
    private static let log = Logger(subsystem: "com.stephenwarren.caloma", category: "hearth-sign-in")

    private init() {}

    /// Signed in to a Hearth account (here or in another Hearth app).
    var isSignedIn: Bool { HearthAccounts.session() != nil }

    /// In `SignInWithAppleButton`'s request closure: asks for the name and email, with a nonce.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            nonce = nil
            return
        }
        let raw = bytes.map { String(format: "%02x", $0) }.joined()
        nonce = raw
        request.nonce = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// After Apple's sign-in succeeded: the Hearth account, shared with every Hearth app, then the
    /// household's plan.
    func connect(_ credential: ASAuthorizationAppleIDCredential) async {
        guard let tokenData = credential.identityToken, let identityToken = String(data: tokenData, encoding: .utf8),
              let nonce else {
            errorMessage = "Apple's sign-in didn't finish. Please try again."
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let session = try await Self.session(identityToken: identityToken, nonce: nonce)
            HearthAccounts.saveSession(HearthSharedSession(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                expiresAt: Double(session.expiresAt),
                userID: session.user.id,
                email: session.user.email,
                updatedBy: .caloma
            ))
            errorMessage = nil
            // The household's plan follows the sign-in: join the organizer's on the server.
            await HearthPurchases.shared.refresh()
            HearthHouseholdServer.scheduleUpdate()
        } catch {
            Self.log.error("Hearth sign-in failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Caloma couldn't sign you in to Hearth just now. Check your connection and try again."
        }
    }

    private nonisolated struct Session: Decodable {
        nonisolated struct User: Decodable {
            var id: String
            var email: String?
        }
        var accessToken: String
        var refreshToken: String
        var expiresAt: Int
        var user: User

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", user
        }
    }

    private nonisolated static func session(identityToken: String, nonce: String) async throws -> Session {
        guard let url = URL(string: "/auth/v1/token?grant_type=id_token", relativeTo: AppConfig.supabaseURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["provider": "apple", "id_token": identityToken, "nonce": nonce])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }
}
