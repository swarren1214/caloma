import AVFoundation
import Observation
import OSLog
import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif

/// A call's sound and video, over WebRTC: one connection to each device in the call, sharing
/// this device's microphone and camera. The intercom's own connection carries the setup
/// (offers, answers and network candidates); the media then goes straight between the
/// devices, encrypted with DTLS-SRTP. On the home network nothing passes through a server.
///
/// Builds without the WebRTC package too (calls ring and connect, but carry no sound or
/// video), so the project still builds until it's added in Xcode.
@Observable
final class CallMedia {
    enum Link: Equatable {
        case connecting
        case connected
        case failed
    }

    private(set) var links: [UUID: Link] = [:]
    private(set) var cameraOn = false
    private(set) var muted = false
    private(set) var speakerOn = true
    private(set) var frontCamera = true
    /// Whose cameras are on at the other end.
    private(set) var remoteCamera: [UUID: Bool] = [:]
    /// Changes whenever a remote video track arrives or goes, so the videos redraw.
    private(set) var remoteVideoVersion = 0

    /// Setup to send to a device in the call (offers, answers, candidates, camera changes).
    @ObservationIgnored var onSignal: ((IntercomMessage, UUID) -> Void)?
    /// The connection to a device failed and didn't come back.
    @ObservationIgnored var onFailed: ((UUID) -> Void)?
    @ObservationIgnored var call: UUID?
    /// CallKit owns the sound for a call it shows (one that woke a locked phone): it turns the
    /// audio session on and off, and WebRTC waits for it (`IntercomCallKit`).
    @ObservationIgnored var callKitAudio = false {
        didSet {
            guard callKitAudio != oldValue else { return }
            #if canImport(WebRTC)
            let session = RTCAudioSession.sharedInstance()
            session.useManualAudio = callKitAudio
            session.isAudioEnabled = !callKitAudio
            #endif
        }
    }

    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "intercom")
    @ObservationIgnored private var started = false

    static var isAvailable: Bool {
        #if canImport(WebRTC)
        true
        #else
        false
        #endif
    }

    #if canImport(WebRTC)
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    @ObservationIgnored private var peers: [UUID: PeerLink] = [:]
    /// Candidates that came before the other end's description; added once it's set.
    @ObservationIgnored private var early: [UUID: [RTCIceCandidate]] = [:]
    @ObservationIgnored private var described: Set<UUID> = []
    @ObservationIgnored private var audioTrack: RTCAudioTrack?
    @ObservationIgnored private(set) var localVideo: RTCVideoTrack?
    @ObservationIgnored private var capturer: RTCCameraVideoCapturer?
    @ObservationIgnored private(set) var remoteVideo: [UUID: RTCVideoTrack] = [:]
    @ObservationIgnored private var dropTimers: [UUID: Task<Void, Never>] = [:]
    #endif

    // MARK: Starting and stopping

    /// Microphone on (and the camera, for video). Safe to call again.
    func start(video: Bool) {
        #if canImport(WebRTC)
        if !started {
            started = true
            configureAudio()
            let factory = Self.factory
            let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            audioTrack = factory.audioTrack(with: audioSource, trackId: "caloma-audio")
            let videoSource = factory.videoSource()
            capturer = RTCCameraVideoCapturer(delegate: videoSource)
            localVideo = factory.videoTrack(with: videoSource, trackId: "caloma-video")
        }
        #endif
        started = true
        muted = false
        setCamera(video)
    }

    /// Everything off and every connection closed.
    func stop() {
        #if canImport(WebRTC)
        for id in Array(peers.keys) { disconnect(id) }
        capturer?.stopCapture()
        capturer = nil
        localVideo = nil
        audioTrack = nil
        early = [:]
        described = []
        remoteVideo = [:]
        if !callKitAudio {
            let session = RTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            try? session.setActive(false)
            session.unlockForConfiguration()
        }
        #endif
        started = false
        cameraOn = false
        muted = false
        speakerOn = true
        frontCamera = true
        links = [:]
        remoteCamera = [:]
        remoteVideoVersion += 1
        call = nil
    }

    // MARK: Controls

    /// CallKit turned the call's audio session on: sound can start.
    func callKitActivated(_ audioSession: AVAudioSession) {
        #if canImport(WebRTC)
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidActivate(audioSession)
        session.isAudioEnabled = true
        #endif
    }

    func callKitDeactivated(_ audioSession: AVAudioSession) {
        #if canImport(WebRTC)
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidDeactivate(audioSession)
        session.isAudioEnabled = false
        #endif
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        #if canImport(WebRTC)
        audioTrack?.isEnabled = !muted
        #endif
    }

    func setCamera(_ on: Bool) {
        cameraOn = on
        #if canImport(WebRTC)
        localVideo?.isEnabled = on
        if on { startCapture() } else { capturer?.stopCapture() }
        #endif
        if let call {
            for peer in links.keys { onSignal?(.camera(call: call, on: on), peer) }
        }
    }

    func flipCamera() {
        frontCamera.toggle()
        #if canImport(WebRTC)
        if cameraOn { startCapture() }
        #endif
    }

    func setSpeaker(_ on: Bool) {
        speakerOn = on
        #if canImport(WebRTC)
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
        session.unlockForConfiguration()
        #endif
    }

    // MARK: Connections

    /// A connection to one device in the call. The caller makes the offer.
    func connect(_ peer: UUID, offer: Bool) {
        links[peer] = .connecting
        #if canImport(WebRTC)
        guard peers[peer] == nil else { return }
        let configuration = RTCConfiguration()
        // The home network: the devices' own addresses are enough. Calls over the internet add
        // STUN and TURN servers here (see the intercom doc, Phase 4).
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.bundlePolicy = .maxBundle
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        let link = PeerLink(peer: peer, owner: self)
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: link) else {
            log.error("Couldn't make a WebRTC connection")
            links[peer] = .failed
            onFailed?(peer)
            return
        }
        link.connection = connection
        peers[peer] = link
        if let audioTrack { connection.add(audioTrack, streamIds: ["caloma"]) }
        if let localVideo { connection.add(localVideo, streamIds: ["caloma"]) }
        if offer {
            link.makeOffer { [weak self] sdp in
                guard let self, let sdp, let call = self.call else { return }
                self.onSignal?(.offer(call: call, sdp: sdp), peer)
            }
        }
        #endif
    }

    func disconnect(_ peer: UUID) {
        links[peer] = nil
        remoteCamera[peer] = nil
        #if canImport(WebRTC)
        dropTimers[peer]?.cancel()
        dropTimers[peer] = nil
        peers[peer]?.connection?.close()
        peers[peer] = nil
        early[peer] = nil
        described.remove(peer)
        if remoteVideo.removeValue(forKey: peer) != nil { remoteVideoVersion += 1 }
        #endif
    }

    /// An offer, answer, candidate or camera change from a device in the call.
    func handle(_ message: IntercomMessage, from peer: UUID) {
        switch message {
        case let .camera(_, on):
            remoteCamera[peer] = on
        #if canImport(WebRTC)
        case let .offer(call, sdp):
            guard let link = peers[peer] else { return }
            link.setRemote(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] ok in
                guard let self, ok else { return }
                self.described.insert(peer)
                self.addEarlyCandidates(for: peer)
                link.makeAnswer { [weak self] answer in
                    guard let self, let answer else { return }
                    self.onSignal?(.answer(call: call, sdp: answer), peer)
                }
            }
        case let .answer(_, sdp):
            guard let link = peers[peer] else { return }
            link.setRemote(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] ok in
                guard let self, ok else { return }
                self.described.insert(peer)
                self.addEarlyCandidates(for: peer)
            }
        case let .candidate(_, sdp, mid, index):
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
            if described.contains(peer), let link = peers[peer] {
                link.add(candidate)
            } else {
                early[peer, default: []].append(candidate)
            }
        #endif
        default:
            break
        }
    }

    #if canImport(WebRTC)
    private func addEarlyCandidates(for peer: UUID) {
        guard let link = peers[peer] else { return }
        for candidate in early[peer] ?? [] { link.add(candidate) }
        early[peer] = nil
    }

    // Called by PeerLink, on the main actor.

    fileprivate func generated(sdp: String, mid: String?, index: Int32, for peer: UUID) {
        guard let call, peers[peer] != nil else { return }
        onSignal?(.candidate(call: call, sdp: sdp, mid: mid, index: index), peer)
    }

    fileprivate func received(video track: RTCVideoTrack, from peer: UUID) {
        remoteVideo[peer] = track
        remoteVideoVersion += 1
    }

    fileprivate func changed(_ state: RTCIceConnectionState, for peer: UUID) {
        guard peers[peer] != nil else { return }
        switch state {
        case .connected, .completed:
            dropTimers[peer]?.cancel()
            dropTimers[peer] = nil
            if links[peer] != .connected {
                links[peer] = .connected
                // Tell them whether to show our video or our name.
                if let call { onSignal?(.camera(call: call, on: cameraOn), peer) }
            }
        case .disconnected:
            // Wi-Fi blips: give it a few seconds to come back before calling it lost.
            dropTimers[peer]?.cancel()
            dropTimers[peer] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, let self, self.links[peer] != nil else { return }
                self.links[peer] = .failed
                self.onFailed?(peer)
            }
        case .failed:
            links[peer] = .failed
            onFailed?(peer)
        default:
            break
        }
    }

    private func startCapture() {
        guard let capturer else { return }
        let position: AVCaptureDevice.Position = frontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
            ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        // About 720p: sharp on a wall iPad without making the phone work hard.
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min { a, b in
            let wa = CMVideoFormatDescriptionGetDimensions(a.formatDescription).width
            let wb = CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
            return abs(Int(wa) - 1280) < abs(Int(wb) - 1280)
        }
        guard let format else { return }
        let fps = min(30, Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
        capturer.startCapture(with: device, format: format, fps: fps)
    }

    private func configureAudio() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            // With CallKit, the session goes on when CallKit says (`callKitActivated`).
            if !callKitAudio { try session.setActive(true) }
        } catch {
            log.error("Couldn't set up call audio: \(error.localizedDescription, privacy: .public)")
        }
        session.unlockForConfiguration()
    }
    #endif
}

#if canImport(WebRTC)
/// Something that isn't Sendable, carried to the main actor anyway. WebRTC objects are safe to
/// hand between threads; Swift just doesn't know it.
private nonisolated struct Carried<Value>: @unchecked Sendable {
    let value: Value
}

/// One WebRTC connection, and its delegate. WebRTC calls back on its own thread, so this is
/// nonisolated and passes everything to `CallMedia` on the main actor.
private nonisolated final class PeerLink: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    let peer: UUID
    weak var owner: CallMedia?
    var connection: RTCPeerConnection?

    private static var constraints: RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil
        )
    }

    init(peer: UUID, owner: CallMedia) {
        self.peer = peer
        self.owner = owner
    }

    func makeOffer(_ done: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let connection else { return }
        connection.offer(for: Self.constraints) { description, _ in
            guard let description else { Task { @MainActor in done(nil) }; return }
            connection.setLocalDescription(description) { error in
                let sdp = error == nil ? description.sdp : nil
                Task { @MainActor in done(sdp) }
            }
        }
    }

    func makeAnswer(_ done: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let connection else { return }
        connection.answer(for: Self.constraints) { description, _ in
            guard let description else { Task { @MainActor in done(nil) }; return }
            connection.setLocalDescription(description) { error in
                let sdp = error == nil ? description.sdp : nil
                Task { @MainActor in done(sdp) }
            }
        }
    }

    func setRemote(_ description: RTCSessionDescription, _ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let connection else { return }
        connection.setRemoteDescription(description) { error in
            let ok = error == nil
            Task { @MainActor in done(ok) }
        }
    }

    func add(_ candidate: RTCIceCandidate) {
        connection?.add(candidate) { _ in }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let peer = peer, owner = owner
        Task { @MainActor in owner?.changed(newState, for: peer) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let peer = peer, owner = owner
        let sdp = candidate.sdp
        let mid = candidate.sdpMid
        let index = candidate.sdpMLineIndex
        Task { @MainActor in owner?.generated(sdp: sdp, mid: mid, index: index, for: peer) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        let peer = peer, owner = owner
        let carried = Carried(value: track)
        Task { @MainActor in owner?.received(video: carried.value, from: peer) }
    }
}

/// A WebRTC video, mirrored for this device's own camera.
struct CallVideoView: UIViewRepresentable {
    var track: RTCVideoTrack?
    var mirrored = false
    var fills = true

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = fills ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.backgroundColor = .black
        context.coordinator.attach(track, to: view)
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        view.videoContentMode = fills ? .scaleAspectFill : .scaleAspectFit
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        context.coordinator.attach(track, to: view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attach(nil, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var track: RTCVideoTrack?

        func attach(_ new: RTCVideoTrack?, to view: RTCMTLVideoView) {
            guard new !== track else { return }
            track?.remove(view)
            track = new
            new?.add(view)
        }
    }
}
#endif

extension CallMedia {
    /// The video from a device in the call, or nothing if it hasn't arrived (or their camera's off).
    @ViewBuilder
    /// Their video: filling the space (cropping the edges), or all of it, with bars if the shapes differ.
    func remoteView(for peer: UUID, fills: Bool = true) -> some View {
        #if canImport(WebRTC)
        if remoteCamera[peer] == true, let track = remoteVideo[peer] {
            CallVideoView(track: track, fills: fills).id(remoteVideoVersion)
        }
        #else
        EmptyView()
        #endif
    }

    /// This device's own camera, mirrored like a mirror (front camera only).
    @ViewBuilder
    func localView() -> some View {
        #if canImport(WebRTC)
        if cameraOn, let track = localVideo {
            CallVideoView(track: track, mirrored: frontCamera)
        }
        #else
        EmptyView()
        #endif
    }
}
