import CryptoKit
import Foundation
import Network
import Observation
import OSLog
import Security
import SwiftData

/// The intercom on the home network. Every family device running Caloma advertises itself
/// with Bonjour (`_caloma-icom._tcp`, named by its `DeviceIdentity.id`) and keeps an eye out
/// for the others, so the device list knows who's reachable right now.
///
/// Connections between devices are TLS with a pre-shared key made from the family's
/// `HouseholdKey`: a device that isn't in the family can see the advertisement but can't
/// connect, and nothing on the connection can be read or changed on the network. Calls are set
/// up over it; their sound and video then go straight between the devices (`CallMedia`).
@Observable
final class IntercomService {
    static let shared = IntercomService()
    nonisolated static let serviceType = "_caloma-icom._tcp"

    /// Family devices seen on this network right now, by device ID.
    private(set) var online: Set<UUID> = []
    private(set) var isRunning = false
    /// Local Network access was turned off for Caloma in Settings.
    private(set) var networkDenied = false

    /// Every message from another device. Set by `CallCenter`.
    @ObservationIgnored var onMessage: ((UUID, IntercomMessage) -> Void)?
    /// A connection to that device dropped.
    @ObservationIgnored var onLost: ((UUID) -> Void)?
    /// Devices that just appeared on the network (a phone woken for a call). Set by `CallCenter`.
    @ObservationIgnored var onOnline: ((Set<UUID>) -> Void)?

    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "intercom")
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var endpoints: [UUID: NWEndpoint] = [:]
    @ObservationIgnored private var links: [UUID: IntercomLink] = [:]
    /// Connections that haven't said who they are yet.
    @ObservationIgnored private var strangers: [ObjectIdentifier: IntercomLink] = [:]
    /// The losing half of two connections made at once: still read (anything already sent on
    /// it arrives), never written to, closed after a few seconds.
    @ObservationIgnored private var retired: [ObjectIdentifier: IntercomLink] = [:]
    @ObservationIgnored private var parameters: NWParameters?
    @ObservationIgnored private var keyFingerprint = ""
    @ObservationIgnored private var container: ModelContainer?

    private init() {}

    var me: UUID { DeviceIdentity.id }

    // MARK: Starting and stopping

    /// Starts advertising and looking (again, if the family's key changed). Called as Caloma
    /// starts and each time it comes back to the front.
    func start(with container: ModelContainer) {
        self.container = container
        let context = container.mainContext
        DeviceRegistry.register(in: context)
        guard let key = HouseholdKey.current(in: context) else {
            log.info("Intercom waiting for the family's first sync")
            return
        }
        // So calls can wake this device when Caloma isn't open.
        IntercomPush.shared.register()
        let fingerprint = HouseholdKey.fingerprint(of: key)
        if isRunning, fingerprint == keyFingerprint { return }
        stop()
        keyFingerprint = fingerprint
        let parameters = Self.parameters(psk: HouseholdKey.connectionKey(from: key))
        self.parameters = parameters
        startListener(parameters)
        startBrowser()
        isRunning = true
        log.info("Intercom started (key \(fingerprint, privacy: .public))")
    }

    /// Stops everything (Caloma went to the background with no call going).
    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for link in links.values { link.close() }
        for link in strangers.values { link.close() }
        for link in retired.values { link.close() }
        links = [:]
        strangers = [:]
        retired = [:]
        endpoints = [:]
        online = []
        isRunning = false
    }

    private func startListener(_ parameters: NWParameters) {
        do {
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: me.uuidString, type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case let .failed(error):
                        self.log.error("Intercom listener failed: \(error.localizedDescription, privacy: .public)")
                        self.listener?.cancel()
                        self.listener = nil
                        // Try again in a moment (the network may have changed).
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            if self.isRunning, self.listener == nil, let parameters = self.parameters { self.startListener(parameters) }
                        }
                    case let .waiting(error):
                        self.noteWaiting(error)
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log.error("Couldn't start the intercom listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case let .waiting(error), let .failed(error):
                    self.noteWaiting(error)
                case .ready:
                    self.networkDenied = false
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func noteWaiting(_ error: NWError) {
        // Local Network turned off for Caloma shows up as a DNS-SD policy error.
        if case let .dns(code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
            networkDenied = true
        }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var endpoints: [UUID: NWEndpoint] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, let id = UUID(uuidString: name), id != me else { continue }
            endpoints[id] = result.endpoint
        }
        self.endpoints = endpoints
        let appeared = Set(endpoints.keys).subtracting(online)
        online = Set(endpoints.keys)
        if !appeared.isEmpty { onOnline?(appeared) }
    }

    // MARK: Connections

    /// Sends a message to another family device, connecting first if need be.
    func send(_ message: IntercomMessage, to peer: UUID) {
        if let link = links[peer] {
            link.send(message)
            return
        }
        guard let endpoint = endpoints[peer], let parameters else {
            log.notice("Can't reach \(peer.uuidString, privacy: .public) on this network")
            // Later, not in the middle of whatever is sending (a call still dialing).
            Task { self.onLost?(peer) }
            return
        }
        let link = IntercomLink(connection: NWConnection(to: endpoint, using: parameters), outgoing: true)
        link.peer = peer
        links[peer] = link
        wire(link)
        link.start(hello: .hello(device: me, name: myName))
        link.send(message)
    }

    /// Whether a device can be reached right now.
    func isOnline(_ id: UUID) -> Bool { online.contains(id) }

    private func accept(_ connection: NWConnection) {
        let link = IntercomLink(connection: connection, outgoing: false)
        strangers[ObjectIdentifier(link)] = link
        wire(link)
        link.start(hello: .hello(device: me, name: myName))
    }

    private func wire(_ link: IntercomLink) {
        link.onMessage = { [weak self] link, message in self?.received(message, on: link) }
        link.onClose = { [weak self] link in self?.closed(link) }
    }

    private func received(_ message: IntercomMessage, on link: IntercomLink) {
        if case let .hello(device, _) = message {
            identified(link, as: device)
            return
        }
        guard let peer = link.peer else { return }
        onMessage?(peer, message)
    }

    private func identified(_ link: IntercomLink, as device: UUID) {
        strangers[ObjectIdentifier(link)] = nil
        guard device != me else { link.close(); return }
        link.peer = device
        if let existing = links[device], existing !== link {
            // Both ends dialed at once: keep the connection the device with the lower ID
            // started, the same choice on both ends.
            let starter = me.uuidString < device.uuidString ? me : device
            let keepNew = (link.outgoing ? me : device) == starter
            if keepNew {
                links[device] = link
                existing.handOver(to: link)
                retire(existing)
            } else {
                retire(link)
            }
        } else {
            links[device] = link
        }
    }

    private func retire(_ link: IntercomLink) {
        let key = ObjectIdentifier(link)
        retired[key] = link
        Task {
            try? await Task.sleep(for: .seconds(5))
            self.retired[key]?.close()
        }
    }

    private func closed(_ link: IntercomLink) {
        strangers[ObjectIdentifier(link)] = nil
        retired[ObjectIdentifier(link)] = nil
        guard let peer = link.peer, links[peer] === link else { return }
        links[peer] = nil
        onLost?(peer)
    }

    private var myName: String {
        guard let context = container?.mainContext else { return DeviceKind.current.label }
        return DeviceRegistry.register(in: context).displayName
    }

    // MARK: TLS with the family's key

    nonisolated static func parameters(psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("caloma-intercom".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 6
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // The home network only: no Wi-Fi Aware or AWDL between devices.
        parameters.includePeerToPeer = false
        return parameters
    }
}

/// One connection to another family device: framed JSON messages each way.
final class IntercomLink {
    let connection: NWConnection
    /// This device dialed it.
    let outgoing: Bool
    var peer: UUID?
    var onMessage: ((IntercomLink, IntercomMessage) -> Void)?
    var onClose: ((IntercomLink) -> Void)?

    private var ready = false
    private var closed = false
    private var waiting: [IntercomMessage] = []
    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "intercom")

    init(connection: NWConnection, outgoing: Bool) {
        self.connection = connection
        self.outgoing = outgoing
    }

    func start(hello: IntercomMessage) {
        waiting.insert(hello, at: 0)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready = true
                    let queued = self.waiting
                    self.waiting = []
                    for message in queued { self.write(message) }
                    self.readHeader()
                case let .failed(error):
                    self.log.notice("Intercom connection failed: \(error.localizedDescription, privacy: .public)")
                    self.close()
                case let .waiting(error):
                    // A TLS failure (the other device has a different family key) or no route.
                    self.log.notice("Intercom connection waiting: \(error.localizedDescription, privacy: .public)")
                    self.close()
                case .cancelled:
                    self.close()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: IntercomMessage) {
        guard !closed else { return }
        if ready { write(message) } else { waiting.append(message) }
    }

    /// Anything still queued here goes out on the connection that replaced this one.
    func handOver(to other: IntercomLink) {
        for message in waiting where message.call != nil { other.send(message) }
        waiting = []
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(self)
    }

    private func write(_ message: IntercomMessage) {
        guard let data = try? IntercomFrame.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.log.notice("Intercom send failed: \(error.localizedDescription, privacy: .public)")
                self?.close()
            }
        })
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard error == nil, let data, let length = IntercomFrame.length(fromHeader: data) else {
                    self.close()
                    return
                }
                self.readBody(length)
                _ = isComplete
            }
        }
    }

    private func readBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard error == nil, let data, data.count == length else {
                    self.close()
                    return
                }
                if let message = try? IntercomFrame.decode(data) {
                    self.onMessage?(self, message)
                }
                self.readHeader()
            }
        }
    }
}
