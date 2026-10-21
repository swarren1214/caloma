import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Who the wall iPad is showing in Kiosk Mode. A tap on the rail, a pick in "Who's here?" or
/// (later) a recognized face proposes someone; this decides. After the idle time with no
/// touches, the family calendar comes back and anything a parent unlocked is locked again.
@Observable
final class KioskSession {
    /// How the person on screen got there.
    enum Source: Equatable {
        case tap, picker, face
    }

    /// The family member on screen, or nil for the calendar (or the whiteboard).
    private(set) var activeID: UUID?
    /// The rail's switch is on Whiteboard rather than Calendar.
    private(set) var showsWhiteboard = false
    /// Someone is writing an event or drawing back: faces don't swap screens underneath them.
    private(set) var isComposing = false
    /// Goes up each time the wall goes back to the calendar on its own, so open sheets close.
    private(set) var idleResets = 0
    private(set) var source: Source = .tap
    /// When the screen was last touched.
    private(set) var lastTouch: Date = .now
    /// A parent entered the PIN. Approvals and leaving Kiosk Mode are open until the screen
    /// goes back to the calendar or someone else steps up.
    private(set) var isUnlocked = false
    /// The unlock came from the camera, not the PIN: when the parent steps away and someone
    /// else's face holds steady, their screen can take over.
    private(set) var unlockedByFace = false
    /// Goes up each time someone is shown, so screens can replay their hello.
    private(set) var arrival = 0
    /// Someone at the door, while the doorbell card is up.
    private(set) var doorbell: DoorbellEvent?
    /// The last ring, so it can be opened again for a while after it closes.
    private(set) var lastDoorbell: DoorbellEvent?
    /// A locked profile waiting for its passcode before it opens.
    struct LockRequest: Identifiable, Equatable {
        let id = UUID()
        let memberID: UUID
        let source: Source
        /// From "Who's here?": the face in view, learned only once the passcode is right.
        var look: [Float]?
    }

    private(set) var lockRequest: LockRequest?
    /// Someone who just cancelled their passcode; their face won't ask again for a moment.
    @ObservationIgnored private var declined: (memberID: UUID, until: Date)?

    /// After someone taps back to the calendar, faces wait a moment before opening anyone.
    private(set) var facesPausedUntil: Date?

    /// How long a face waits before it can open the same person's screen again.
    static let faceCooldown: TimeInterval = 30
    /// When each person's face may open their screen again: 30 seconds after a face opened
    /// it, and 30 seconds after it closed, whichever is later. A tap always opens it.
    @ObservationIgnored private var faceCooldowns: [UUID: Date] = [:]

    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// The parents, set by the Family Board: a parent the camera recognizes skips the PIN.
    @ObservationIgnored var parentIDs: Set<UUID> = []
    /// Who the camera last recognized, and when.
    @ObservationIgnored private var lastSeen: (memberID: UUID, at: Date)?
    /// How long after a steady match someone still counts as standing in front of the iPad.
    static let inViewSeconds: TimeInterval = 2.5

    /// Whether the camera recognized this person a moment ago, so a tap on their own screen
    /// is them and not someone else.
    func isInView(_ memberID: UUID, now: Date = .now) -> Bool {
        guard let lastSeen, lastSeen.memberID == memberID else { return false }
        return now.timeIntervalSince(lastSeen.at) <= Self.inViewSeconds
    }

    /// A steady face match. A parent recognized on their own screen gets approvals and home
    /// controls without the PIN; anyone else changes nothing here.
    func faceSeen(_ memberID: UUID) {
        lastSeen = (memberID, .now)
        if activeID == memberID, parentIDs.contains(memberID), !isUnlocked {
            unlock(byFace: true)
        }
    }

    /// Profile › Kiosk Mode › Back to the Calendar After.
    var idleSeconds: TimeInterval {
        Self.moveIdleTimeToTwentySeconds()
        let seconds = UserDefaults.standard.integer(forKey: SettingsKey.kioskIdleSeconds)
        return TimeInterval(seconds > 0 ? seconds : Self.defaultIdleSeconds)
    }

    /// Back to the calendar after 20 seconds unless the family picks otherwise.
    static let defaultIdleSeconds = 20
    /// How long the whiteboard stays up with nobody drawing or touching it.
    static let whiteboardIdleSeconds: TimeInterval = 60

    /// Once: a wall that was on the old 30-second default moves to 20. Any other choice stays.
    static func moveIdleTimeToTwentySeconds() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKey.kioskIdleMovedTo20) else { return }
        defaults.set(true, forKey: SettingsKey.kioskIdleMovedTo20)
        if defaults.integer(forKey: SettingsKey.kioskIdleSeconds) == 30 {
            defaults.set(defaultIdleSeconds, forKey: SettingsKey.kioskIdleSeconds)
        }
    }

    /// Whether a face is still waiting out its cooldown before reopening this person.
    func isCoolingDown(_ memberID: UUID, now: Date = .now) -> Bool {
        (faceCooldowns[memberID] ?? .distantPast) > now
    }

    private func startCooldown(_ memberID: UUID) {
        let until = Date.now.addingTimeInterval(Self.faceCooldown)
        faceCooldowns[memberID] = max(faceCooldowns[memberID] ?? .distantPast, until)
    }

    /// A tap, a pick or a face asking for someone's screen. Locked profiles ask for their
    /// passcode first; everyone else opens straight away.
    func open(_ memberID: UUID, source: Source, look: [Float]? = nil) {
        if memberID == activeID {
            lastTouch = .now
            return
        }
        // A face just seen doesn't reopen the same screen for 30 seconds; a tap still does.
        if source == .face, isCoolingDown(memberID) { return }
        // The camera sees the person whose screen it is: no passcode, and a parent's screen
        // opens unlocked. Anyone else tapping it still gets asked.
        let isThem = source == .face || isInView(memberID)
        guard ProfileLock.isLocked(memberID), !isThem else {
            show(memberID, source: source)
            if isThem, parentIDs.contains(memberID) { unlock(byFace: true) }
            return
        }
        guard lockRequest == nil else { return }
        if source == .face, let declined, declined.memberID == memberID, declined.until > .now { return }
        lockRequest = LockRequest(memberID: memberID, source: source, look: look)
        lastTouch = .now
    }

    /// The passcode (or Face ID) for this request was right.
    /// A parent who just gave their own passcode is unlocked for the visit too: approvals and
    /// home controls don't ask again for the parent PIN.
    func finishUnlock(_ requestID: UUID, isParent: Bool = false) {
        guard let request = lockRequest, request.id == requestID else { return }
        lockRequest = nil
        if let look = request.look {
            FaceStore.shared.learn(look, for: request.memberID, confirmed: true)
        }
        show(request.memberID, source: request.source)
        if isParent { unlock() }
    }

    /// Cancelled: and a face standing there doesn't ask again straight away.
    func cancelUnlock() {
        if let request = lockRequest {
            declined = (request.memberID, .now.addingTimeInterval(20))
        }
        lockRequest = nil
        facesPausedUntil = .now.addingTimeInterval(15)
    }

    func show(_ memberID: UUID, source: Source) {
        // Someone new on screen never inherits the last person's unlock, and the person a
        // face had opened starts their 30 seconds.
        if memberID != activeID {
            isUnlocked = false
            if let activeID, self.source == .face { startCooldown(activeID) }
        }
        activeID = memberID
        showsWhiteboard = false
        self.source = source
        arrival += 1
        lastTouch = .now
        if source == .face { startCooldown(memberID) }
    }

    func showCalendar() {
        // The 30 seconds run from when a face-opened screen closes, too.
        if let activeID, source == .face { startCooldown(activeID) }
        activeID = nil
        showsWhiteboard = false
        isUnlocked = false
        lockRequest = nil
    }

    /// The rail's Whiteboard switch. Faces don't open anyone while someone's drawing.
    func showWhiteboard() {
        if let activeID, source == .face { startCooldown(activeID) }
        activeID = nil
        showsWhiteboard = true
        isUnlocked = false
        lockRequest = nil
        lastTouch = .now
    }

    /// The calendar button or the countdown ring: back to the calendar, and don't let the
    /// face that's still standing there pop their screen straight back open.
    func showCalendarByTap() {
        showCalendar()
        facesPausedUntil = .now.addingTimeInterval(15)
    }

    func touched() {
        lastTouch = .now
    }

    func setComposing(_ composing: Bool) {
        isComposing = composing
        lastTouch = .now
    }

    /// The PIN pad, or the camera recognizing the parent whose screen is open.
    func unlock(byFace: Bool = false) {
        // A PIN unlock stays a PIN unlock if the camera also sees them.
        if !isUnlocked || !byFace { unlockedByFace = byFace }
        isUnlocked = true
        // The PIN is a touch; the camera isn't, so it doesn't hold the screen open.
        if !byFace { lastTouch = .now }
    }

    func lock() {
        isUnlocked = false
    }

    func ring(_ event: DoorbellEvent) {
        doorbell = event
        lastDoorbell = event
        lastTouch = .now
    }

    func closeDoorbell() {
        doorbell = nil
    }

    func reopenDoorbell() {
        doorbell = lastDoorbell
        lastTouch = .now
    }

    func start() {
        guard watchdog == nil else { return }
        lastTouch = .now
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func tick() {
        guard activeID != nil || isUnlocked || lockRequest != nil || showsWhiteboard || isComposing else { return }
        // The whiteboard waits a minute after the last stroke or touch, whatever the idle time.
        // Writing an event or a reply gets three.
        var wait = showsWhiteboard && activeID == nil ? Self.whiteboardIdleSeconds : idleSeconds
        if isComposing { wait = max(wait, 180) }
        if Date.now.timeIntervalSince(lastTouch) >= wait {
            showCalendar()
            idleResets += 1
        }
    }
}

/// Notices every touch anywhere in the window without getting in its way, for the idle timer.
struct TouchObserver: UIViewRepresentable {
    var onTouch: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(onTouch: onTouch)
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onTouch = onTouch
    }

    final class ObserverView: UIView {
        var onTouch: () -> Void
        private var recognizer: TouchRecognizer?

        init(onTouch: @escaping () -> Void) {
            self.onTouch = onTouch
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window else { return }
            let recognizer = TouchRecognizer { [weak self] in self?.onTouch() }
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }
    }

    /// Fails at once on every touch, so it never blocks or delays anything.
    final class TouchRecognizer: UIGestureRecognizer {
        private let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            handler()
            state = .failed
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}

extension EnvironmentValues {
    /// The wall calendar in Kiosk Mode: look and open, but no new events, drags, edits or
    /// deletes. Parents change the calendar from their phones.
    @Entry var calendarReadOnly: Bool = false
}

/// "Good morning", "Good afternoon" or "Good evening".
func kioskGreeting(at date: Date = .now) -> String {
    let hour = Calendar.current.component(.hour, from: date)
    switch hour {
    case 4..<12: return "Good morning"
    case 12..<17: return "Good afternoon"
    default: return "Good evening"
    }
}
