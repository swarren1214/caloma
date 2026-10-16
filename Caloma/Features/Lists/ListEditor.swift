import SwiftData
import SwiftUI

/// New List and Edit List: the name and icon, when it's needed and what it's for, and the
/// things on it, each given to someone, to a few people (either can bring it), or to everyone
/// (each brings their own). Nothing is saved until Done.
struct ListEditor: View {
    var target: ListEditorTarget

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived }) private var events: [FamilyEvent]
    @Query private var allItems: [FamilyListItem]

    @State private var title = ""
    @State private var symbol = "suitcase.fill"
    @State private var hasDue = false
    @State private var due = ListEditor.defaultDue()
    /// The event occurrence it's for ("<event>@<start>"), or "".
    @State private var occurrenceID = ""
    /// What the event picker said when the list was opened, to tell whether it was changed.
    @State private var loadedOccurrenceID = ""
    @State private var clears = true
    @State private var things: [Thing] = []
    @State private var draft = ""
    /// Who the next thing goes to: empty means everyone.
    @State private var picked: Set<UUID> = []
    @State private var loaded = false
    @State private var confirmingDelete = false
    @FocusState private var addFocused: Bool

    /// One thing on the list while editing.
    struct Thing: Identifiable, Equatable {
        var id = UUID()
        /// The saved item, when it was already on the list.
        var itemID: UUID?
        var title: String
        var everyone: Bool
        var assignees: [UUID]
        /// Its icon, kept when the name stays the same.
        var symbol: String = ""
    }

    private var family: [Member] { members.filter { !$0.isArchived } }
    private var existing: FamilyList? {
        if case .edit(let list) = target { return list }
        return nil
    }

    static let quickSymbols = [
        "suitcase.fill", "tent.fill", "beach.umbrella.fill", "car.fill", "airplane", "backpack.fill",
        "gift.fill", "birthday.cake.fill", "party.popper.fill", "cart.fill", "fork.knife", "house.fill",
        "graduationcap.fill", "figure.skiing.downhill", "sun.max.fill", "checklist",
    ]

    private static func defaultDue() -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        return calendar.date(bySettingHour: 17, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Upcoming events in the next two months, to tie the list to.
    private var upcoming: [EventOccurrence] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let later = calendar.date(byAdding: .day, value: 60, to: today) ?? today
        return CalendarMath.occurrences(of: events.map(\.record), from: today, through: later)
            .filter { $0.end > .now }
            .sorted { $0.start < $1.start }
            .prefix(40)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: symbol, color: accent, size: 44)
                        TextField("List name", text: $title, prompt: Text("Bear Lake Trip"))
                            .font(.title3.weight(.semibold))
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)
                            .onSubmit { addFocused = true }
                    }
                    IconPicker(quick: Self.quickSymbols, selection: $symbol, color: accent, text: title)
                }

                Section {
                    Toggle("Needed By", isOn: $hasDue.animation())
                    if hasDue {
                        DatePicker("Date", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    }
                    Picker("For an Event", selection: $occurrenceID) {
                        Text("None").tag("")
                        ForEach(upcoming) { occurrence in
                            Text("\(occurrence.event.title) · \(occurrence.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                                .tag(occurrence.id)
                        }
                    }
                    Toggle(isOn: $clears) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clear When It's Over")
                            Text(clearsNote)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Everyone sees their part in Kid View and on the Family Board until it's done.")
                }

                Section {
                    if things.isEmpty {
                        Text("Add things below. Tap who's bringing each one first.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($things) { $thing in
                        ThingRow(thing: $thing, family: family)
                    }
                    .onDelete { things.remove(atOffsets: $0) }
                    .onMove { things.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text(thingsHeader)
                }

                if let existing {
                    Section {
                        Button("Finish List") {
                            persist()
                            FamilyLists.finish(existing, in: context)
                            dismiss()
                        }
                        Button("Delete List", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New List" : "Edit List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { addBar }
            .confirmationDialog("Delete \(title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete List", role: .destructive) {
                    if let existing { FamilyLists.delete(existing, in: context) }
                    dismiss()
                }
            } message: {
                Text("It comes off everyone's screens and won't be offered to use again.")
            }
            .onAppear(perform: load)
        }
    }

    private var clearsNote: String {
        if !occurrenceID.isEmpty { return "Off everyone's screens when the event ends" }
        if hasDue { return "Off everyone's screens the day after it's needed" }
        return "Pick a date or an event, or finish it yourself"
    }

    private var thingsHeader: String {
        let toPack = things.reduce(0) { $0 + ($1.everyone ? family.count : 1) }
        guard !things.isEmpty else { return "Things" }
        return "\(things.count) \(things.count == 1 ? "thing" : "things") · \(toPack) to check off"
    }

    // MARK: Adding

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Add something…", text: $draft)
                    .focused($addFocused)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.body.weight(.bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add to list")
            }
            Text("WHO'S BRINGING IT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chip("Everyone", color: Color(.label), on: picked.isEmpty) { picked = [] }
                    ForEach(family) { person in
                        chip(person.name, color: person.color.color, on: picked.contains(person.id)) {
                            if picked.contains(person.id) { picked.remove(person.id) } else { picked.insert(person.id) }
                        }
                    }
                }
                // Room for the outlines, so the scroll view doesn't shave them off.
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func chip(_ label: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                // On a picked chip the name sits on its color: the page color for Everyone (whose
                // color is the label color, light in dark mode), white on everyone else's.
                .foregroundStyle(on ? (color == Color(.label) ? Color(.systemBackground) : .white) : color)
                .background {
                    if on {
                        Capsule().fill(color)
                    } else {
                        Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let assignees = family.map(\.id).filter { picked.contains($0) }
        withAnimation(.snappy) {
            things.append(Thing(title: name, everyone: assignees.isEmpty, assignees: assignees))
        }
        draft = ""
        addFocused = true
    }

    // MARK: Loading and saving

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case .reuse(let old) = target {
            title = old.title
            symbol = old.symbol
            clears = old.clearsWhenOver
            things = FamilyLists.items(of: old, in: allItems).map {
                Thing(title: $0.title, everyone: $0.everyone, assignees: $0.assigneeIDs, symbol: $0.symbol)
            }
            return
        }
        guard let list = existing else { return }
        title = list.title
        symbol = list.symbol
        if let dueAt = list.dueAt {
            hasDue = true
            due = dueAt
        }
        clears = list.clearsWhenOver
        if let eventID = list.eventID {
            occurrenceID = upcoming.first { $0.event.id == eventID && $0.end == list.endsAt }?.id
                ?? upcoming.first { $0.event.id == eventID }?.id
                ?? ""
            loadedOccurrenceID = occurrenceID
        }
        things = FamilyLists.items(of: list, in: allItems).map {
            Thing(itemID: $0.id, title: $0.title, everyone: $0.everyone, assignees: $0.assigneeIDs, symbol: $0.symbol)
        }
    }

    private func save() {
        persist()
        dismiss()
    }

    /// Writes the list and its things.
    private func persist() {
        // A thing typed but not added yet still counts.
        add()
        let list: FamilyList
        if let existing {
            list = existing
        } else {
            list = FamilyList(title: "")
            context.insert(list)
        }
        list.title = title.trimmingCharacters(in: .whitespaces)
        list.symbol = symbol
        list.dueAt = hasDue ? due : nil
        if let occurrence = upcoming.first(where: { $0.id == occurrenceID }) {
            list.eventID = occurrence.event.id
            list.endsAt = FamilyLists.end(dueAt: list.dueAt, eventEnd: occurrence.end)
        } else if occurrenceID.isEmpty && (occurrenceID != loadedOccurrenceID || list.eventID == nil) {
            // No event: it's over the day after it's due.
            list.eventID = nil
            list.endsAt = FamilyLists.end(dueAt: list.dueAt, eventEnd: nil)
        }
        // Otherwise the event is further out than the picker shows: the link stays as it was.
        list.clearsWhenOver = clears

        // Things: removed (or emptied) ones go, kept ones update, new ones are added and get an
        // icon from their name.
        let saved = FamilyLists.items(of: list, in: allItems)
        let kept = things.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        let keeping = Set(kept.compactMap(\.itemID))
        for item in saved where !keeping.contains(item.id) {
            FamilyLists.delete(item, in: context)
        }
        var needIcons: [FamilyListItem] = []
        for (index, thing) in kept.enumerated() {
            let name = thing.title.trimmingCharacters(in: .whitespaces)
            let assignees = thing.everyone ? [] : thing.assignees
            if let id = thing.itemID, let item = saved.first(where: { $0.id == id }) {
                if item.title != name { item.symbol = "" }
                if item.everyone != thing.everyone || item.assigneeIDs != assignees {
                    // Check-offs by anyone it's no longer for don't count anymore.
                    FamilyLists.dropChecks(on: item, keeping: thing.everyone ? family.map(\.id) : assignees, in: context)
                }
                item.title = name
                item.everyone = thing.everyone
                item.assigneeIDs = assignees
                item.sortOrder = index
                if item.symbol.isEmpty { needIcons.append(item) }
            } else {
                let item = FamilyListItem(listID: list.id, title: name, everyone: thing.everyone, assignees: assignees, sortOrder: index)
                item.symbol = thing.symbol
                context.insert(item)
                if item.symbol.isEmpty { needIcons.append(item) }
            }
        }
        Persistence.save(context)
        for item in needIcons {
            ListItemIcon.assign(to: item, in: context)
        }
    }
}

/// A thing in the editor: its name, who's bringing it, and a menu to change who.
private struct ThingRow: View {
    @Binding var thing: ListEditor.Thing
    var family: [Member]

    private var people: [Member] {
        thing.everyone ? family : family.filter { thing.assignees.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Thing", text: $thing.title)
                Text(whoLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Menu {
                Button {
                    thing.everyone = true
                    thing.assignees = []
                } label: {
                    Label("Everyone Brings Their Own", systemImage: thing.everyone ? "checkmark" : "person.3")
                }
                Section("Or Give It To") {
                    ForEach(family) { person in
                        let on = !thing.everyone && thing.assignees.contains(person.id)
                        Button {
                            var ids = thing.everyone ? [] : thing.assignees
                            if on { ids.removeAll { $0 == person.id } } else { ids.append(person.id) }
                            thing.everyone = ids.isEmpty
                            thing.assignees = ids
                        } label: {
                            Label(person.name, systemImage: on ? "checkmark" : "person")
                        }
                    }
                }
            } label: {
                FaceStack(people: people, total: family.count, everyone: thing.everyone)
            }
            .accessibilityLabel("Who's bringing \(thing.title): \(whoLabel)")
        }
    }

    private var whoLabel: String {
        if thing.everyone { return "Everyone brings their own" }
        let names = people.map(\.name)
        switch names.count {
        case 0: return "Nobody yet"
        case 1: return names[0]
        default: return names.formatted(.list(type: .or)) + ", either one"
        }
    }
}

/// Up to three overlapping faces, and "+2" for the rest.
private struct FaceStack: View {
    var people: [Member]
    var total: Int
    var everyone: Bool

    var body: some View {
        HStack(spacing: -8) {
            ForEach(people.prefix(3)) { person in
                MemberAvatar(person, size: 30)
                    .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2))
            }
            if people.count > 3 {
                Text("+\(people.count - 3)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2))
            }
        }
    }
}
