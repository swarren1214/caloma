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

    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// Family › Kiosk Mode › Back to the Calendar After.
    var idleSeconds: TimeInterval {
        let seconds = UserDefaults.standard.integer(forKey: SettingsKey.kioskIdleSeconds)
        return TimeInterval(seconds > 0 ? seconds : 30)
    }

    /// A tap, a pick or a face asking for someone's screen. Locked profiles ask for their
    /// passcode first; everyone else opens straight away.
    func open(_ memberID: UUID, source: Source, look: [Float]? = nil) {
        if memberID == activeID {
            lastTouch = .now
            return
        }
        guard ProfileLock.isLocked(memberID) else {
            show(memberID, source: source)
            return
        }
        guard lockRequest == nil else { return }
        if source == .face, let declined, declined.memberID == memberID, declined.until > .now { return }
        lockRequest = LockRequest(memberID: memberID, source: source, look: look)
        lastTouch = .now
    }

    /// The passcode (or Face ID) for this request was right.
    func finishUnlock(_ requestID: UUID) {
        guard let request = lockRequest, request.id == requestID else { return }
        lockRequest = nil
        if let look = request.look {
            FaceStore.shared.learn(look, for: request.memberID)
        }
        show(request.memberID, source: request.source)
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
        // Someone new on screen never inherits the last person's unlock.
        if memberID != activeID { isUnlocked = false }
        activeID = memberID
        showsWhiteboard = false
        self.source = source
        arrival += 1
        lastTouch = .now
    }

    func showCalendar() {
        activeID = nil
        showsWhiteboard = false
        isUnlocked = false
        lockRequest = nil
    }

    /// The rail's Whiteboard switch. Faces don't open anyone while someone's drawing.
    func showWhiteboard() {
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

    /// Only the PIN pad calls this. Faces never do.
    func unlock() {
        isUnlocked = true
        lastTouch = .now
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
        // Drawing takes longer than a glance: the whiteboard waits at least two minutes.
        // Writing an event or a reply gets three.
        var wait = showsWhiteboard && activeID == nil ? max(idleSeconds, 120) : idleSeconds
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
