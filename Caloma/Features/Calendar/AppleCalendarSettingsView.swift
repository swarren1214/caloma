import EventKit
import SwiftData
import SwiftUI

/// Profile › Apple Calendar: show Apple Calendar events on the family calendar (choosing which
/// calendars), and add family events to Apple Calendar. Both are off until turned on, and
/// both are just for this device.
struct AppleCalendarSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Bindable private var apple = AppleCalendar.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { apple.showsAppleEvents }, set: { on in
                    Task {
                        if on && !apple.hasAccess { _ = await apple.requestAccess() }
                        apple.showsAppleEvents = on && apple.hasAccess
                    }
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show Apple Calendar Events")
                        Text("Work, school and other calendars, alongside the family's")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { apple.addsFamilyEvents }, set: { on in
                    Task {
                        if on && !apple.hasAccess { _ = await apple.requestAccess() }
                        apple.addsFamilyEvents = on && apple.hasAccess
                        if apple.addsFamilyEvents {
                            apple.pushFamilyEvents(in: context)
                        } else {
                            apple.removeFamilyEvents()
                        }
                    }
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add Family Events to Apple Calendar")
                        Text("The next two months, in a calendar named Caloma")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if apple.status == .denied || apple.status == .restricted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Caloma doesn't have access to your calendars.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .tint(.primary)
                    }
                } else {
                    Text("These are just for this device. Each parent can turn them on for their own iPhone.")
                }
            }

            if apple.showsAppleEvents && apple.hasAccess {
                let groups = Dictionary(grouping: apple.calendars) { $0.source.title }
                ForEach(groups.keys.sorted(), id: \.self) { source in
                    Section(source) {
                        ForEach(groups[source] ?? [], id: \.calendarIdentifier) { calendar in
                            let shown = !apple.hiddenCalendarIDs.contains(calendar.calendarIdentifier)
                            Button {
                                if shown {
                                    apple.hiddenCalendarIDs.insert(calendar.calendarIdentifier)
                                } else {
                                    apple.hiddenCalendarIDs.remove(calendar.calendarIdentifier)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(Color(cgColor: calendar.cgColor))
                                    Text(calendar.title)
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(shown ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .navigationTitle("Apple Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }
}
