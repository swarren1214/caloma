import AudioToolbox
import AVFoundation
import Observation
import OSLog
import SwiftData
import UIKit

/// The intercom's calls on this device: rings, answers and hangs up, and carries out what
/// `CallState` decides (messages to other devices, the ringtone, starting and stopping sound
/// and video). Its screens show in their own window above everything (`CallWindow`), so a call
/// comes through over the Family Board, Kid View or a sheet alike.
@Observable
final class CallCenter {
    static let shared = CallCenter()

    private(set) var state = CallState()
    let media = CallMedia()
    /// Calls nobody answered here, newest first (kept while Caloma is open).
    private(set) var missed: [MissedCall] = []
    /// A device name to flash full screen ("Kitchen Board"), from Find in Family › Devices.
    private(set) var flash: String?
    /// When the call connected, for the timer.
    private(set) var connectedAt: Date?
    /// Why a call couldn't start ("Caloma needs the microphone…").
    var problem: String?

    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "intercom")
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var timeouts: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var clearing: Task<Void, Never>?
    @ObservationIgnored private var ringing: Task<Void, Never>?
    @ObservationIgnored private var keepingAwake: Task<Void, Never>?
    @ObservationIgnored private var flashing: Task<Void, Never>?
    @ObservationIgnored private var tookKioskCamera = false
    @ObservationIgnored private var idleTimerWasDisabled: Bool?
    /// Caller's side: devices rung by push (`IntercomPush`) that haven't come onto the network
    /// yet. Not being reachable is expected for them while they wake up.
    @ObservationIgnored private var waking: Set<UUID> = []
    /// Caller's side: the ring for each device, sent again once a waking one shows up.
    @ObservationIgnored private var rings: [UUID: IntercomMessage] = [:]
    /// Answering side: the call that woke this device, before its ring comes over the network.
    @ObservationIgnored private var woken: WokenRing?
    /// Answered on the lock screen before that ring came.
    @ObservationIgnored private var answerWhenRung = false
    /// Answered in Caloma's own screen while the system shows the call too: the camera choice,
    /// for when the system passes the answer back.
    @ObservationIgnored private var answerVideo: Bool?

    private var service: IntercomService { IntercomService.shared }

    private init() {}

    func start(with container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        service.onMessage = { [weak self] peer, message in self?.received(message, from: peer) }
        service.onLost = { [weak self] peer in
            guard let self else { return }
            // Still waking up from a push: not there yet isn't gone.
            if waking.contains(peer), state.ringingPeers.contains(peer) { return }
            apply(.lost(peer))
        }
        service.onOnline = { [weak self] peers in self?.cameOnline(peers) }
        media.onSignal = { message, peer in IntercomService.shared.send(message, to: peer) }
        media.onFailed = { [weak self] peer in self?.apply(.mediaFailed(peer)) }
    }

    // MARK: Things people do

    /// Rings these devices. With several (all the boards), everyone who answers joins.
    func call(_ devices: [HouseDevice], video: Bool) async {
        guard !state.isBusy else { return }
        let targets = devices.filter { $0.id != DeviceIdentity.id }
        guard !targets.isEmpty else { return }
        guard let video = await permission(video: video) else { return }
        var names: [UUID: String] = [:]
        for device in targets { names[device.id] = device.displayName }
        let call = UUID()
        // Devices not on the network right now (locked, or Caloma closed) get woken by push.
        let asleep = targets.map(\.id).filter { !service.isOnline($0) }
        waking = Set(asleep)
        let name = myName
        apply(.dial(call: call, to: names, video: video, me: DeviceIdentity.id, myName: name))
        guard !asleep.isEmpty else { return }
        Task {
            let reached = await IntercomPush.shared.ring(call: call, name: name, video: video, to: asleep)
            // Ones the server couldn't wake won't answer: as if unreachable.
            for peer in asleep where !reached.contains(peer) && !service.isOnline(peer) {
                waking.remove(peer)
                if state.call == call { apply(.lost(peer)) }
            }
        }
    }

    /// Devices that just showed up on the network: ring the ones being woken for this call.
    private func cameOnline(_ peers: Set<UUID>) {
        guard state.isCaller, state.phase == .calling || state.phase == .live else { return }
        for peer in peers where waking.contains(peer) && state.ringingPeers.contains(peer) {
            if let ring = rings[peer] { service.send(ring, to: peer) }
        }
    }

    /// Calls back a missed call.
    func callBack(_ call: MissedCall) async {
        guard let device = device(call.from) else { return }
        missed.removeAll { $0.id == call.id }
        await self.call([device], video: true)
    }

    func answer(video: Bool) async {
        guard state.phase == .ringing else { return }
        if let call = state.call, IntercomCallKit.showing == call {
            // The system shows this call too: answer there, so its screen and sound follow.
            answerVideo = video
            IntercomCallKit.shared.requestAnswer(call)
            return
        }
        await answerHere(video: video)
    }

    func decline() { apply(.decline) }

    // MARK: Calls that woke this device (IntercomCallKit)

    var isWoken: Bool { woken != nil }

    /// A push woke this device for a call: get onto the network so the caller can ring.
    func woke(for ring: WokenRing) {
        woken = ring
        answerWhenRung = false
        answerVideo = nil
        if let container = AppRouter.shared.container {
            start(with: container)
            IntercomService.shared.start(with: container)
        }
    }

    /// Answered on the system's call screen (or passed back from Caloma's own).
    func answerFromCallKit(_ call: UUID) {
        if state.phase == .ringing, state.call == call {
            let video = answerVideo ?? (state.offeredVideo && UIApplication.shared.applicationState == .active)
            answerVideo = nil
            Task { await answerHere(video: video) }
        } else if woken?.call == call {
            // The ring hasn't come over the network yet: answer as soon as it does.
            answerWhenRung = true
        }
    }

    /// Declined or hung up on the system's call screen.
    func endFromCallKit(_ call: UUID) {
        if state.call == call, state.isBusy {
            apply(.hangUp)
        } else if let woken, woken.call == call {
            service.send(.decline(call: call, reason: .declined), to: woken.from)
        }
        if woken?.call == call {
            woken = nil
            answerWhenRung = false
        }
        answerVideo = nil
    }

    /// Answers the ringing call here: microphone (and camera) permission first.
    private func answerHere(video: Bool) async {
        guard state.phase == .ringing else { return }
        guard let video = await permission(video: video) else {
            apply(.decline)
            return
        }
        guard state.phase == .ringing else { return }
        apply(.answer(video: video))
    }
    func hangUp() { apply(.hangUp) }

    func toggleMute() { media.setMuted(!media.muted) }
    func toggleSpeaker() { media.setSpeaker(!media.speakerOn) }
    func flipCamera() { media.flipCamera() }

    func toggleCamera() async {
        if media.cameraOn {
            media.setCamera(false)
        } else if await FaceCamera.requestAccess() {
            media.setCamera(true)
        } else {
            problem = "Caloma needs the camera for video. Turn it on in Settings › Caloma."
        }
    }

    /// Flashes the device's name on its screen, to tell which board is which.
    func find(_ device: HouseDevice) {
        service.send(.find(name: device.displayName), to: device.id)
    }

    func forget(_ call: MissedCall) {
        missed.removeAll { $0.id == call.id }
    }

    // MARK: Messages

    private func received(_ message: IntercomMessage, from peer: UUID) {
        switch message {
        case let .find(name):
            show(flash: name)
        case let .ring(call, _, _, _, _) where !takesCalls:
            service.send(.decline(call: call, reason: .off), to: peer)
        case let .hangUp(call) where woken?.call == call && state.call != call:
            // The caller gave up before their ring got here.
            woken = nil
            answerWhenRung = false
            IntercomCallKit.shared.end(call, reason: .remoteEnded)
        default:
            apply(.received(message, from: peer))
            if case let .ring(call, _, _, _, _) = message, woken?.call == call, answerWhenRung, state.phase == .ringing {
                answerWhenRung = false
                answerFromCallKit(call)
            }
        }
    }

    private func apply(_ event: CallEvent) {
        let before = state.phase
        let call = state.call
        let effects = state.apply(event)
        for effect in effects { run(effect) }
        if state.phase != before { phaseChanged(from: before) }
        // A call the system is showing ended here: take its screen down too.
        if let call, IntercomCallKit.showing == call, state.call != call || !state.isBusy {
            if woken?.call == call { woken = nil }
            IntercomCallKit.shared.end(call, reason: before == .ringing && event != .decline ? .unanswered : .remoteEnded)
        }
    }

    private func run(_ effect: CallEffect) {
        switch effect {
        case let .send(message, peer):
            if case .ring = message { rings[peer] = message }
            service.send(message, to: peer)
        case let .connect(peer, offer):
            media.connect(peer, offer: offer)
        case let .disconnect(peer):
            media.disconnect(peer)
        case let .startMedia(video):
            takeKioskCamera()
            media.call = state.call
            media.start(video: video)
        case .stopMedia:
            media.stop()
            giveBackKioskCamera()
        case let .media(message, peer):
            media.handle(message, from: peer)
        case let .ring(on):
            ring(on)
        case let .missed(peer, name):
            missed.insert(MissedCall(from: peer, name: name, at: .now), at: 0)
            if missed.count > 10 { missed.removeLast(missed.count - 10) }
        case let .scheduleTimeout(call):
            timeouts[call]?.cancel()
            timeouts[call] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(CallState.ringSeconds))
                guard !Task.isCancelled else { return }
                self?.timeouts[call] = nil
                self?.apply(.timedOut(call: call))
            }
        case .scheduleClear:
            clearing?.cancel()
            clearing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(CallState.endedSeconds))
                guard !Task.isCancelled else { return }
                self?.apply(.cleared)
            }
        }
    }

    private func phaseChanged(from before: CallState.Phase) {
        switch state.phase {
        case .live:
            if before != .live { connectedAt = .now }
        case .idle:
            connectedAt = nil
            for task in timeouts.values { task.cancel() }
            timeouts = [:]
            ring(false)
            waking = []
            rings = [:]
        default:
            break
        }
        if state.isBusy { keepAwake() } else { stopKeepingAwake() }
        CallWindow.shared.update()
    }

    // MARK: The device around the call

    /// Microphone (and camera) permission. Nil when there's no microphone; false video when
    /// only the camera was refused.
    private func permission(video: Bool) async -> Bool? {
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Caloma needs the microphone for calls. Turn it on in Settings › Caloma."
            return nil
        }
        guard video else { return false }
        return await FaceCamera.requestAccess()
    }

    /// The Family Board's camera watches for faces and movement; a call needs it instead.
    private func takeKioskCamera() {
        guard !tookKioskCamera else { return }
        tookKioskCamera = true
        FaceRecognizer.shared.pause(true)
        KioskPresence.shared.pause(true)
    }

    private func giveBackKioskCamera() {
        guard tookKioskCamera else { return }
        tookKioskCamera = false
        Task {
            // A moment for the call's camera to let go.
            try? await Task.sleep(for: .milliseconds(600))
            FaceRecognizer.shared.pause(false)
            KioskPresence.shared.pause(false)
        }
    }

    private func ring(_ on: Bool) {
        ringing?.cancel()
        ringing = nil
        guard on else { return }
        // The system's call screen rings for a call that woke this device.
        if let call = state.call, IntercomCallKit.showing == call { return }
        // A ring wakes a dimmed board or its screensaver.
        KioskPresence.shared.touched()
        ringing = Task {
            while !Task.isCancelled {
                AudioServicesPlayAlertSound(SystemSoundID(1005))
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    /// No dimming, screensaver or auto-lock while a call is ringing or going.
    private func keepAwake() {
        if idleTimerWasDisabled == nil {
            idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        guard keepingAwake == nil else { return }
        keepingAwake = Task {
            while !Task.isCancelled {
                KioskPresence.shared.touched()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func stopKeepingAwake() {
        keepingAwake?.cancel()
        keepingAwake = nil
        if let was = idleTimerWasDisabled {
            UIApplication.shared.isIdleTimerDisabled = was
            idleTimerWasDisabled = nil
        }
    }

    private func show(flash name: String) {
        KioskPresence.shared.touched()
        flash = name
        CallWindow.shared.update()
        flashing?.cancel()
        flashing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.flash = nil
            CallWindow.shared.update()
        }
    }

    func dismissFlash() {
        flashing?.cancel()
        flash = nil
        CallWindow.shared.update()
    }

    // MARK: The family's devices

    private var context: ModelContext? { container?.mainContext }

    private var thisDevice: HouseDevice? {
        context.map { DeviceRegistry.register(in: $0) }
    }

    private var takesCalls: Bool { thisDevice?.takesCalls ?? true }

    /// What the other end sees: a board's name, or the person who carries this phone.
    private var myName: String {
        guard let context, let device = thisDevice else { return DeviceKind.current.label }
        if !device.isBoard, let owner = device.ownerID {
            var descriptor = FetchDescriptor<Member>(predicate: #Predicate { $0.id == owner })
            descriptor.fetchLimit = 1
            if let person = (try? context.fetch(descriptor))?.first, !person.name.isEmpty { return person.name }
        }
        return device.displayName
    }

    func device(_ id: UUID) -> HouseDevice? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<HouseDevice>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

struct MissedCall: Identifiable, Equatable {
    let id = UUID()
    let from: UUID
    let name: String
    let at: Date
}
