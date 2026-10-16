import SwiftUI
import UIKit

/// The wall iPad's screen brightness in Kiosk Mode. After a few minutes with no touch and no
/// movement, it fades to the lowest brightness. When the camera sees someone move (or the
/// screen is touched), it fades back up to suit the room: about 50% in a dark room, up to 100%
/// in a bright one, and it keeps following the room's light while it's awake.
@Observable
final class KioskPresence {
    static let shared = KioskPresence()

    private(set) var isDimmed = false
    private(set) var cameraDenied = false

    @ObservationIgnored private var running = false
    @ObservationIgnored private var lastActivity = Date.now
    @ObservationIgnored private var lastAdjust = Date.distantPast
    /// The room's brightness, smoothed (APEX stops from the camera).
    @ObservationIgnored private var roomLight: Double?
    /// What the screen was before Kiosk Mode, put back when it ends.
    @ObservationIgnored private var original: CGFloat?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var fade: Task<Void, Never>?

    private var camera: FaceCamera { FaceRecognizer.shared.camera }

    private var dims: Bool { UserDefaults.standard.object(forKey: SettingsKey.kioskDims) as? Bool ?? true }
    private var matchesLight: Bool { UserDefaults.standard.object(forKey: SettingsKey.kioskMatchLight) as? Bool ?? true }
    private var dimAfter: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: SettingsKey.kioskDimMinutes)
        return TimeInterval((minutes > 0 ? minutes : 5) * 60)
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    // MARK: Starting and stopping

    func start() async {
        guard !running else { return }
        running = true
        original = screen?.brightness
        lastActivity = .now
        isDimmed = false
        if dims || matchesLight {
            if await FaceCamera.requestAccess() {
                guard running else { return }
                camera.onPresence = { motion, brightness in
                    Task { @MainActor in KioskPresence.shared.saw(motion: motion, brightness: brightness) }
                }
                camera.start("presence")
            } else {
                // Without the camera it still dims; a touch wakes it.
                cameraDenied = true
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.tick()
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        watchdog?.cancel()
        watchdog = nil
        fade?.cancel()
        camera.onPresence = nil
        camera.stop("presence")
        isDimmed = false
        if let original { screen?.brightness = original }
        original = nil
    }

    /// Face ID needs the front camera for a moment.
    func pause(_ paused: Bool) {
        guard running, !cameraDenied else { return }
        if paused { camera.stop("presence") } else { camera.start("presence") }
    }

    // MARK: What happens

    /// A touch anywhere on the screen.
    func touched() {
        lastActivity = .now
        if isDimmed { wake() }
    }

    private func saw(motion: Bool, brightness: Double?) {
        guard running else { return }
        if let brightness {
            // Smooth it, so a passing shadow doesn't flicker the screen.
            roomLight = roomLight.map { $0 * 0.8 + brightness * 0.2 } ?? brightness
        }
        if motion {
            lastActivity = .now
            if isDimmed { wake() }
        }
        // While awake, follow the room's light about once a minute.
        if !isDimmed, matchesLight, Date.now.timeIntervalSince(lastAdjust) > 60 {
            lastAdjust = .now
            fadeTo(target, over: 2)
        }
    }

    private func tick() {
        guard running, dims, !isDimmed, Date.now.timeIntervalSince(lastActivity) >= dimAfter else { return }
        isDimmed = true
        fadeTo(0, over: 2.5)
    }

    private func wake() {
        isDimmed = false
        lastAdjust = .now
        fadeTo(target, over: 0.6)
    }

    /// 50% in a dark room (brightness value 0 or below), 100% in a bright one (5 or above),
    /// in between for everything else. Without a reading: where it was before Kiosk Mode.
    private var target: CGFloat {
        guard matchesLight, let light = roomLight else { return max(original ?? 0.8, 0.5) }
        let t = min(max(light / 5, 0), 1)
        return CGFloat(0.5 + 0.5 * t)
    }

    /// Changes the brightness smoothly rather than in one jump.
    private func fadeTo(_ value: CGFloat, over seconds: Double) {
        fade?.cancel()
        guard let screen else { return }
        let start = screen.brightness
        guard abs(start - value) > 0.01 else { return }
        let steps = max(Int(seconds * 30), 1)
        fade = Task { [weak self] in
            for step in 1...steps {
                guard !Task.isCancelled, self?.running == true else { return }
                let progress = Double(step) / Double(steps)
                let eased = progress * progress * (3 - 2 * progress)
                screen.brightness = start + (value - start) * CGFloat(eased)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }
}
