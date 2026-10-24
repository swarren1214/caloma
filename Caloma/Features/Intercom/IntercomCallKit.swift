import AVFoundation
import CallKit
import OSLog
import UIKit

/// The system call screen, for calls that woke this device (`IntercomPush`): it rings over the
/// lock screen like a phone call, and answering there joins the call. Calls that come in while
/// Caloma is open ring in Caloma's own screen instead (`CallWindow`).
final class IntercomCallKit: NSObject {
    private static var made: IntercomCallKit?
    /// Made by the first push that wakes this device, so devices that never get one (boards
    /// left on at home) never set up CallKit.
    static var shared: IntercomCallKit {
        if let made { return made }
        let new = IntercomCallKit()
        made = new
        return new
    }
    /// The call the system is showing, without setting CallKit up.
    static var showing: UUID? { made?.current }

    /// The call the system is showing.
    private(set) var current: UUID?
    private let provider: CXProvider
    private let controller = CXCallController()
    private let log = Logger(subsystem: "com.stephenwarren.caloma", category: "intercom")
    private var giveUp: Task<Void, Never>?

    /// How long to wait for the caller once awake, before it's a missed call.
    private static let waitSeconds: Double = CallState.ringSeconds

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        if let icon = UIImage(systemName: "house.fill")?.pngData() { configuration.iconTemplateImageData = icon }
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Shows the ringing call for a wake-up push. `done` runs once the system has it.
    func report(_ ring: WokenRing?, done: @escaping @Sendable () -> Void) {
        let center = CallCenter.shared
        // A push that can't be a call here still has to show one (iOS ends the app otherwise):
        // shown and ended straight away.
        let usable: WokenRing? = {
            guard let ring, current == nil else { return nil }
            if center.state.isBusy { return nil }
            return ring
        }()
        guard let ring = usable else {
            if let ring, ring.call == current {
                // The same call again: the system is already showing it (and says so).
                provider.reportNewIncomingCall(with: ring.call, update: update(name: ring.name, video: ring.video)) { _ in done() }
                return
            }
            let id = UUID()
            provider.reportNewIncomingCall(with: id, update: update(name: ring?.name ?? "Intercom", video: false)) { [weak self] _ in
                Task { @MainActor in self?.provider.reportCall(with: id, endedAt: nil, reason: .unanswered) }
                done()
            }
            return
        }
        current = ring.call
        center.woke(for: ring)
        provider.reportNewIncomingCall(with: ring.call, update: update(name: ring.name, video: ring.video)) { [weak self] error in
            if let error {
                let reason = error.localizedDescription
                Task { @MainActor in
                    // Do Not Disturb, Focus or a blocked caller: as good as declined.
                    self?.log.notice("System didn't take the intercom call: \(reason, privacy: .public)")
                    if self?.current == ring.call { self?.current = nil }
                    CallCenter.shared.endFromCallKit(ring.call)
                }
            }
            done()
        }
        giveUp?.cancel()
        giveUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.waitSeconds))
            guard !Task.isCancelled, let self, self.current == ring.call else { return }
            // The caller never got through on the network (not home, or gave up first).
            if CallCenter.shared.state.call != ring.call {
                self.end(ring.call, reason: .unanswered)
                CallCenter.shared.endFromCallKit(ring.call)
            }
        }
    }

    /// The call is over here: takes the system's call screen down.
    func end(_ call: UUID, reason: CXCallEndedReason) {
        guard current == call else { return }
        current = nil
        giveUp?.cancel()
        giveUp = nil
        provider.reportCall(with: call, endedAt: nil, reason: reason)
        finished()
    }

    /// Answered in Caloma's own screen: tell the system, so its call screen moves on too (and
    /// turns on the sound). It answers through `CXAnswerCallAction`, below.
    func requestAnswer(_ call: UUID) {
        controller.request(CXTransaction(action: CXAnswerCallAction(call: call))) { [weak self] error in
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor in
                self?.log.error("Couldn't answer through the system: \(reason, privacy: .public)")
                CallCenter.shared.answerFromCallKit(call)
            }
        }
    }

    private func finished() {
        CallCenter.shared.media.callKitAudio = false
        // Woken in the background and still there: nothing more to listen for.
        if UIApplication.shared.applicationState == .background, !CallCenter.shared.state.isBusy {
            IntercomService.shared.stop()
        }
    }

    private func update(name: String, video: Bool) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = video
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }
}

extension IntercomCallKit: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            guard let call = current else { return }
            current = nil
            CallCenter.shared.endFromCallKit(call)
            finished()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            giveUp?.cancel()
            CallCenter.shared.media.callKitAudio = true
            CallCenter.shared.answerFromCallKit(action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            let call = action.callUUID
            if current == call {
                current = nil
                giveUp?.cancel()
            }
            CallCenter.shared.endFromCallKit(call)
            action.fulfill()
            finished()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            CallCenter.shared.media.setMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { CallCenter.shared.media.callKitActivated(audioSession) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { CallCenter.shared.media.callKitDeactivated(audioSession) }
    }
}
