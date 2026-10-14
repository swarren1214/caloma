import SwiftData
import SwiftUI

/// The family under the tabs in the iPad sidebar while Calendar is open: each person's photo
/// in a ring of their color (tap to hide or show their events), Chores & Home Care, Apple
/// Calendar, and the next countdown.
struct CalendarSidebarFilters: View {
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var allMembers: [Member]
    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived }) private var events: [FamilyEvent]
    @Bindable private var filter = CalendarFilter.shared
    private let apple = AppleCalendar.shared
    @State private var showsAppleSettings = false

    private var members: [Member] { allMembers.filter { !$0.isArchived } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            heading("Family")
            personRow(nil, key: "everyone", name: "Everyone")
            ForEach(members) { member in
                personRow(member, key: member.id.uuidString, name: member.name)
            }

            heading("Also Show")
                .padding(.top, 14)
            Toggle(isOn: $filter.showChores) {
                Label("Chores & Home Care", systemImage: "checklist")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            Button {
                showsAppleSettings = true
            } label: {
                HStack {
                    Label("Apple Calendar", systemImage: "calendar")
                    Spacer()
                    Text(apple.showsAppleEvents && apple.hasAccess ? "On" : "Off")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let visible = events.map(\.record).filter { self.filter.shows($0) }
            if let countdown = CalendarMath.nextCountdown(visible) {
                CountdownCard(occurrence: countdown, color: color(for: countdown.event))
                    .padding(.top, 14)
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showsAppleSettings) {
            NavigationStack {
                AppleCalendarSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { showsAppleSettings = false }
                        }
                    }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }

    private func color(for event: EventRecord) -> Color {
        if event.isEveryone { return accent }
        return members.first { event.attendeeIDs.contains($0.id) }?.color.color ?? accent
    }

    private func personRow(_ member: Member?, key: String, name: String) -> some View {
        let on = filter.isShown(key)
        return Button {
            withAnimation(.smooth(duration: 0.2)) { filter.toggle(key) }
        } label: {
            HStack(spacing: 12) {
                PersonRing(member: member, isOn: on, size: 38)
                Text(name)
                    .font(.body.weight(on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !on {
                    Text("Hidden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(on ? "Shown" : "Hidden")
        .accessibilityHint("Shows or hides their events")
    }
}
