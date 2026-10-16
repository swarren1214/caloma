import HomeKit
import SwiftUI

/// The doorbell on the wall: live video in a card that slides in over whatever is showing.
/// Talk, mute, expand, and close any time. It closes itself after a minute, but never while
/// someone is talking. Unlocking the door takes the parent PIN.
struct DoorbellCard: View {
    var event: DoorbellEvent
    var onClose: () -> Void

    @Environment(KioskSession.self) private var session
    @State private var expanded = false
    @State private var talking = false
    @State private var muted = false
    @State private var deadline = Date.now.addingTimeInterval(DoorbellCard.autoClose)
    @State private var unlocking = false
    @State private var unlockNote: String?

    static let autoClose: TimeInterval = 60
    private let rose = Brand.defaultAccent

    private var audio: HMCameraAudioStreamSetting {
        if talking { return .bidirectionalAudioAllowed }
        return muted ? .muted : .incomingAudioAllowed
    }

    private var lockID: UUID? { HomeBridge.shared.lockID(near: event.accessoryID) }

    var body: some View {
        ZStack(alignment: expanded ? .center : .bottomTrailing) {
            if expanded {
                Color.black.opacity(0.4)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.smooth) { expanded = false } }
                    .transition(.opacity)
            }
            card
                .frame(width: expanded ? 900 : 440, height: expanded ? 640 : 360)
                .padding(expanded ? 0 : 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: expanded ? .center : .bottomTrailing)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: expanded)
        .task(id: TimerKey(deadline: deadline, talking: talking)) {
            guard !talking else { return }
            let wait = deadline.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, !talking else { return }
            onClose()
        }
        .sheet(isPresented: $unlocking) {
            NavigationStack {
                VStack(spacing: 16) {
                    ParentPINPad(title: "Enter the parent PIN to unlock \(event.name)", tint: rose) {
                        unlocking = false
                        session.unlock()
                        unlockDoor()
                    }
                }
                .padding(24)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { unlocking = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    private struct TimerKey: Equatable {
        var deadline: Date
        var talking: Bool
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CameraLiveView(accessoryID: event.accessoryID, audio: audio)
                    .background(Color.black)
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("LIVE").font(.caption.weight(.bold)).tracking(0.5)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(14)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("Close video")
            }
            .overlay(alignment: .bottom) {
                if talking {
                    Label("They can hear you", systemImage: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            .clipped()

            // The minute until it closes, paused while talking.
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let left = talking ? DoorbellCard.autoClose : max(0, deadline.timeIntervalSince(context.date))
                GeometryReader { proxy in
                    Rectangle()
                        .fill(rose)
                        .frame(width: proxy.size.width * left / DoorbellCard.autoClose)
                        .animation(.linear(duration: 0.25), value: left)
                }
            }
            .frame(height: 3)
            .background(Color(.tertiarySystemFill))

            controls
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: expanded ? 28 : 24))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Image(systemName: event.byMotion ? "video.fill" : "bell.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(rose, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(event.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            roundButton(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", muted ? "Unmute" : "Mute") {
                muted.toggle()
            }
            roundButton(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", expanded ? "Shrink" : "Expand") {
                withAnimation(.smooth) { expanded.toggle() }
            }
            if expanded, lockID != nil {
                Button {
                    if session.isUnlocked { unlockDoor() } else { unlocking = true }
                } label: {
                    Label(unlockNote ?? "Unlock", systemImage: "lock.open.fill")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Button {
                withAnimation(.snappy) {
                    talking.toggle()
                    // Done talking: a fresh minute before it closes.
                    if !talking { deadline = .now.addingTimeInterval(DoorbellCard.autoClose) }
                }
            } label: {
                Label(talking ? "Done" : "Talk", systemImage: talking ? "mic.slash.fill" : "mic.fill")
                    .font(.headline)
                    // The buttons keep their size; the name and subtitle give way instead.
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(talking ? Brand.late : Color(hex: 0x34C759), in: Capsule())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact, trigger: talking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        if talking { return "Talking · stays open until you're done" }
        let when = event.at.formatted(date: .omitted, time: .shortened)
        return (event.byMotion ? "Motion · " : "Doorbell · ") + when + (muted ? " · sound off" : "")
    }

    private func roundButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func unlockDoor() {
        guard let lockID else { return }
        unlockNote = "Unlocking…"
        Task {
            let ok = await HomeBridge.shared.unlock(lockID)
            unlockNote = ok ? "Unlocked" : "Couldn't unlock"
        }
    }
}

/// HomeKit's camera view: the doorbell's latest snapshot at once, then the live stream.
struct CameraLiveView: UIViewRepresentable {
    var accessoryID: UUID
    var audio: HMCameraAudioStreamSetting

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        context.coordinator.attach(view, accessoryID: accessoryID, audio: audio)
        return view
    }

    func updateUIView(_ view: HMCameraView, context: Context) {
        context.coordinator.setAudio(audio)
    }

    static func dismantleUIView(_ view: HMCameraView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, HMCameraStreamControlDelegate, HMCameraSnapshotControlDelegate {
        private weak var view: HMCameraView?
        private var profile: HMCameraProfile?
        private var audio: HMCameraAudioStreamSetting = .incomingAudioAllowed
        private var live = false

        func attach(_ view: HMCameraView, accessoryID: UUID, audio: HMCameraAudioStreamSetting) {
            self.view = view
            self.audio = audio
            guard let profile = HomeBridge.shared.cameraProfile(for: accessoryID) else { return }
            self.profile = profile
            profile.streamControl?.delegate = self
            profile.snapshotControl?.delegate = self
            if let snapshot = profile.snapshotControl?.mostRecentSnapshot {
                view.cameraSource = snapshot
            }
            profile.snapshotControl?.takeSnapshot()
            profile.streamControl?.startStream()
        }

        func setAudio(_ audio: HMCameraAudioStreamSetting) {
            guard audio != self.audio else { return }
            self.audio = audio
            applyAudio()
        }

        func stop() {
            profile?.streamControl?.stopStream()
            profile = nil
        }

        private func applyAudio() {
            profile?.streamControl?.cameraStream?.updateAudioStreamSetting(audio) { _ in }
        }

        private func streamStarted() {
            guard let stream = profile?.streamControl?.cameraStream else { return }
            live = true
            view?.cameraSource = stream
            applyAudio()
        }

        private func snapshotTaken(_ snapshot: HMCameraSnapshot?) {
            guard !live, let snapshot else { return }
            view?.cameraSource = snapshot
        }

        nonisolated func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
            Task { @MainActor in self.streamStarted() }
        }

        nonisolated func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: Error?) {}

        nonisolated func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: Error?) {
            Task { @MainActor in self.snapshotTaken(snapshot) }
        }
    }
}
