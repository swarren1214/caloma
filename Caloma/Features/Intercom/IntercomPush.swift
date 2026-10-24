import CryptoKit
import Foundation
import OSLog
import PushKit
import SwiftData

/// Wakes the family's phones and iPads for a call when Caloma isn't open on them (locked, or in
/// the background), so the call comes through like a phone call (`IntercomCallKit`).
///
/// Each device gives the Hearth API its VoIP push token, filed under a secret made from the
/// family's `HouseholdKey`; the server only keeps a hash of it, and there's no sign-in. Calling
/// a device that isn't on the network right now asks the server to wake it; once awake it joins
/// the home network and the call goes on as usual, straight between the devices.
final class IntercomPush: NSObject {
    static let shared = IntercomPush()

    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "intercom")
    private var registry: PKPushRegistry?
    private var token: String?
    /// The ordinary notification token (for broadcasts), from the app delegate.
    var alertToken: String? {
        didSet { if alertToken != oldValue { register() } }
    }
    private static let registeredKey = "intercom.push.registered"
    private static let registeredAtKey = "intercom.push.registeredAt"
    /// Sent again now and then, so the server's copy doesn't go stale.
    private static let refreshEvery: TimeInterval = 7 * 24 * 60 * 60

    private override init() {}

    /// Asks for a VoIP token. Called as Caloma launches: a push that wakes Caloma is only
    /// delivered once this has run in that launch.
    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    /// The family's secret for the server (base64url, 43 characters). Made from the household
    /// key, never the key itself.
    nonisolated static func secret(from key: SymmetricKey) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("caloma.intercom.relay.v1".utf8), using: key)
        return Data(code).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Debug builds get their pushes from Apple's sandbox; TestFlight and the App Store from production.
    private var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private var householdSecret: String? {
        guard let context = AppRouter.shared.container?.mainContext, let key = HouseholdKey.current(in: context) else { return nil }
        return Self.secret(from: key)
    }

    /// Gives the server this device's token, when there's one and the family's key is here.
    /// Called when the token arrives and each time the intercom starts.
    func register() {
        guard let token, let secret = householdSecret else { return }
        let marker = "\(token).\(alertToken ?? "-").\(SHA256.hash(data: Data(secret.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()).\(environment)"
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.registeredKey) == marker,
           let at = defaults.object(forKey: Self.registeredAtKey) as? Date,
           Date.now.timeIntervalSince(at) < Self.refreshEvery {
            return
        }
        var body: [String: Any] = [
            "secret": secret,
            "device": DeviceIdentity.id.uuidString.lowercased(),
            "token": token,
            "environment": environment,
        ]
        if let alertToken { body["alertToken"] = alertToken }
        Task {
            guard await post("caloma/intercom/devices", body) != nil else { return }
            defaults.set(marker, forKey: Self.registeredKey)
            defaults.set(Date.now, forKey: Self.registeredAtKey)
            log.info("Intercom can wake this device")
        }
    }

    /// Wakes these devices for a call. The ones the server reached.
    func ring(call: UUID, name: String, video: Bool, to devices: [UUID]) async -> Set<UUID> {
        guard !devices.isEmpty, let secret = householdSecret else { return [] }
        let body: [String: Any] = [
            "secret": secret,
            "call": call.uuidString.lowercased(),
            "from": DeviceIdentity.id.uuidString.lowercased(),
            "name": String(name.prefix(60)),
            "video": video,
            "to": devices.prefix(8).map { $0.uuidString.lowercased() },
        ]
        guard let data = await post("caloma/intercom/ring", body),
              let reply = try? JSONDecoder().decode(RingReply.self, from: data) else { return [] }
        return Set(reply.woken.compactMap(UUID.init(uuidString:)))
    }

    private struct RingReply: Decodable { let woken: [String] }

    private struct IceReply: Decodable { let iceServers: [CallIceServer]; let ttl: Double }
    private var ice: (servers: [CallIceServer], until: Date)?

    /// STUN and TURN for calls away from home, kept until they're half way to expiring.
    func iceServers() async -> [CallIceServer] {
        if let ice, ice.until > .now { return ice.servers }
        guard let secret = householdSecret,
              let data = await post("caloma/intercom/ice", ["secret": secret]),
              let reply = try? JSONDecoder().decode(IceReply.self, from: data),
              !reply.iceServers.isEmpty else { return ice?.servers ?? CallIceServer.stunOnly }
        ice = (reply.iceServers, Date.now.addingTimeInterval(reply.ttl / 2))
        return reply.iceServers
    }

    /// Tells these devices (off the network) that someone's broadcasting.
    func broadcast(call: UUID, name: String, to devices: [UUID]) async {
        guard !devices.isEmpty, let secret = householdSecret else { return }
        let body: [String: Any] = [
            "secret": secret,
            "call": call.uuidString.lowercased(),
            "from": DeviceIdentity.id.uuidString.lowercased(),
            "name": String(name.prefix(60)),
            "to": devices.prefix(16).map { $0.uuidString.lowercased() },
        ]
        _ = await post("caloma/intercom/broadcast", body)
    }

    private func post(_ path: String, _ body: [String: Any]) async -> Data? {
        var request = URLRequest(url: AppConfig.apiBaseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                log.error("Intercom relay \(path, privacy: .public) answered \(status)")
                return nil
            }
            return data
        } catch {
            log.error("Intercom relay \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension IntercomPush: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            self.token = token
            self.register()
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated {
            self.token = nil
            UserDefaults.standard.removeObject(forKey: Self.registeredKey)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let ring = WokenRing(payload.dictionaryPayload)
        let done = PushCompletion(completion)
        MainActor.assumeIsolated {
            // iOS insists every one of these shows a call, at once.
            IntercomCallKit.shared.report(ring) { done.run() }
        }
    }
}

/// What a wake-up push says: who's calling, and which call.
nonisolated struct WokenRing: Equatable, Sendable {
    let call: UUID
    let from: UUID
    let name: String
    let video: Bool

    init?(_ payload: [AnyHashable: Any]) {
        guard let ring = payload["intercom"] as? [String: Any],
              let call = (ring["call"] as? String).flatMap(UUID.init(uuidString:)),
              let from = (ring["from"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        self.call = call
        self.from = from
        let name = (ring["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name.isEmpty ? "Intercom" : name
        self.video = ring["video"] as? Bool ?? false
    }
}

/// PushKit's completion, carried into CallKit's callback.
private nonisolated final class PushCompletion: @unchecked Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func run() { completion() }
}
