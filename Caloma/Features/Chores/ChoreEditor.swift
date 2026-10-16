import SwiftData
import SwiftUI

/// New Chore and editing one: name and icon, who does it, how often, and what it's worth.
struct ChoreEditor: View {
    var chore: Chore?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(filter: #Predicate<Room> { !$0.isArchived }, sort: \Room.sortOrder) private var rooms: [Room]
    @AppStorage(SettingsKey.centsPer100) private var centsPer100 = 500
    @AppStorage(SettingsKey.allowanceOn) private var allowanceOn = true
    @AppStorage(SettingsKey.approvalsByDefault) private var approvalsByDefault = true

    @State private var title = ""
    @State private var symbol = "checkmark.circle"
    @State private var roomID: UUID?
    @State private var priority: ChorePriority = .unset
    @State private var addingRoom = false
    @State private var assignees: [UUID] = []
    @State private var rotates = false
    @State private var upForGrabs = false
    @State private var repeatRule: ChoreRepeat = .daily
    @State private var weekdayMask = 0
    @State private var startDate = Date.now
    @State private var points = 10
    @State private var requiresPhoto = false
    @State private var requiresApproval = true
    @State private var loaded = false
    @State private var confirmsDelete = false

    private var kids: [Member] { members.filter { $0.isKid && !$0.isArchived } }
    /// Kids first, then parents: anyone in the family can have chores.
    private var people: [Member] { kids + members.filter { !$0.isKid && !$0.isArchived } }
    private var words: PointWords { PointWords.current() }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && (upForGrabs || !assignees.isEmpty)
            && (repeatRule != .someDays || weekdayMask != 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: symbol, color: accent, size: 40)
                        TextField("Chore name", text: $title)
                            .font(.title3)
                    }
                } footer: {
                    Text("Short and clear. Kids see this name.")
                }

                Section("Icon") {
                    IconPicker(quick: SymbolSets.chores, selection: $symbol, color: accent, text: title)
                }

                Section {
                    if people.isEmpty {
                        Text("Add your family in Family first.").foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(people) { kid in
                                    Chip(title: kid.name, color: kid.color.color, isOn: assignees.contains(kid.id)) {
                                        toggle(kid.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollIndicators(.hidden)
                        // Up for grabs is open to every kid, so there's no one to pick.
                        .disabled(upForGrabs)
                        .opacity(upForGrabs ? 0.4 : 1)
                        .animation(.smooth, value: upForGrabs)
                    }
                    Toggle(isOn: $upForGrabs) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Up for Grabs")
                                Text("The first kid to finish gets the \(words.plural)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "hand.raised")
                        }
                    }
                    if assignees.count > 1 && !upForGrabs {
                        Toggle(isOn: $rotates) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text("Take Turns")
                                    Text(turnsDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                } header: {
                    Text("Assign To")
                } footer: {
                    if upForGrabs {
                        Text("Any kid can claim it. The first to finish gets the \(words.plural).")
                    } else if people.contains(where: { !$0.isKid && assignees.contains($0.id) }) {
                        Text("Parents' chores show on the board and the calendar, without \(words.plural).")
                    }
                }

                Section {
                    Picker(selection: $roomID) {
                        Text("No Room").tag(UUID?.none)
                        ForEach(rooms) { room in
                            Label(room.name, systemImage: room.symbol).tag(UUID?.some(room.id))
                        }
                    } label: {
                        Label("Room", systemImage: "door.left.hand.open")
                    }
                    Button {
                        addingRoom = true
                    } label: {
                        Label("New Room", systemImage: "plus")
                    }
                } header: {
                    Text("Room")
                } footer: {
                    Text(UserDefaults.standard.bool(forKey: SettingsKey.homeKitAllowed)
                         ? "Optional. Shows on the chore so kids know where to go. Your Apple Home rooms are here too."
                         : "Optional. Shows on the chore so kids know where to go.")
                }

                Section {
                    Picker("Priority", selection: $priority) {
                        ForEach(ChorePriority.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Priority")
                } footer: {
                    Text(priorityFooter)
                }

                Section("Schedule") {
                    Picker("Repeat", selection: $repeatRule) {
                        ForEach(ChoreRepeat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    if repeatRule == .someDays {
                        WeekdayPicker(mask: $weekdayMask, color: accent)
                    }
                    DatePicker(repeatRule == .once ? "Day" : "Starts", selection: $startDate, displayedComponents: .date)
                }

                Section {
                    Stepper(value: $points, in: 1...500, step: points < 10 ? 1 : 5) {
                        HStack(spacing: 6) {
                            Image(systemName: words.symbol).foregroundStyle(Brand.star)
                            Text(words.count(points))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    Toggle(isOn: $requiresPhoto) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Ask for a Photo")
                                Text("Kids snap one when they finish").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "camera")
                        }
                    }
                    Toggle(isOn: $requiresApproval) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Needs a Parent's OK")
                                Text("\(words.title) land after you approve").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.shield")
                        }
                    }
                } header: {
                    Text("Reward")
                } footer: {
                    if allowanceOn {
                        Text("About \(money(RewardMath.cents(for: points, centsPer100: centsPer100))) in allowance at your family's rate.")
                    }
                }

                if chore != nil {
                    Section {
                        Button("Delete Chore", role: .destructive) { confirmsDelete = true }
                    } footer: {
                        Text("Points already earned stay with each kid.")
                    }
                }
            }
            .contentMargins(.bottom, 56, for: .scrollContent)
            .sheet(isPresented: $addingRoom) {
                RoomEditor(room: nil) { room in roomID = room.id }
            }
            .task {
                // Apple Home's rooms join the picker (once; the family can delete them).
                await HomeRoomImport.run(in: context)
            }
            .onChange(of: upForGrabs) { _, on in
                guard on else { return }
                withAnimation(.smooth) {
                    assignees = []
                    rotates = false
                }
            }
            .navigationTitle(chore == nil ? "New Chore" : "Edit Chore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) { save() }
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Delete \(title)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Chore", role: .destructive) {
                    chore?.isArchived = true
                    Persistence.save(context)
                    dismiss()
                }
            } message: {
                Text("It comes off everyone's board. Points already earned stay.")
            }
            .onAppear(perform: load)
        }
    }

    private var turnsDetail: String {
        let names = people.filter { assignees.contains($0.id) }.map(\.name)
        return names.formatted(.list(type: .and)) + " swap each week"
    }

    private func toggle(_ id: UUID) {
        if let index = assignees.firstIndex(of: id) {
            assignees.remove(at: index)
        } else {
            assignees.append(id)
        }
        if assignees.count < 2 { rotates = false }
    }

    private func money(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let chore {
            title = chore.title
            symbol = chore.symbol
            assignees = chore.assigneeIDs
            rotates = chore.rotates
            upForGrabs = chore.upForGrabs
            repeatRule = chore.repeatRule
            weekdayMask = chore.weekdayMask
            startDate = chore.startDate
            points = chore.points
            requiresPhoto = chore.requiresPhoto
            requiresApproval = chore.requiresApproval
            roomID = chore.roomID
            priority = chore.priority
        } else {
            requiresApproval = approvalsByDefault
            if kids.count == 1, let only = kids.first { assignees = [only.id] }
            let weekday = Calendar.current.component(.weekday, from: .now)
            weekdayMask = ChoreMath.bit(forWeekday: weekday)
        }
    }

    private var priorityFooter: String {
        switch priority {
        case .unset: "Optional. Higher priority chores come first on the board and in Kid View."
        case .low: "Comes after the more important chores."
        case .medium: "Comes first on the board. Kid View marks it Important."
        case .high: "Comes first of all. Kid View tells the kid to do it first."
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespaces)
        let target: Chore
        if let chore {
            target = chore
        } else {
            target = Chore(title: name, symbol: symbol, points: points)
            context.insert(target)
        }
        target.title = name
        target.symbol = symbol
        // Keep everyone in family order.
        target.assigneeIDs = people.map(\.id).filter { assignees.contains($0) }
        target.upForGrabs = upForGrabs
        target.rotates = rotates && assignees.count > 1 && !upForGrabs
        target.repeatRule = repeatRule
        target.weekdayMask = weekdayMask
        target.startDate = Calendar.current.startOfDay(for: startDate)
        target.points = points
        target.requiresPhoto = requiresPhoto
        target.requiresApproval = requiresApproval
        target.roomID = roomID
        target.priority = priority
        Persistence.save(context)
        dismiss()
    }
}

/// Seven round day buttons, Sunday first (or the calendar's first day).
struct WeekdayPicker: View {
    @Binding var mask: Int
    var color: Color

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let names = calendar.weekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack {
            ForEach(order, id: \.self) { weekday in
                let bit = ChoreMath.bit(forWeekday: weekday)
                let on = mask & bit != 0
                Button {
                    mask ^= bit
                } label: {
                    Text(symbols[weekday - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? AnyShapeStyle(color) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[weekday - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
                if weekday != order.last { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ChoreEditor(chore: nil)
        .previewEnvironment()
}
