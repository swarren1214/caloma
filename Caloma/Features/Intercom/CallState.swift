import Foundation

/// Where a call is, and what to do next, with nothing else in it: no network, no camera, no
/// clock. `CallCenter` feeds it what happened (`CallEvent`) and carries out what it says
/// (`CallEffect`), so the whole flow can be tested on its own (CallStateTests).
///
/// One call at a time. The caller rings one device or several (all the boards); everyone who
/// picks up joins, each with their own connection to the caller. A device on a call answers
/// any other ring with "busy".
nonisolated struct CallState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// We rang; nobody's picked up yet.
        case calling
        /// Someone is ringing us.
        case ringing
        /// Talking with at least one device.
        case live
        /// Over, showing why for a moment ("No answer").
        case ended(String)
    }

    var phase: Phase = .idle
    var call: UUID?
    var isCaller = false
    /// The caller asked for video (shown on the ringing screen).
    var offeredVideo = false
    /// Our camera is on.
    var video = false
    /// Who rang us.
    var caller: UUID?
    /// Still ringing (the caller's side).
    var ringingPeers: Set<UUID> = []
    /// In the call.
    var peers: Set<UUID> = []
    /// Names to show, by device.
    var names: [UUID: String] = [:]

    var isIdle: Bool { phase == .idle }
    var isBusy: Bool {
        switch phase {
        case .calling, .ringing, .live: true
        case .idle, .ended: false
        }
    }

    /// How long a ring lasts before it's a missed call.
    static let ringSeconds: Double = 30
    /// How long "No answer" stays up.
    static let endedSeconds: Double = 2.5

    mutating func apply(_ event: CallEvent) -> [CallEffect] {
        switch event {
        case let .dial(call, targets, video, me, myName):
            return dial(call: call, targets: targets, video: video, me: me, myName: myName)
        case let .received(message, peer):
            return received(message, from: peer)
        case let .answer(video):
            return answer(video: video)
        case .decline:
            return decline()
        case .hangUp:
            return hangUp()
        case let .timedOut(call):
            return timedOut(call)
        case let .lost(peer):
            return left(peer, reason: "Couldn't reach \(name(peer))")
        case let .mediaFailed(peer):
            return left(peer, reason: "Lost the connection")
        case .cleared:
            if case .ended = phase { self = CallState() }
            return []
        }
    }

    func name(_ peer: UUID) -> String { names[peer] ?? "that device" }

    // MARK: Calling out

    private mutating func dial(call: UUID, targets: [UUID: String], video: Bool, me: UUID, myName: String) -> [CallEffect] {
        guard !isBusy, !targets.isEmpty else { return [] }
        self = CallState()
        phase = .calling
        self.call = call
        isCaller = true
        self.video = video
        offeredVideo = video
        names = targets
        ringingPeers = Set(targets.keys)
        var effects: [CallEffect] = [.startMedia(video: video)]
        let everyone = targets.keys.sorted { $0.uuidString < $1.uuidString }
        for peer in everyone {
            let others = everyone.filter { $0 != peer }
            effects.append(.send(.ring(call: call, from: me, name: myName, video: video, group: others), to: peer))
        }
        effects.append(.scheduleTimeout(call: call))
        return effects
    }

    // MARK: From the other devices

    private mutating func received(_ message: IntercomMessage, from peer: UUID) -> [CallEffect] {
        switch message {
        case let .ring(call, _, name, video, _):
            if isBusy {
                return self.call == call ? [] : [.send(.decline(call: call, reason: .busy), to: peer)]
            }
            self = CallState()
            phase = .ringing
            self.call = call
            caller = peer
            offeredVideo = video
            names[peer] = name
            return [.ring(true), .scheduleTimeout(call: call)]

        case let .accept(call, _):
            if call == self.call, peers.contains(peer) { return [] }
            guard call == self.call, isCaller, ringingPeers.contains(peer) else {
                // Picked up after we'd given up: tell them it's over.
                return call == self.call || !isBusy ? [.send(.hangUp(call: call), to: peer)] : []
            }
            ringingPeers.remove(peer)
            peers.insert(peer)
            phase = .live
            return [.connect(peer, offer: true)]

        case let .decline(call, reason):
            guard call == self.call, isCaller, ringingPeers.contains(peer) else { return [] }
            ringingPeers.remove(peer)
            return endIfEmpty(reason: everyoneDeclined(reason))

        case let .hangUp(call):
            guard call == self.call else { return [] }
            return left(peer, reason: "Call ended")

        case let .offer(call, _), let .answer(call, _), let .candidate(call, _, _, _), let .camera(call, _):
            guard call == self.call, peers.contains(peer) else { return [] }
            return [.media(message, from: peer)]

        case .hello, .find:
            return []
        }
    }

    /// One device left (hung up, dropped off the network, or its connection failed).
    private mutating func left(_ peer: UUID, reason: String) -> [CallEffect] {
        switch phase {
        case .ringing where peer == caller:
            // They gave up before anyone answered.
            let name = name(peer)
            self = CallState()
            return [.ring(false), .missed(from: peer, name: name)]
        case .calling, .live:
            if ringingPeers.remove(peer) != nil {
                return endIfEmpty(reason: reason)
            }
            guard peers.remove(peer) != nil else { return [] }
            var effects: [CallEffect] = [.disconnect(peer)]
            if !isCaller {
                // The caller left: that's the call.
                effects += end(reason: "Call ended")
            } else {
                effects += endIfEmpty(reason: "Call ended")
            }
            return effects
        default:
            return []
        }
    }

    private func everyoneDeclined(_ reason: DeclineReason) -> String {
        names.count == 1 ? "\(names.values.first ?? "") · \(reason.sentence)" : reason.sentence
    }

    private mutating func endIfEmpty(reason: String) -> [CallEffect] {
        guard ringingPeers.isEmpty, peers.isEmpty else { return [] }
        return end(reason: reason)
    }

    private mutating func end(reason: String) -> [CallEffect] {
        var effects: [CallEffect] = []
        for peer in peers.sorted(by: { $0.uuidString < $1.uuidString }) { effects.append(.disconnect(peer)) }
        let keepNames = names
        self = CallState()
        names = keepNames
        phase = .ended(reason)
        effects += [.stopMedia, .scheduleClear]
        return effects
    }

    // MARK: Things done here

    private mutating func answer(video: Bool) -> [CallEffect] {
        guard phase == .ringing, let call, let caller else { return [] }
        phase = .live
        self.video = video
        peers = [caller]
        return [.ring(false), .startMedia(video: video), .send(.accept(call: call, video: video), to: caller), .connect(caller, offer: false)]
    }

    private mutating func decline() -> [CallEffect] {
        guard phase == .ringing, let call, let caller else { return [] }
        self = CallState()
        return [.ring(false), .send(.decline(call: call, reason: .declined), to: caller)]
    }

    private mutating func hangUp() -> [CallEffect] {
        switch phase {
        case .ringing:
            return decline()
        case .calling, .live:
            guard let call else { return [] }
            var effects: [CallEffect] = []
            for peer in ringingPeers.union(peers).sorted(by: { $0.uuidString < $1.uuidString }) {
                effects.append(.send(.hangUp(call: call), to: peer))
            }
            for peer in peers.sorted(by: { $0.uuidString < $1.uuidString }) { effects.append(.disconnect(peer)) }
            effects.append(.stopMedia)
            self = CallState()
            return effects
        case .ended:
            self = CallState()
            return []
        case .idle:
            return []
        }
    }

    private mutating func timedOut(_ call: UUID) -> [CallEffect] {
        guard call == self.call else { return [] }
        switch phase {
        case .ringing:
            guard let caller else { return [] }
            let name = name(caller)
            self = CallState()
            return [.ring(false), .missed(from: caller, name: name), .send(.decline(call: call, reason: .noAnswer), to: caller)]
        case .calling, .live:
            guard !ringingPeers.isEmpty else { return [] }
            let effects = ringingPeers.sorted(by: { $0.uuidString < $1.uuidString }).map { CallEffect.send(.hangUp(call: call), to: $0) }
            ringingPeers = []
            return effects + endIfEmpty(reason: "No answer")
        default:
            return []
        }
    }
}

nonisolated enum CallEvent: Equatable, Sendable {
    /// Ring these devices (ID → name to show).
    case dial(call: UUID, to: [UUID: String], video: Bool, me: UUID, myName: String)
    case received(IntercomMessage, from: UUID)
    /// Picked up here.
    case answer(video: Bool)
    case decline
    case hangUp
    /// A ring ran out.
    case timedOut(call: UUID)
    /// The network connection to that device dropped.
    case lost(UUID)
    /// Sound and video to that device stopped and couldn't recover.
    case mediaFailed(UUID)
    /// The "ended" moment is over.
    case cleared
}

nonisolated enum CallEffect: Equatable, Sendable {
    case send(IntercomMessage, to: UUID)
    /// Start sound and video to that device; the caller makes the offer.
    case connect(UUID, offer: Bool)
    case disconnect(UUID)
    /// Microphone (and camera) on.
    case startMedia(video: Bool)
    case stopMedia
    /// For WebRTC: an offer, answer, network candidate or camera change from that device.
    case media(IntercomMessage, from: UUID)
    /// The ringtone.
    case ring(Bool)
    case missed(from: UUID, name: String)
    case scheduleTimeout(call: UUID)
    case scheduleClear
}
