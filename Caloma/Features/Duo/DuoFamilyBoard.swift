import PencilKit
import SwiftData
import SwiftUI

/// iPhone Duo, standing as a tent on the counter: the "Family Board" glance board. Everyone's
/// ring for today, what's next on the calendar, and tonight's dinner from BigTable (with
/// Hearth+), big enough to read across the kitchen, with no bars. Kid View and Add a Note sit on
/// the rail. The system can't tell Tent from Closed, so it opens from Home's toolbar
/// (`DuoFamilyBoardButton`), never by itself.
///
/// Not the iPad wall's Family Board (Kiosk Mode): this is a read-only glance, so it isn't behind
/// Caloma Plus. Add a Note sends a wall note, which is (`CalomaPlus.whiteboard`).
struct DuoFamilyBoard: View {
    /// Close the board and open Kid View (the app root presents Kid View, so the board goes first).
    var onKidView: () -> Void

    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]
    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived }) private var events: [FamilyEvent]
    @State private var addingNote = false
    @State private var showsPaywall = false
    private var link: HearthLink { HearthLink.shared }

    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points)
    }

    var body: some View {
        let family = family
        HearthGlanceBoard("Family Board", color: Brand.defaultAccent) {
            VStack(spacing: 18) {
                rings(family)
                    .frame(maxHeight: .infinity)
                HStack(alignment: .top, spacing: 18) {
                    next
                        .frame(maxWidth: .infinity, alignment: .leading)
                    dinner
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: onKidView) {
                    Label("Kid View", systemImage: "figure.and.child.holdinghands")
                }
                Button {
                    if CalomaPlus.isUnlocked { addingNote = true } else { showsPaywall = true }
                } label: {
                    Label("Add a Note", systemImage: "note.text.badge.plus")
                }
            }
        }
        // White over the app's color, Close included (the root tint is the app's color).
        .tint(.white)
        .sheet(isPresented: $addingNote) {
            DuoNoteSheet(people: members.filter { !$0.isArchived })
                .tint(Brand.defaultAccent)
        }
        .hearthPaywall(isPresented: $showsPaywall, feature: CalomaPlus.whiteboard)
    }

    // MARK: Everyone's ring

    @ViewBuilder
    private func rings(_ family: FamilySnapshot) -> some View {
        let people = family.kids
        if people.isEmpty {
            Text("Add the kids in Household to see their rings here.")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 16) {
                ForEach(people) { kid in
                    let progress = family.progress(for: kid)
                    VStack(spacing: 6) {
                        ZStack {
                            ProgressRing(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), color: .white, lineWidth: 10)
                            MemberAvatar(kid, size: 64)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 120, maxHeight: 120)
                        Text(kid.name)
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(progress.total == 0 ? "All clear" : "\(progress.done) of \(progress.total)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(progress.total == 0 ? "\(kid.name), nothing today" : "\(kid.name), \(progress.done) of \(progress.total) done")
                }
            }
        }
    }

    // MARK: What's next

    private var next: some View {
        let now = Date.now
        let end = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        let upcoming = CalendarMath.occurrences(of: events.map(\.record), from: now, through: end)
            .filter { !$0.event.isAllDay && $0.end > now }
            .sorted(by: CalendarMath.order)
            .first
        return VStack(alignment: .leading, spacing: 4) {
            Text("NEXT")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .opacity(0.8)
            if let upcoming {
                Text(upcoming.event.title)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                Text(when(upcoming))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.9)
            } else {
                Text("Nothing else today")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func when(_ occurrence: EventOccurrence) -> String {
        let day = Calendar.current.isDateInToday(occurrence.start) ? "Today" : "Tomorrow"
        return "\(day) · \(occurrence.start.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Dinner

    @ViewBuilder
    private var dinner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DINNER")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .opacity(0.8)
            if let meal = link.dinner(on: .now) {
                Text(meal.title)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                Text(meal.isDineOut ? "Eating out" : "From BigTable")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .opacity(0.9)
            } else if link.hasLockedMealPlan {
                Text("BigTable's plan shows here with Hearth+")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
            } else {
                Text("Not planned")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Add a Note from the Family Board: draw a note with a finger and pick who it's for. It's a
/// wall note (the same as the whiteboard's "Show this when they walk up"), for today, so it pops
/// up on the wall iPad when they walk up and stays in the whiteboard's list.
struct DuoNoteSheet: View {
    var people: [Member]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var drawing = PKDrawing()
    @State private var audience: Set<UUID> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(people) { person in
                            let on = audience.contains(person.id)
                            Button {
                                if on { audience.remove(person.id) } else { audience.insert(person.id) }
                            } label: {
                                VStack(spacing: 4) {
                                    MemberAvatar(person, size: 40)
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(on ? person.color.color : .clear, lineWidth: 3))
                                    Text(person.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(on ? .primary : .secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("For \(person.name)")
                            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                PencilCanvas(drawing: $drawing, tool: .pen(.black, width: 5), onPencilTap: nil)
                    // Sticky-note paper stays light, in dark mode too.
                    .environment(\.colorScheme, .light)
                    .background(WallNotePaper.color)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        if !drawing.hasInk {
                            Text("Write a note")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.black.opacity(0.25))
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(16)
            .navigationTitle("Add a Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Send") { send() }
                        .disabled(!drawing.hasInk || audience.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func send() {
        let note = WallNote(drawing: drawing.dataRepresentation(), from: nil, audience: people.map(\.id).filter { audience.contains($0) }, keep: .today, pinned: true)
        context.insert(note)
        Persistence.save(context)
        dismiss()
    }
}
