import SwiftData
import SwiftUI

/// One event, opened from the calendar: when, where, who's going and driving, what to bring,
/// what the kids see. Edit, skip this day of a repeating event, or delete.
struct EventDetailView: View {
    var eventID: UUID
    var day: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    /// On the Kiosk Mode wall: look, don't change.
    @Environment(\.calendarReadOnly) private var readOnly
    @Query private var events: [FamilyEvent]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var packings: [EventPacking]
    @State private var editing = false
    @State private var confirmsDelete = false

    private var event: FamilyEvent? { events.first { $0.id == eventID } }

    var body: some View {
        Group {
            if let event {
                content(event)
            } else {
                ContentUnavailableView("Event Deleted", systemImage: "calendar.badge.minus")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", systemImage: "xmark") { dismiss() }
            }
            if event != nil && !readOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let event { EventEditor(event: event, day: day) }
        }
    }

    private func content(_ event: FamilyEvent) -> some View {
        let record = event.record
        let occurrence = CalendarMath.occurrence(of: record, startingOn: day)
        let going = event.attendeeIDs.isEmpty ? members.filter { !$0.isArchived } : members.filter { event.attendeeIDs.contains($0.id) }
        let color = event.attendeeIDs.isEmpty ? accent : (going.first?.color.color ?? accent)
        let driver = members.first { $0.id == event.driverID }
        let kids = going.filter(\.isKid)
        return List {
            Section {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 6, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.title2.bold())
                        Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .foregroundStyle(.secondary)
                        Text(CalendarMath.timeLabel(occurrence))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 4)
                if let handwriting = event.handwriting {
                    EventHandwriting(data: handwriting)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                if !event.location.isEmpty {
                    LabeledContent {
                        Text(event.location)
                    } label: {
                        Label("Where", systemImage: "mappin.and.ellipse")
                    }
                }
                LabeledContent {
                    Text(event.repeatRule.summary(start: event.start, weekdayMask: event.weekdayMask))
                } label: {
                    Label("Repeats", systemImage: "repeat")
                }
                if event.alertMinutes >= 0 {
                    LabeledContent {
                        Text(EventAlertChoice.label(event.alertMinutes))
                    } label: {
                        Label("Alert", systemImage: "bell")
                    }
                }
            }

            Section(event.attendeeIDs.isEmpty ? "Everyone's Going" : "Who's Going") {
                ForEach(going) { member in
                    HStack(spacing: 12) {
                        PersonRing(member: member, size: 38)
                        Text(member.name)
                        Spacer()
                        if member.id == driver?.id {
                            EventPill(text: "Driving", symbol: "car.fill", color: member.color.color)
                        }
                    }
                }
                if let driver, !going.contains(where: { $0.id == driver.id }) {
                    HStack(spacing: 12) {
                        PersonRing(member: driver, size: 38)
                        Text(driver.name)
                        Spacer()
                        EventPill(text: "Driving", symbol: "car.fill", color: driver.color.color)
                    }
                }
            }

            if !event.bring.isEmpty {
                Section("Remember to Bring") {
                    ForEach(event.bring, id: \.self) { item in
                        HStack {
                            Text(item)
                            Spacer()
                            // Which kids have packed it today.
                            ForEach(kids) { kid in
                                if packed(item, kid: kid, event: event) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(kid.color.color)
                                        .accessibilityLabel("\(kid.name) packed it")
                                }
                            }
                        }
                    }
                }
            }

            if !kids.isEmpty {
                Section("Kid View") {
                    LabeledContent("Shows on their day", value: event.showInKidView ? "Yes" : "No")
                    LabeledContent("Countdown", value: event.countsDown ? "\(CalendarMath.sleeps(from: .now, until: occurrence.start)) sleeps" : "Off")
                    LabeledContent("Get-ready chore", value: event.getReadyChoreID == nil ? "Off" : "The night before")
                }
            }

            if !event.notes.isEmpty {
                Section("Notes") {
                    Text(event.notes)
                }
            }

            if !readOnly {
                Section {
                    if event.repeatRule != .never {
                        Button("Skip \(day.formatted(.dateTime.weekday(.wide).month().day()))") {
                            Family.skip(event, on: day, in: context)
                            dismiss()
                        }
                    }
                    Button("Delete Event", role: .destructive) { confirmsDelete = true }
                } footer: {
                    if event.repeatRule != .never {
                        Text("Skipping takes this one day off the calendar and leaves the rest.")
                    }
                }
            }
        }
        .confirmationDialog("Delete \(event.title)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            if event.repeatRule != .never {
                Button("Only This Day", role: .destructive) {
                    Family.skip(event, on: day, in: context)
                    dismiss()
                }
                Button("Every Day", role: .destructive) {
                    Family.delete(event, in: context)
                    dismiss()
                }
            } else {
                Button("Delete Event", role: .destructive) {
                    Family.delete(event, in: context)
                    dismiss()
                }
            }
        }
    }

    private func packed(_ item: String, kid: Member, event: FamilyEvent) -> Bool {
        packings.first { $0.eventID == event.id && $0.memberID == kid.id && Calendar.current.isDate($0.day, inSameDayAs: day) }?.packed.contains(item) ?? false
    }
}
