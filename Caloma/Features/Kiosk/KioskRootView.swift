import LocalAuthentication
import SwiftData
import SwiftUI

/// Kiosk Mode: the iPad on the wall. The family calendar fills the screen, with everyone down
/// the left. Tap a face for their screen: a kid's chores (the Kid View, as is) or a parent's own
/// tasks and what's waiting on them. With no touches for the idle time, the calendar eases
/// back in. Leaving takes the parent PIN; Guided Access keeps the rest of iPadOS out.
struct KioskRootView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.kioskShowsFamily) private var showsFamily = true
    @AppStorage(SettingsKey.kioskKeepAwake) private var keepAwake = true
    @AppStorage(SettingsKey.kioskFaces) private var facesOn = false

    @State private var session = KioskSession()
    private let presence = KioskPresence.shared
    @State private var leaving = false
    @Environment(\.modelContext) private var context
    @Query private var wallNotes: [WallNote]
    /// Repeating notes already dismissed on this visit.
    @State private var dismissedNotes: Set<UUID> = []
    @State private var drawingBack: DrawBackRequest?
    /// Two people the camera can't tell apart: ask which.
    @State private var closeCall: CloseCall?

    private var people: [Member] { members.filter { !$0.isArchived } }
    private var active: Member? {
        guard let id = session.activeID else { return nil }
        return people.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsFamily {
                KioskRail(people: people, onLeave: { leaving = true })
                Divider().ignoresSafeArea()
            }
            ZStack {
                if let active {
                    Group {
                        if active.isKid {
                            KidContextView(kid: active)
                        } else {
                            AdultContextView(member: active)
                        }
                    }
                    .id(active.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                } else if session.showsWhiteboard {
                    WhiteboardView(kiosk: true)
                        .transition(.opacity)
                } else {
                    NavigationStack {
                        CalendarView()
                    }
                    .environment(\.calendarReadOnly, true)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.smooth(duration: 0.45), value: session.activeID)
        .animation(.smooth(duration: 0.35), value: session.showsWhiteboard)
        // A note drawn for whoever just walked up drops in over their screen.
        .overlay {
            if let active, session.lockRequest == nil, session.doorbell == nil {
                let waiting = WallNoteQueue.pending(for: active.id, in: wallNotes).filter { !dismissedNotes.contains($0.id) }
                if let note = waiting.first {
                    let sender = people.first { $0.id == note.fromMemberID }
                    let drawBack: (() -> Void)? = sender != nil && sender?.id != active.id ? {
                        if let sender { drawingBack = DrawBackRequest(note: note, fromID: active.id, toID: sender.id) }
                    } : nil
                    WallNoteCard(
                        note: note,
                        viewer: active,
                        sender: sender,
                        position: (1, waiting.count),
                        onGotIt: { gotIt(note, by: active) },
                        onDrawBack: drawBack
                    )
                    .id(note.id)
                    .transition(.opacity)
                }
            }
        }
        .onChange(of: session.arrival) { _, _ in dismissedNotes = [] }
        // Who's replying to whom is fixed when Draw Back is tapped, whatever the wall does next.
        .sheet(item: $drawingBack) { request in
            if let writer = people.first(where: { $0.id == request.fromID }), let sender = people.first(where: { $0.id == request.toID }) {
                DrawBackSheet(from: writer, to: sender) { drawing in
                    let reply = WallNote(drawing: drawing.dataRepresentation(), from: writer.id, audience: [sender.id], keep: .once, replyTo: request.note.id)
                    context.insert(reply)
                    drawingBack = nil
                    gotIt(request.note, by: writer)
                }
                .onAppear { session.setComposing(true) }
                .onDisappear { session.setComposing(false) }
                .onChange(of: session.idleResets) { _, _ in drawingBack = nil }
            } else {
                Color.clear.onAppear { drawingBack = nil }
            }
        }
        // With the family rail turned off there's still a way out.
        .overlay(alignment: .bottomLeading) {
            if !showsFamily {
                Button {
                    leaving = true
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Leave the Family Board")
            }
        }
        // No one around: the screensaver, over everything but the doorbell.
        .overlay {
            if presence.isScreensaverOn {
                KioskScreensaverView { presence.touched() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: presence.isScreensaverOn)
        .onChange(of: presence.isScreensaverOn) { _, on in
            guard on else { return }
            // Underneath, the wall goes back to the calendar, and nothing is left open on top.
            session.showCalendar()
            leaving = false
            drawingBack = nil
            closeCall = nil
        }
        // Look less often while the screen is dark or the doorbell is up.
        .onChange(of: presence.isDimmed) { _, dimmed in
            FaceRecognizer.shared.setSlow(dimmed || session.doorbell != nil)
        }
        // Someone at the door: the card slides in over everything.
        .overlay {
            if let event = session.doorbell {
                DoorbellCard(event: event) {
                    withAnimation(.smooth) { session.closeDoorbell() }
                }
                .id(event.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if session.doorbell == nil, let last = session.lastDoorbell {
                RecentDoorbellPill(event: last) {
                    withAnimation(.spring(duration: 0.45, bounce: 0.2)) { session.reopenDoorbell() }
                }
                .padding(24)
                .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: session.doorbell)
        // Dimmed: the first touch only wakes the screen; it doesn't press anything.
        .overlay {
            if presence.isDimmed {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { presence.touched() }
            }
        }
        .background(TouchObserver {
            session.touched()
            presence.touched()
        })
        .environment(session)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            session.start()
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            Task { await presence.start() }
            HomeBridge.shared.start()
            HomeBridge.shared.onDoorbell = { event in
                // A ring always shows; motion never covers a card that's already up.
                if event.byMotion && session.doorbell != nil { return }
                // It wakes the screensaver and the dimmed screen.
                presence.touched()
                withAnimation(.spring(duration: 0.45, bounce: 0.2)) { session.ring(event) }
            }
            startFaces()
            WallNoteQueue.sweep(wallNotes, in: context)
            // Waking to the calendar: decided right as the screensaver ends, so a face that
            // woke it waits a moment before opening anyone's screen.
            presence.onScreensaverEnd = {
                if ScreensaverPrefs.wakeTo == .calendar { session.showCalendarByTap() }
            }
        }
        .onDisappear {
            session.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            HomeBridge.shared.onDoorbell = nil
            presence.onScreensaverEnd = nil
            presence.stop()
            FaceRecognizer.shared.onRecognized = nil
            FaceRecognizer.shared.onCloseCall = nil
            FaceRecognizer.shared.onLeft = nil
            FaceRecognizer.shared.stop()
        }
        .onChange(of: facesOn) { _, _ in startFaces() }
        .onChange(of: session.idleResets) { _, _ in closeCall = nil }
        // Brothers and sisters the camera can't tell apart: a quick pick instead of a guess.
        .sheet(item: $closeCall) { call in
            if let first = people.first(where: { $0.id == call.first }), let second = people.first(where: { $0.id == call.second }) {
                CloseCallPicker(call: call, first: first, second: second) { person in
                    pickedCloseCall(call, person: person)
                }
            } else {
                Color.clear.onAppear { closeCall = nil }
            }
        }
        .onChange(of: people.filter { !$0.isKid }.map(\.id), initial: true) { _, ids in
            session.parentIDs = Set(ids)
        }
        // Face ID shares the front camera; let it have it while a passcode is asked for.
        .onChange(of: session.lockRequest != nil) { _, asking in
            FaceRecognizer.shared.pause(asking)
            presence.pause(asking)
        }
        .onChange(of: session.doorbell != nil) { _, ringing in
            // Look less often while the doorbell is up; it won't switch screens anyway.
            FaceRecognizer.shared.setSlow(ringing || presence.isDimmed)
        }
        .onChange(of: keepAwake) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        // A locked profile: their passcode (or Face ID) before their screen opens.
        .sheet(item: Binding(get: { session.lockRequest }, set: { if $0 == nil { session.cancelUnlock() } })) { request in
            if let person = people.first(where: { $0.id == request.memberID }) {
                ProfileUnlockSheet(member: person) {
                    withAnimation(.smooth(duration: 0.45)) { session.finishUnlock(request.id, isParent: !person.isKid) }
                } onCancel: {
                    session.cancelUnlock()
                }
                .presentationDetents([.large])
            } else {
                Color.clear.onAppear { session.cancelUnlock() }
            }
        }
        .sheet(isPresented: $leaving) {
            LeaveKioskSheet {
                leaving = false
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    router.kioskOpen = false
                }
            }
            .presentationDetents([.large])
        }
    }
}

extension KioskRootView {
    /// Got It: a Once note is done for them; Today and Until Erased notes rest until their next
    /// visit.
    private func gotIt(_ note: WallNote, by person: Member) {
        withAnimation(.smooth) {
            if note.keep == .once, !note.seenBy.contains(person.id) {
                note.seenBy.append(person.id)
            }
            dismissedNotes.insert(note.id)
        }
        Persistence.save(context)
    }

    /// Faces on: watch the camera and let a steady match open that person's screen.
    private func startFaces() {
        let recognizer = FaceRecognizer.shared
        guard facesOn, !FaceStore.shared.isEmpty else {
            recognizer.onRecognized = nil
            recognizer.onCloseCall = nil
            recognizer.onLeft = nil
            recognizer.stop()
            return
        }
        recognizer.onRecognized = { id, held in recognized(id, held: held) }
        recognizer.onLeft = { id in withAnimation(.smooth(duration: 0.45)) { session.faceLeft(id) } }
        recognizer.onCloseCall = { first, second, look in closeCalled(first, second, look: look) }
        Task { await recognizer.start(.recognize) }
    }

    /// A tap always wins over a face. Someone new only takes over a screen a face opened, after
    /// a steady second and a half, and never while a parent has it unlocked with the PIN.
    private func recognized(_ id: UUID, held: TimeInterval) {
        guard !leaving, session.doorbell == nil, session.lockRequest == nil, people.contains(where: { $0.id == id }) else { return }
        // A steady match settles a close call that was still up.
        if closeCall != nil { closeCall = nil }
        // Remembered even when it doesn't change screens: a tap on their own profile, or a
        // parent's approvals and home controls, then skip the PIN.
        if held >= 0.5 { session.faceSeen(id) }
        // A face wakes the screensaver; with "Then Show: Their Screen" it opens theirs too.
        if presence.isScreensaverOn {
            presence.touched()
            if ScreensaverPrefs.wakeTo == .calendar { return }
        }
        // Someone drawing on the whiteboard or writing keeps the screen.
        if session.isComposing || (session.showsWhiteboard && session.activeID == nil) { return }
        // Their own screen: nothing to do. Only touches hold it open; a face never resets the
        // countdown back to the calendar.
        if session.activeID == id { return }
        if session.activeID == nil {
            session.open(id, source: .face)
        } else if let current = session.activeID, session.isAway(current) {
            // Whoever had the screen walked away: the next face takes over straight away, even
            // from a tapped-open or PIN-unlocked screen (the unlock doesn't carry over). The
            // camera only reports someone new once the last person it followed has left.
            session.open(id, source: .face)
        } else if session.source == .face, !session.isUnlocked || session.unlockedByFace, held >= 1.5 {
            session.open(id, source: .face)
        }
    }
}

extension KioskRootView {
    /// Two people keep coming out about even. Only asked over the calendar, with nothing else
    /// up; anywhere else a tap on the family rail is just as quick.
    private func closeCalled(_ first: UUID, _ second: UUID, look: [Float]) {
        guard !leaving, closeCall == nil, drawingBack == nil, session.doorbell == nil, session.lockRequest == nil,
              session.activeID == nil, !session.isComposing, !session.showsWhiteboard,
              people.contains(where: { $0.id == first }), people.contains(where: { $0.id == second }) else { return }
        if presence.isScreensaverOn {
            presence.touched()
            if ScreensaverPrefs.wakeTo == .calendar { return }
        }
        closeCall = CloseCall(first: first, second: second, look: look)
    }

    /// The pick opens their screen like "Who's here?" does. The look is kept only if the
    /// camera was already leaning their way; a locked profile keeps it once its passcode is right.
    private func pickedCloseCall(_ call: CloseCall, person: Member) {
        let locked = ProfileLock.isLocked(person.id)
        if !locked { FaceStore.shared.learn(call.look, for: person.id) }
        closeCall = nil
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            session.open(person.id, source: .picker, look: locked ? call.look : nil)
        }
    }
}

/// Draw Back: the note, who's answering and who it goes to.
struct DrawBackRequest: Identifiable {
    let id = UUID()
    let note: WallNote
    let fromID: UUID
    let toID: UUID
}

/// "Front Door · 2 min ago" after the doorbell card closes, to open it again. Gone after ten
/// minutes.
private struct RecentDoorbellPill: View {
    var event: DoorbellEvent
    var action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = Int(context.date.timeIntervalSince(event.at) / 60)
            if minutes < 10 {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Brand.defaultAccent, in: Circle())
                        Text("\(event.name) · \(minutes < 1 ? "just now" : "\(minutes) min ago")")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 14)
                    .frame(minHeight: 40)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Everyone down the left: the calendar button, a ring for each person (kids show how many
/// jobs are left), the countdown back to the calendar, and the lock to leave.
struct KioskRail: View {
    var people: [Member]
    var onLeave: () -> Void

    @Environment(KioskSession.self) private var session
    @Environment(\.accent) private var accent
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]

    var body: some View {
        let family = FamilySnapshot(members: people, chores: chores, completions: completions, points: [])
        VStack(spacing: 14) {
            // Calendar or Whiteboard: two labeled halves of one switch, the one showing filled.
            VStack(spacing: 4) {
                railMode("Calendar", symbol: "calendar", isOn: session.activeID == nil && !session.showsWhiteboard) {
                    session.showCalendarByTap()
                }
                railMode("Board", symbol: "applepencil.and.scribble", isOn: session.activeID == nil && session.showsWhiteboard) {
                    session.showWhiteboard()
                }
            }
            .padding(4)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 20))

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(people) { person in
                        let left = person.isKid ? family.items(for: person).filter { $0.status == .open && (!$0.chore.upForGrabs || $0.memberID == person.id) }.count : 0
                        KioskRailFace(
                            person: person,
                            isOn: session.activeID == person.id,
                            isDimmed: session.activeID != nil && session.activeID != person.id,
                            recognized: session.activeID == person.id && session.source == .face,
                            jobsLeft: left
                        ) {
                            session.open(person.id, source: .tap)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)

            if session.activeID != nil {
                IdleRing(color: active?.color.color ?? accent) {
                    session.showCalendarByTap()
                }
                .transition(.opacity)
            }

            Button(action: onLeave) {
                VStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                    Text("Leave")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.secondary)
                .frame(width: 56, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave the Family Board")
        }
        .padding(.vertical, 22)
        .frame(width: 112)
        .background(Color(.secondarySystemGroupedBackground).ignoresSafeArea())
        .animation(.smooth, value: session.activeID)
    }

    private var active: Member? { people.first { $0.id == session.activeID } }

    private func railMode(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.bold))
            }
            .frame(width: 72, height: 56)
            .foregroundStyle(isOn ? .white : .primary)
            .background(isOn ? accent : Color.clear, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(KidPressStyle())
        .accessibilityLabel(title == "Board" ? "Whiteboard" : "Family calendar")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One person on the rail: photo or initial in their color ring, their name, a red badge with
/// a kid's jobs left, and a green face badge when they were recognized.
private struct KioskRailFace: View {
    var person: Member
    var isOn: Bool
    var isDimmed: Bool
    var recognized: Bool
    var jobsLeft: Int
    var action: () -> Void

    var body: some View {
        let color = person.color.color
        Button(action: action) {
            VStack(spacing: 5) {
                MemberAvatar(person, size: 54)
                    .padding(4)
                    .overlay(Circle().strokeBorder(color, lineWidth: 4))
                    .background {
                        if isOn { Circle().fill(color.opacity(0.25)).padding(-4) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if jobsLeft > 0 {
                            Text(jobsLeft.formatted())
                                .font(.caption.weight(.heavy))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(Brand.late, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                                .offset(x: 6, y: -6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if recognized {
                            Image(systemName: "faceid")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color(hex: 0x34C759), in: Circle())
                                .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 3))
                                .offset(x: 4, y: 4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(person.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 96)
            }
            .opacity(isDimmed ? 0.5 : 1)
        }
        .buttonStyle(KidPressStyle())
        .accessibilityLabel(jobsLeft > 0 ? "\(person.name), \(jobsLeft) jobs left" : person.name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The countdown back to the calendar: a ring that empties over the idle time, reset by any
/// touch. Tapping it goes now.
private struct IdleRing: View {
    var color: Color
    var action: () -> Void

    @Environment(KioskSession.self) private var session

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let idle = session.idleSeconds
                    let left = max(0, idle - context.date.timeIntervalSince(session.lastTouch))
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: idle > 0 ? left / idle : 0)
                                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.5), value: left)
                            Image(systemName: "calendar")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                        }
                        .frame(width: 40, height: 40)
                        Text("Calendar\nin \(Int(left.rounded(.up))) s")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to the calendar")
    }
}

/// Leaving Kiosk Mode: the parent PIN, or this iPad's own Face ID or passcode.
struct LeaveKioskSheet: View {
    var onLeave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var authenticating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 0)
                if ParentPIN.isSet {
                    ParentPINPad(title: "Enter the parent PIN to leave the Family Board", tint: accent, onUnlock: onLeave)
                } else {
                    Text("Leave the Family Board?")
                        .font(.title2.bold())
                }
                Button(ParentPIN.isSet ? "Use Face ID or Passcode Instead" : "Leave with Face ID or Passcode") {
                    useDeviceOwner()
                }
                .disabled(authenticating)
                Text("If Guided Access is on, triple-click the top button afterwards to unlock the iPad.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
            }
        }
    }

    private func useDeviceOwner() {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            // No passcode on this iPad and no PIN: nothing to check, so don't trap anyone.
            if !ParentPIN.isSet { onLeave() }
            return
        }
        authenticating = true
        Task {
            defer { authenticating = false }
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Leave the Family Board")) ?? false
            if ok { onLeave() }
        }
    }
}
