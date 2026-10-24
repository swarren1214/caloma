import CryptoKit
import Foundation
import Observation
import OSLog

/// The intercom away from home. Devices that aren't on the same network reach each other
/// through a Supabase Realtime channel for the family: what the home network's connections
/// carry (rings, answers, WebRTC setup) goes through it instead. Sound and video still go
/// straight between the devices (or through TURN when a network won't allow that).
///
/// Nothing readable passes through Supabase: the channel's name and every message's key come
/// from the family's `HouseholdKey`, and each message is sealed with AES-GCM, addressed to one
/// device and dated, so it can't be read, changed or replayed. Supabase sees which device IDs
/// are on the channel, and when they send.
///
/// Speaks Realtime's Phoenix protocol over a plain WebSocket, so Caloma needs no Supabase SDK.
@Observable
final class IntercomRelay {
    /// The family's other devices on the channel right now.
    private(set) var present: Set<UUID> = []
    private(set) var isConnected = false

    @ObservationIgnored var onMessage: ((UUID, IntercomMessage) -> Void)?
    @ObservationIgnored var onPresence: (() -> Void)?

    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "intercom")
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var topic = ""
    @ObservationIgnored private var sealing: SymmetricKey?
    @ObservationIgnored private var fingerprint = ""
    @ObservationIgnored private var ref = 0
    @ObservationIgnored private var joinRef: String?
    @ObservationIgnored private var joined = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var metas: [UUID: Int] = [:]
    /// Message IDs already taken, so a replay is dropped.
    @ObservationIgnored private var seen: [String: Date] = [:]
    /// Messages sent before the channel was joined, sent once it is.
    @ObservationIgnored private var waiting: [(UUID, IntercomMessage)] = []

    /// How far a message's date may be from this device's clock.
    nonisolated static let maximumAge: TimeInterval = 120

    private var me: UUID { DeviceIdentity.id }

    // MARK: Keys

    nonisolated static func topic(for key: SymmetricKey) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("caloma.intercom.topic.v1".utf8), using: key)
        return "caloma-icom-" + Data(code).prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sealingKey(for key: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("caloma.intercom.wan.v1".utf8), outputByteCount: 32)
    }

    /// One message, sealed for one device.
    nonisolated struct Envelope: Codable, Equatable, Sendable {
        let from: UUID
        let to: UUID
        let id: String
        let at: Date
        let message: IntercomMessage
    }

    nonisolated static func seal(_ envelope: Envelope, with key: SymmetricKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let box = try AES.GCM.seal(try encoder.encode(envelope), using: key)
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        return combined.base64EncodedString()
    }

    nonisolated static func open(_ text: String, with key: SymmetricKey) throws -> Envelope {
        guard let data = Data(base64Encoded: text) else { throw CocoaError(.coderReadCorrupt) }
        let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Envelope.self, from: plain)
    }

    // MARK: Starting and stopping

    func start(with key: SymmetricKey) {
        let fingerprint = HouseholdKey.fingerprint(of: key)
        if running, fingerprint == self.fingerprint { return }
        stop()
        self.fingerprint = fingerprint
        topic = Self.topic(for: key)
        sealing = Self.sealingKey(for: key)
        running = true
        attempts = 0
        connect()
    }

    func stop() {
        running = false
        retry?.cancel()
        retry = nil
        disconnect()
        waiting = []
    }

    private func connect() {
        guard running else { return }
        var components = URLComponents(url: AppConfig.supabaseURL.appending(path: "realtime/v1/websocket"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: AppConfig.supabasePublishableKey),
            URLQueryItem(name: "vsn", value: "1.0.0"),
        ]
        guard let url = components.url else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        joined = false
        joinRef = nextRef()
        // The device ID is the presence key, so the family's devices know who's here.
        send(event: "phx_join", payload: [
            "config": [
                "broadcast": ["self": false, "ack": false],
                "presence": ["key": me.uuidString.lowercased(), "enabled": true],
                "postgres_changes": [] as [Any],
                "private": false,
            ],
        ], ref: joinRef)
        loops = [
            Task { [weak self] in await self?.readLoop(socket) },
            Task { [weak self] in await self?.heartbeatLoop(socket) },
        ]
    }

    private func disconnect() {
        for loop in loops { loop.cancel() }
        loops = []
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        joined = false
        isConnected = false
        metas = [:]
        if !present.isEmpty {
            present = []
            onPresence?()
        }
    }

    /// Dropped: try again, a little later each time.
    private func dropped(_ socket: URLSessionWebSocketTask) {
        guard socket === self.socket else { return }
        disconnect()
        guard running else { return }
        attempts += 1
        let delay = [1.0, 2, 5, 10, 30][min(attempts - 1, 4)]
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: Sending

    /// Sends a message to a family device through the channel. False if it can't go now.
    @discardableResult
    func send(_ message: IntercomMessage, to peer: UUID) -> Bool {
        guard running, let sealing else { return false }
        guard joined else {
            waiting.append((peer, message))
            return true
        }
        let envelope = Envelope(from: me, to: peer, id: UUID().uuidString, at: .now, message: message)
        guard let box = try? Self.seal(envelope, with: sealing) else { return false }
        send(event: "broadcast", payload: [
            "type": "broadcast",
            "event": "m",
            "payload": ["to": peer.uuidString.lowercased(), "box": box],
        ])
        return true
    }

    private func nextRef() -> String {
        ref += 1
        return String(ref)
    }

    private func send(event: String, payload: [String: Any], ref: String? = nil, topic: String? = nil) {
        guard let socket else { return }
        var frame: [String: Any] = [
            "topic": topic ?? "realtime:\(self.topic)",
            "event": event,
            "payload": payload,
            "ref": ref ?? nextRef(),
        ]
        if topic == nil, let joinRef { frame["join_ref"] = joinRef }
        guard let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor in self?.log.notice("Intercom relay send failed: \(reason, privacy: .public)") }
        }
    }

    // MARK: Receiving

    private func readLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let text: String? = switch message {
                case let .string(text): text
                case let .data(data): String(data: data, encoding: .utf8)
                @unknown default: nil
                }
                if let text { handle(text) }
            } catch {
                if !Task.isCancelled {
                    log.notice("Intercom relay closed: \(error.localizedDescription, privacy: .public)")
                    dropped(socket)
                }
                return
            }
        }
    }

    private func heartbeatLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, socket === self.socket else { return }
            send(event: "heartbeat", payload: [:], topic: "phoenix")
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = frame["event"] as? String else { return }
        let payload = frame["payload"] as? [String: Any] ?? [:]
        switch event {
        case "phx_reply":
            guard let ref = frame["ref"] as? String, ref == joinRef else { return }
            if (payload["status"] as? String) == "ok" {
                joined = true
                isConnected = true
                attempts = 0
                send(event: "presence", payload: ["type": "presence", "event": "track", "payload": ["device": me.uuidString.lowercased()]])
                let pending = waiting
                waiting = []
                for (peer, message) in pending { send(message, to: peer) }
                log.info("Intercom relay joined")
            } else {
                log.error("Intercom relay join refused: \(String(describing: payload["response"]), privacy: .public)")
                if let socket { dropped(socket) }
            }
        case "phx_error", "phx_close":
            if let socket { dropped(socket) }
        case "presence_state":
            metas = [:]
            add(payload, sign: 1)
            presenceChanged()
        case "presence_diff":
            add(payload["joins"] as? [String: Any] ?? [:], sign: 1)
            add(payload["leaves"] as? [String: Any] ?? [:], sign: -1)
            presenceChanged()
        case "broadcast":
            guard let inner = payload["payload"] as? [String: Any],
                  let to = inner["to"] as? String, to == me.uuidString.lowercased(),
                  let box = inner["box"] as? String else { return }
            received(box)
        default:
            break
        }
    }

    private func add(_ presences: [String: Any], sign: Int) {
        for (key, value) in presences {
            guard let id = UUID(uuidString: key), id != me else { continue }
            let count = ((value as? [String: Any])?["metas"] as? [Any])?.count ?? 1
            let total = (metas[id] ?? 0) + sign * count
            metas[id] = total > 0 ? total : nil
        }
    }

    private func presenceChanged() {
        let now = Set(metas.keys)
        guard now != present else { return }
        present = now
        onPresence?()
    }

    private func received(_ box: String) {
        guard let sealing, let envelope = try? Self.open(box, with: sealing) else {
            log.notice("Intercom relay: a message that isn't the family's")
            return
        }
        guard envelope.to == me, envelope.from != me,
              abs(envelope.at.timeIntervalSinceNow) < Self.maximumAge,
              seen[envelope.id] == nil else { return }
        seen[envelope.id] = envelope.at
        if seen.count > 500 {
            let cutoff = Date.now.addingTimeInterval(-Self.maximumAge * 2)
            seen = seen.filter { $0.value > cutoff }
        }
        onMessage?(envelope.from, envelope.message)
    }
}
