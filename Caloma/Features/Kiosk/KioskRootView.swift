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
    @State private var leaving = false

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
        // With the family rail turned off there's still a way out.
        .overlay(alignment: .bottomLeading) {
            if !showsFamily {
                Button {
                    leaving = true
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Leave Kiosk Mode")
            }
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
        .background(TouchObserver { session.touched() })
        .environment(session)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            session.start()
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            HomeBridge.shared.start()
            HomeBridge.shared.onDoorbell = { event in
                // A ring always shows; motion never covers a card that's already up.
                if event.byMotion && session.doorbell != nil { return }
                withAnimation(.spring(duration: 0.45, bounce: 0.2)) { session.ring(event) }
            }
            startFaces()
        }
        .onDisappear {
            session.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            HomeBridge.shared.onDoorbell = nil
            FaceRecognizer.shared.onRecognized = nil
            FaceRecognizer.shared.stop()
        }
        .onChange(of: facesOn) { _, _ in startFaces() }
        .onChange(of: session.doorbell != nil) { _, ringing in
            // Look less often while the doorbell is up; it won't switch screens anyway.
            FaceRecognizer.shared.setSlow(ringing)
        }
        .onChange(of: keepAwake) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
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
    /// Faces on: watch the camera and let a steady match open that person's screen.
    private func startFaces() {
        let recognizer = FaceRecognizer.shared
        guard facesOn, !FaceStore.shared.isEmpty else {
            recognizer.onRecognized = nil
            recognizer.stop()
            return
        }
        recognizer.onRecognized = { id, held in recognized(id, held: held) }
        Task { await recognizer.start(.recognize) }
    }

    /// A tap always wins over a face. Someone new only takes over a screen a face opened, after
    /// a steady second and a half, and never while a parent has it unlocked.
    private func recognized(_ id: UUID, held: TimeInterval) {
        guard !leaving, session.doorbell == nil, people.contains(where: { $0.id == id }) else { return }
        if let paused = session.facesPausedUntil, paused > .now, session.activeID == nil { return }
        if session.activeID == id {
            // Standing there counts as using it.
            session.touched()
        } else if session.activeID == nil {
            session.show(id, source: .face)
        } else if session.source == .face, !session.isUnlocked, held >= 1.5 {
            session.show(id, source: .face)
        }
    }
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
                    .frame(height: 40)
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
            Button {
                session.showCalendarByTap()
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(session.activeID == nil ? accent.opacity(0.16) : Color(.tertiarySystemFill), in: .rect(cornerRadius: 18))
                    .foregroundStyle(session.activeID == nil ? accent : .primary)
            }
            .buttonStyle(KidPressStyle())
            .accessibilityLabel("Family calendar")

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
                            session.show(person.id, source: .tap)
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
                    Text("Kiosk")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave Kiosk Mode")
        }
        .padding(.vertical, 22)
        .frame(width: 112)
        .background(Color(.secondarySystemGroupedBackground).ignoresSafeArea())
        .animation(.smooth, value: session.activeID)
    }

    private var active: Member? { people.first { $0.id == session.activeID } }
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
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 40, height: 40)
                        Text("Calendar\nin \(Int(left.rounded(.up))) s")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
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
                    ParentPINPad(title: "Enter the parent PIN to leave Kiosk Mode", tint: accent, onUnlock: onLeave)
                } else {
                    Text("Leave Kiosk Mode?")
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
                    Button("Cancel") { dismiss() }
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
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Leave Kiosk Mode")) ?? false
            if ok { onLeave() }
        }
    }
}
