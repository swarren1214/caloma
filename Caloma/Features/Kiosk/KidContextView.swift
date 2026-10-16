import SwiftData
import SwiftUI

/// What Kid View needs to know when it's on the wall: there's no kid row or Parent button (the
/// rail does that), and a "Not Ella?" button for when the wrong kid is showing.
struct KioskKidOptions {
    var onNotMe: () -> Void
}

/// A kid's screen in Kiosk Mode: the Kid View exactly as it is, plus what's next and what to
/// bring. When a face brought them here, a hello slides in at the top for a few seconds.
struct KidContextView: View {
    var kid: Member

    @Environment(KioskSession.self) private var session
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var greeting = false
    @State private var picking = false

    private var kids: [Member] { members.filter { $0.isKid && !$0.isArchived } }

    var body: some View {
        NavigationStack {
            KidDayView(
                kid: kid,
                kids: kids,
                onPick: { session.show($0.id, source: .tap) },
                onLeave: {},
                kiosk: KioskKidOptions(onNotMe: { picking = true })
            )
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(kid.color.color)
        .overlay(alignment: .top) {
            if greeting {
                KioskHello(kid: kid) { picking = true }
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: session.arrival) {
            guard session.source == .face else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.35)) { greeting = true }
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.smooth) { greeting = false }
        }
        .sheet(isPresented: $picking) {
            WhoIsHerePicker(current: kid.id)
        }
    }
}

/// "There you are, Ella!" with a wave, jobs left and stars to go, and Not me.
private struct KioskHello: View {
    var kid: Member
    var onNotMe: () -> Void

    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var wave = false

    var body: some View {
        let family = FamilySnapshot(members: members, chores: chores, completions: completions, points: [])
        let left = family.items(for: kid).filter { $0.status == .open && (!$0.chore.upForGrabs || $0.memberID == kid.id) }.count
        HStack(spacing: 14) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 28))
                .foregroundStyle(Brand.starBright)
                .rotationEffect(.degrees(wave ? 14 : -8), anchor: .bottomTrailing)
                .animation(.easeInOut(duration: 0.25).repeatCount(5, autoreverses: true), value: wave)
            VStack(alignment: .leading, spacing: 1) {
                Text("There you are, \(kid.name)!")
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                Text(left == 0 ? "All your jobs are done!" : (left == 1 ? "1 job left today" : "\(left) jobs left today"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Button("Not me", action: onNotMe)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .foregroundStyle(kid.color.color)
                .background(kid.color.color.opacity(0.14), in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(kid.color.color.opacity(0.4), lineWidth: 3))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
        .onAppear { wave = true }
        .accessibilityElement(children: .contain)
    }
}

/// The kid's next event this week and what to bring, beside the progress track.
struct KioskUpNext: View {
    var kid: Member

    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived && $0.showInKidView }) private var events: [FamilyEvent]

    var body: some View {
        if let next = next {
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text(next.start.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                    Text(next.start.formatted(.dateTime.day()))
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(kid.color.color, in: .rect(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("UP NEXT")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(kid.color.color)
                    Text(next.event.isAllDay ? next.event.title : "\(next.event.title) · \(next.start.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                    if !next.event.bring.isEmpty {
                        Text("Bring " + next.event.bring.formatted(.list(type: .and)))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
            .accessibilityElement(children: .combine)
        }
    }

    /// The first thing still to come in the next week.
    private var next: EventOccurrence? {
        let now = Date.now
        let mine = events.map(\.record).filter { $0.includes(kid.id) }
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: now) else { return nil }
        return CalendarMath.occurrences(of: mine, from: now, through: end)
            .filter { $0.end > now }
            .sorted(by: CalendarMath.order)
            .first
    }
}

/// The small "Not Ella?" button in a kid's header on the wall.
struct KioskNotMeButton: View {
    var name: String
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: 0x34C759))
                    .frame(width: 8, height: 8)
                Text("Not \(name)?")
            }
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(KidPressStyle())
    }
}

/// "Who's here?": every face in the family. Picking one opens their screen.
struct WhoIsHerePicker: View {
    var current: UUID?

    @Environment(KioskSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Member.sortOrder) private var members: [Member]

    var body: some View {
        let people = members.filter { !$0.isArchived }
        VStack(spacing: 22) {
            Text("Who's here?")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 18)], spacing: 18) {
                ForEach(people) { person in
                    Button {
                        session.show(person.id, source: .picker)
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            MemberAvatar(person, size: 84)
                                .padding(4)
                                .overlay(Circle().strokeBorder(person.color.color, lineWidth: 4))
                                .background {
                                    if person.id == current { Circle().fill(person.color.color.opacity(0.25)).padding(-5) }
                                }
                            Text(person.name)
                                .font(.system(size: 17, weight: .heavy, design: .rounded))
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(KidPressStyle())
                }
            }
            Text("Grown-ups still need their PIN to approve anything.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .presentationDetents([.medium])
    }
}
