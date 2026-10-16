import HomeKit
import SwiftUI

// Cameras on the Control screen: a strip of snapshots that refresh every 15 seconds, and a
// camera full screen and live, with Talk and Mute.

/// A camera's latest snapshot, 16:9, with its name.
struct CameraSnapshotTile: View {
    var camera: HomeCamera

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CameraSnapshotView(accessoryID: camera.id)
                .background(Color.black)
                .allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 6) {
                Image(systemName: camera.isDoorbell ? "bell.fill" : "video.fill")
                    .font(.caption.weight(.bold))
                Text(camera.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(width: 260, height: 146)
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(camera.name) camera")
        .accessibilityAddTraits(.isButton)
    }
}

/// HomeKit's camera view showing the newest snapshot, refreshed every 15 seconds.
struct CameraSnapshotView: UIViewRepresentable {
    var accessoryID: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        context.coordinator.attach(view, accessoryID: accessoryID)
        return view
    }

    func updateUIView(_ view: HMCameraView, context: Context) {}

    static func dismantleUIView(_ view: HMCameraView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, HMCameraSnapshotControlDelegate {
        private weak var view: HMCameraView?
        private var control: HMCameraSnapshotControl?
        private var refresh: Task<Void, Never>?

        func attach(_ view: HMCameraView, accessoryID: UUID) {
            self.view = view
            guard let control = HomeBridge.shared.cameraProfile(for: accessoryID)?.snapshotControl else { return }
            self.control = control
            if let snapshot = control.mostRecentSnapshot { view.cameraSource = snapshot }
            refresh = Task { [weak self] in
                while !Task.isCancelled {
                    self?.snap()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }

        /// The live view takes over the camera's snapshot delegate while it's open, so claim it
        /// back each time.
        private func snap() {
            guard let control, view?.window != nil else { return }
            control.delegate = self
            control.takeSnapshot()
        }

        func stop() {
            refresh?.cancel()
            refresh = nil
        }

        private func show(_ snapshot: HMCameraSnapshot?) {
            guard let snapshot else { return }
            view?.cameraSource = snapshot
        }

        nonisolated func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: Error?) {
            Task { @MainActor in self.show(snapshot) }
        }
    }
}

/// A camera full screen and live, with Talk and Mute.
struct CameraFullScreen: View {
    var camera: HomeCamera

    @Environment(\.dismiss) private var dismiss
    @State private var talking = false
    @State private var muted = false

    private var audio: HMCameraAudioStreamSetting {
        if talking { return .bidirectionalAudioAllowed }
        return muted ? .muted : .incomingAudioAllowed
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraLiveView(accessoryID: camera.id, audio: audio)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(camera.name).font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.black.opacity(0.5), in: Capsule())
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 16) {
                Button {
                    muted.toggle()
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .accessibilityLabel(muted ? "Unmute" : "Mute")
                Button {
                    talking.toggle()
                } label: {
                    Label(talking ? "Done" : "Talk", systemImage: "mic.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .frame(height: 56)
                        .background(talking ? Brand.late : Color(hex: 0x34C759), in: Capsule())
                }
                .sensoryFeedback(.impact, trigger: talking)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 30)
        }
        .statusBarHidden()
    }
}
