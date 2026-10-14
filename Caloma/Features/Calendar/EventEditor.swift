import SwiftData
import SwiftUI

/// New Event and editing one: what, who's going and who's driving, when, and the kids' side
/// (what to bring, Kid View, a countdown, and a get-ready chore the night before).
struct EventEditor: View {
    var event: FamilyEvent?
    var day: Date
    /// For a new event: the time tapped on the calendar.
    var startAt: Date? = nil
    /// For a new event: tapped in the all-day row.
    var allDay = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]

    @State private var title = ""
    @State private var symbol = "calendar"
    @State private var location = ""
    @State private var notes = ""
    @State private var attendees: Set<UUID> = []
    @State private var driverID: UUID?
    @State private var isAllDay = false
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var repeatRule: EventRepeat = .never
    @State private var weekdayMask = 0
    @State private var endsRepeat = false
    @State private var repeatEnd = Date.now
    @State private var alertMinutes = -1
    @State private var bring: [String] = []
    @State private var newItem = ""
    @State private var showInKidView = true
    @State private var countsDown = false
    @State private var getReady = false
    @State private var loaded = false
    @State private var confirmsDelete = false

    private var people: [Member] { members.filter { !$0.isArchived } }
    private var parents: [Member] { people.filter { !$0.isKid } }
    private var kidsGoing: [Member] {
        people.filter { $0.isKid && (attendees.isEmpty || attendees.contains($0.id)) }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && (repeatRule != .weekly || weekdayMask != 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: symbol, color: leadColor, size: 40, filled: true)
                        TextField("Event name", text: $title)
                            .font(.title3.weight(.semibold))
                    }
                    Label {
                        TextField("Location", text: $location)
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Icon") {
                    IconPicker(quick: SymbolSets.events, selection: $symbol, color: leadColor)
                }

                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            Chip(title: "Everyone", color: accent, isOn: attendees.isEmpty, showsDot: false) {
                                withAnimation(.snappy) { attendees = [] }
                            }
                            ForEach(people) { member in
                                Chip(title: member.name, color: member.color.color, isOn: attendees.contains(member.id)) {
                                    withAnimation(.snappy) { toggle(member.id) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                    if !parents.isEmpty {
                        Picker(selection: $driverID) {
                            Text("No One").tag(UUID?.none)
                            ForEach(parents) { parent in
                                Text(parent.name).tag(UUID?.some(parent.id))
                            }
                        } label: {
                            Label("Who's Driving", systemImage: "car.fill")
                        }
                    }
                } header: {
                    Text("Who's Going")
                } footer: {
                    Text(driverID == nil ? "It shows in their color on the calendar." : "The driver gets the alert too, with where to go.")
                }

                Section("When") {
                    Toggle("All Day", isOn: $isAllDay.animation(.snappy))
                    DatePicker("Starts", selection: Binding(get: { start }, set: { moveStart(to: $0) }), displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $end, in: start..., displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
                    Picker("Repeat", selection: $repeatRule.animation(.snappy)) {
                        ForEach(EventRepeat.allCases) { Text($0.label).tag($0) }
                    }
                    if repeatRule == .weekly {
                        WeekdayPicker(mask: $weekdayMask, color: leadColor)
                    }
                    if repeatRule != .never {
                        Toggle("End Repeat", isOn: $endsRepeat.animation(.snappy))
                        if endsRepeat {
                            DatePicker("Last Day", selection: $repeatEnd, in: start..., displayedComponents: .date)
                        }
                    }
                    Picker("Alert", selection: $alertMinutes) {
                        ForEach(EventAlertChoice.all) { choice in
                            Text(choice.label).tag(choice.minutes)
                        }
                    }
                }

                if !kidsGoing.isEmpty {
                    kidsSection
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                if event != nil {
                    Section {
                        Button("Delete Event", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .contentMargins(.bottom, 56, for: .scrollContent)
            .navigationTitle(event == nil ? "New Event" : "Edit Event")
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
                Button("Delete Event", role: .destructive) {
                    if let event { Family.delete(event, in: context) }
                    dismiss()
                }
            } message: {
                Text(repeatRule == .never ? "It comes off everyone's calendar." : "Every day it repeats comes off everyone's calendar.")
            }
            .onAppear(perform: load)
        }
    }

    private var kidsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Remember to Bring")
                    Text("Kids tick these off in Kid View")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 8) {
                    ForEach(bring, id: \.self) { item in
                        Button {
                            withAnimation(.snappy) { bring.removeAll { $0 == item } }
                        } label: {
                            HStack(spacing: 6) {
                                Text(item)
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item)")
                    }
                }
                HStack {
                    TextField("Add something to bring", text: $newItem)
                        .submitLabel(.done)
                        .onSubmit(addItem)
                    Button("Add", action: addItem)
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.vertical, 4)
            Toggle(isOn: $showInKidView) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show in Kid View")
                    Text("On \(kidNames)'s day, with a big friendly card")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $countsDown) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Count Down to It")
                    Text("\"3 sleeps to go\" in Kid View")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $getReady) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Get-Ready Chore")
                    Text("\"Get ready for \(title.isEmpty ? "it" : title)\" the night before")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!Family.supportsGetReady(repeatRule))
        } header: {
            Text("For the Kids")
        } footer: {
            if !Family.supportsGetReady(repeatRule) {
                Text("Get-ready chores work for events that happen once, daily or weekly.")
            }
        }
    }

    private var kidNames: String {
        kidsGoing.map(\.name).formatted(.list(type: .and))
    }

    /// The icon's color: the one person going, or the accent.
    private var leadColor: Color {
        if attendees.count == 1, let member = people.first(where: { attendees.contains($0.id) }) {
            return member.color.color
        }
        if attendees.isEmpty { return accent }
        return people.first { attendees.contains($0.id) }?.color.color ?? accent
    }

    /// Moving the start moves the end with it, keeping the length.
    private func moveStart(to new: Date) {
        let length = max(end.timeIntervalSince(start), 0)
        start = new
        end = new.addingTimeInterval(length)
    }

    private func toggle(_ id: UUID) {
        if attendees.contains(id) { attendees.remove(id) } else { attendees.insert(id) }
        // Everyone ticked one by one is everyone.
        if attendees.count == people.count { attendees = [] }
    }

    private func addItem() {
        let item = newItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty, !bring.contains(item) else { return }
        withAnimation(.snappy) { bring.append(item) }
        newItem = ""
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let calendar = Calendar.current
        if let event {
            title = event.title
            symbol = event.symbol
            location = event.location
            notes = event.notes
            attendees = Set(event.attendeeIDs)
            driverID = event.driverID
            isAllDay = event.isAllDay
            start = event.start
            end = event.isAllDay ? (calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.end) : event.end
            repeatRule = event.repeatRule
            weekdayMask = event.weekdayMask == 0 ? ChoreMath.bit(forWeekday: calendar.component(.weekday, from: event.start)) : event.weekdayMask
            endsRepeat = event.repeatEnd != nil
            repeatEnd = event.repeatEnd ?? event.start
            alertMinutes = event.alertMinutes
            bring = event.bring
            showInKidView = event.showInKidView
            countsDown = event.countsDown
            getReady = event.getReadyChoreID != nil
        } else {
            if let startAt {
                // Where they tapped on the calendar.
                start = startAt
            } else {
                // The next whole hour on the day that was showing.
                let hour = calendar.component(.hour, from: .now) + 1
                let base = calendar.isDateInToday(day) ? min(hour, 20) : 16
                start = calendar.date(bySettingHour: base, minute: 0, second: 0, of: day) ?? day
            }
            isAllDay = allDay
            end = allDay ? start : start.addingTimeInterval(3600)
            weekdayMask = ChoreMath.bit(forWeekday: calendar.component(.weekday, from: start))
            repeatEnd = calendar.date(byAdding: .month, value: 3, to: start) ?? start
            alertMinutes = 60
        }
    }

    private func save() {
        let calendar = Calendar.current
        let target: FamilyEvent
        if let event {
            target = event
        } else {
            target = FamilyEvent(title: "", start: start, end: end)
            context.insert(target)
        }
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.symbol = symbol
        target.location = location.trimmingCharacters(in: .whitespaces)
        target.notes = notes
        target.attendeeIDs = people.map(\.id).filter { attendees.contains($0) }
        target.driverID = driverID
        target.isAllDay = isAllDay
        if isAllDay {
            // All-day events run from the start of the first day to the start of the day
            // after the last.
            let first = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: max(end, start))
            target.start = first
            target.end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        } else {
            target.start = start
            target.end = max(end, start)
        }
        target.repeatRule = repeatRule
        target.weekdayMask = repeatRule == .weekly ? weekdayMask : 0
        target.repeatEnd = repeatRule != .never && endsRepeat ? calendar.startOfDay(for: repeatEnd) : nil
        target.alertMinutes = alertMinutes
        target.bring = kidsGoing.isEmpty ? [] : bring
        target.showInKidView = showInKidView
        target.countsDown = countsDown
        Family.didSave(target, getReady: getReady && !kidsGoing.isEmpty, in: context)
        dismiss()
    }
}

/// Lays out views left to right, wrapping onto new lines: the "bring" items.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: subviews.isEmpty ? 0 : y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
