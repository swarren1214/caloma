import SwiftData
import SwiftUI

/// New Chore Group and editing one: its name, which chores are in it, how the people in it
/// share them, how often the turn moves on, and the order they go in.
struct ChoreGroupEditor: View {
    var group: ChoreGroup?
    /// Starts a new group from a room: its name, icon and chores.
    var roomID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var groups: [ChoreGroup]
    @Query(filter: #Predicate<Chore> { !$0.isArchived }, sort: \Chore.sortOrder) private var chores: [Chore]
    @Query(filter: #Predicate<Room> { !$0.isArchived }, sort: \Room.sortOrder) private var rooms: [Room]

    @State private var name = ""
    @State private var symbol = "square.stack.3d.up"
    @State private var color = HearthColorChoice.palette("orange")
    @State private var choreIDs: Set<UUID> = []
    @State private var mode: RotationMode = .turns
    @State private var period: RotationPeriod = .week
    @State private var weekday = 0
    /// The people in it, in turn order.
    @State private var order: [UUID] = []
    @State private var loaded = false
    @State private var pickingIcon = false
    @State private var confirmsDelete = false
    @State private var showsAllChores = false

    private var people: [Member] {
        members.filter { $0.isKid && !$0.isArchived } + members.filter { !$0.isKid && !$0.isArchived }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !order.isEmpty
    }

    /// Chores worth listing: not up for grabs, not part of a calendar event's get-ready.
    private var candidates: [Chore] {
        chores.filter { !$0.upForGrabs && $0.eventID == nil }
            .sorted { lhs, rhs in
                // This group's chores and the room's first, then the rest.
                let l = choreIDs.contains(lhs.id) ? 0 : (lhs.roomID != nil && lhs.roomID == roomFocus ? 1 : 2)
                let r = choreIDs.contains(rhs.id) ? 0 : (rhs.roomID != nil && rhs.roomID == roomFocus ? 1 : 2)
                return (l, lhs.sortOrder, lhs.title) < (r, rhs.sortOrder, rhs.title)
            }
    }

    private var roomFocus: UUID? { group?.roomID ?? roomID }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        HearthIconTile(icon: symbol, color: color, size: 40)
                        TextField("Group name", text: $name)
                            .font(.title3)
                            .textInputAutocapitalization(.words)
                    }
                    Button { pickingIcon = true } label: {
                        HearthIconColorLabel(icon: symbol, color: color)
                    }
                    .hearthIconColorPicker(isPresented: $pickingIcon, title: name, caption: "Chore Group", context: .chore, icon: $symbol, color: $color)
                } footer: {
                    Text("Like Kitchen, Bathrooms or Pets.")
                }

                choresSection

                Section {
                    ForEach(RotationMode.allCases) { option in
                        Button {
                            withAnimation(.smooth) { mode = option }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.symbol)
                                    .frame(width: 28)
                                    .foregroundStyle(color.color)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.title).foregroundStyle(.primary)
                                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mode == option {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(color.color)
                                }
                            }
                        }
                        .accessibilityAddTraits(mode == option ? .isSelected : [])
                    }
                } header: {
                    Text("How They Share It")
                }

                if mode != .everyone {
                    Section {
                        Picker("Switch", selection: $period) {
                            ForEach(RotationPeriod.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                        if period.usesWeekday {
                            SwitchDayPicker(weekday: $weekday)
                        }
                    } header: {
                        Text("Switch")
                    } footer: {
                        Text(switchFooter)
                    }
                }

                membersSection

                if mode != .everyone && order.count > 1 {
                    previewSection
                }

                if group != nil {
                    Section {
                        Button("Delete Group", role: .destructive) { confirmsDelete = true }
                    } footer: {
                        Text("Its chores stay on the board, rotating as they do now.")
                    }
                }
            }
            .contentMargins(.bottom, 56, for: .scrollContent)
            .navigationTitle(group == nil ? "New Chore Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .alert("Delete \(name)?", isPresented: $confirmsDelete) {
                Button("Delete Group", role: .destructive) {
                    if let group {
                        Rotations.delete(group, chores: chores)
                        Persistence.save(context)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its chores stay on the board, rotating as they do now.")
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Chores

    private var choresSection: some View {
        let list = candidates
        let visible = showsAllChores ? list : Array(list.prefix(max(8, choreIDs.count)))
        return Section {
            if list.isEmpty {
                Text("Add some chores first, then group them here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(visible) { chore in
                let on = choreIDs.contains(chore.id)
                let elsewhere = chore.groupID.flatMap { id in groups.first { $0.id == id && !$0.isArchived && $0.id != group?.id } }
                Button {
                    if on { choreIDs.remove(chore.id) } else { choreIDs.insert(chore.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(on ? color.color : Color(.tertiaryLabel))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chore.title).foregroundStyle(.primary)
                            if let elsewhere {
                                Text("In \(elsewhere.name)").font(.caption).foregroundStyle(.secondary)
                            } else if let room = rooms.first(where: { $0.id == chore.roomID }) {
                                Text(room.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(chore.points)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Image(systemName: PointWords.current().symbol)
                            .font(.caption)
                            .foregroundStyle(Brand.star)
                    }
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if list.count > visible.count {
                Button("Show All \(list.count) Chores") { withAnimation { showsAllChores = true } }
            }
        } header: {
            Text("Chores")
        } footer: {
            Text("Each chore keeps its own \(PointWords.current().plural), so bigger jobs can be worth more. Picking a chore that’s in another group moves it here.")
        }
    }

    // MARK: People

    private var membersSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(people) { person in
                        Chip(title: person.name, color: person.color.color, isOn: order.contains(person.id)) {
                            withAnimation(.smooth) {
                                if let index = order.firstIndex(of: person.id) {
                                    order.remove(at: index)
                                } else {
                                    order.append(person.id)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)

            if mode != .everyone {
                ForEach(Array(order.enumerated()), id: \.element) { position, id in
                    if let person = people.first(where: { $0.id == id }) {
                        HStack(spacing: 12) {
                            Text("\(position + 1)")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            MemberAvatar(person, size: 30)
                            Text(person.name)
                            Spacer()
                            if position > 0 {
                                Button {
                                    withAnimation(.smooth) { order.swapAt(position, position - 1) }
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .font(.body.weight(.semibold))
                                        .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Move \(person.name) up")
                            }
                        }
                    }
                }
            }
        } header: {
            Text(mode == .everyone ? "Who’s In It" : "Who’s In It, in Order")
        } footer: {
            if mode == .turns, let first = order.first.flatMap({ id in people.first { $0.id == id } }) {
                Text("\(first.name) goes first, starting \(period == .day ? "today" : "this \(period == .month ? "month" : "week")").")
            } else if mode == .split {
                Text("With more chores than people, some get two. Everyone moves along one each turn.")
            }
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        let rule = draftRule
        let current = RotationMath.periodIndex(of: .now, rule: rule)
        let titles = selectedChores.map(\.title)
        return Section("Preview") {
            ForEach(current..<(current + 4), id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    Text(RotationText.turnName(index, current: current, rule: rule))
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 104, alignment: .leading)
                    if mode == .turns {
                        let id = RotationMath.person(ofPeriod: index, members: order, adjustments: rule.adjustments)
                        Text(id.flatMap { id in people.first { $0.id == id }?.name } ?? "")
                            .font(.subheadline)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(titles.enumerated()), id: \.offset) { slot, title in
                                let ids = RotationMath.assignees(slot: slot, ofPeriod: index, members: order, rule: rule)
                                Text("\(ids.compactMap { id in people.first { $0.id == id }?.name }.first ?? ""): \(title)")
                                    .font(.subheadline)
                            }
                            if titles.isEmpty {
                                Text("Pick some chores to see who gets which.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// In slot order: the group's chores as they are, then ones joining.
    private var selectedChores: [Chore] {
        func slot(_ chore: Chore) -> Int { chore.groupID == group?.id && group != nil ? chore.rotationSlot : Rotations.joiningSlot }
        return chores.filter { choreIDs.contains($0.id) }
            .sorted { (slot($0), $0.createdAt) < (slot($1), $1.createdAt) }
    }

    /// The rule as it will be: a changed rotation starts over this turn with the first person.
    private var draftRule: RotationRule {
        if let group, !rotationChanged(group) { return group.rule }
        return RotationRule(mode: mode, period: period, weekday: weekday, anchor: Rotations.freshAnchor())
    }

    private func rotationChanged(_ group: ChoreGroup) -> Bool {
        group.mode != mode || group.period != period || !RotationMath.sameWeekday(group.weekday, weekday) || group.memberIDs != order
    }

    private var switchFooter: String {
        switch period {
        case .day: "The turn moves on every morning."
        case .week: "The turn moves on once a week, on this day."
        case .twoWeeks: "Each person has it for two weeks, switching on this day."
        case .month: "The turn moves on the first of each month."
        }
    }

    // MARK: Load and save

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let group {
            name = group.name
            symbol = group.symbol
            color = group.color
            mode = group.mode
            period = group.period
            weekday = group.weekday
            // Anyone who's left the family drops out of the order.
            order = group.memberIDs.filter { id in people.contains { $0.id == id } }
            choreIDs = Set(Rotations.chores(in: group, from: chores).map(\.id))
        } else {
            let kids = members.filter { $0.isKid && !$0.isArchived }
            order = kids.map(\.id)
            if let roomID, let room = rooms.first(where: { $0.id == roomID }) {
                name = room.name
                symbol = room.symbol
                choreIDs = Set(chores.filter { $0.roomID == roomID && !$0.upForGrabs && $0.eventID == nil }.map(\.id))
            }
        }
    }

    private func save() {
        let target: ChoreGroup
        if let group {
            target = group
        } else {
            let next = (groups.filter { !$0.isArchived }.map(\.sortOrder).max() ?? -1) + 1
            target = ChoreGroup(name: name, symbol: symbol, colorRaw: color.storage, sortOrder: next)
            target.roomID = roomID
            context.insert(target)
        }
        let restarts = group == nil || rotationChanged(target)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.symbol = symbol
        target.colorRaw = color.storage
        target.mode = mode
        target.period = period
        target.weekday = weekday
        target.memberIDs = order
        if restarts {
            // A new order or schedule starts over: the first person has this turn.
            target.anchor = Rotations.freshAnchor()
            target.adjustRaw = ""
        }
        // Chores leaving keep rotating as they were; chores joining take on the group's rotation.
        for chore in chores {
            if choreIDs.contains(chore.id) {
                Rotations.join(chore, to: target)
            } else if chore.groupID == target.id {
                chore.groupID = nil
            }
        }
        Rotations.apply(target, to: chores)
        // Groups that lost chores renumber the ones they have left.
        for other in groups where other.id != target.id && !other.isArchived {
            Rotations.apply(other, to: chores)
        }
        Persistence.save(context)
        dismiss()
    }
}

/// The day a weekly rotation switches: seven round buttons, one picked.
struct SwitchDayPicker: View {
    @Binding var weekday: Int
    @Environment(\.accent) private var accent

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let names = calendar.weekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        let picked = weekday == 0 ? calendar.firstWeekday : weekday
        HStack {
            ForEach(order, id: \.self) { day in
                let on = picked == day
                Button {
                    weekday = day
                } label: {
                    Text(symbols[day - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? AnyShapeStyle(accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch on \(names[day - 1])")
                .accessibilityAddTraits(on ? .isSelected : [])
                if day != order.last { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 4)
    }
}
