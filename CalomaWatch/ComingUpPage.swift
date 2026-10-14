import MapKit
import SwiftUI
import UserNotifications

/// Coming Up: the next family event, counting down, with Directions and a five-minute nudge
/// when you're the one driving. The rest of today and tomorrow below it.
struct ComingUpPage: View {
    @Environment(PhoneLink.self) private var link

    var body: some View {
        TimelineView(.everyMinute) { context in
            let events = link.snapshot.upcoming(now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let next = events.first {
                        NextEventCard(event: next, now: context.date)
                        if events.count > 1 {
                            Text("Later")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.top, 4)
                            ForEach(events.dropFirst()) { event in
                                EventLine(event: event)
                            }
                        }
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.title)
                                .foregroundStyle(.tint)
                            Text("Nothing coming up")
                                .font(.headline)
                            Text("A free couple of days.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                    }
                }
            }
            .containerBackground(Color(rgb: events.first?.color ?? link.snapshot.accent).gradient.opacity(0.35), for: .tabView)
        }
        .navigationTitle("Coming Up")
    }
}

private struct NextEventCard: View {
    var event: WatchSnapshot.Event
    var now: Date
    @State private var finding = false
    @State private var notFound = false
    @State private var snoozedUntil: Date?

    var body: some View {
        let color = Color(rgb: event.color)
        VStack(alignment: .leading, spacing: 6) {
            PageLabel(title: event.youDrive ? "You're driving" : "Coming up", color: color)
            Text(headline)
                .font(.title3.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text("\(event.title) · \(event.who) · \(event.timeLabel(now: now))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let driver = event.driver, !event.youDrive {
                Label("\(driver) drives", systemImage: "car.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !event.location.isEmpty {
                HStack(spacing: 6) {
                    Button {
                        Task { await directions() }
                    } label: {
                        Label(finding ? "Finding…" : "Directions", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(finding)
                    if event.youDrive && event.start > now {
                        Button("5m") { Task { await snooze() } }
                            .frame(width: 48)
                            .accessibilityLabel("Remind me in 5 minutes")
                    }
                }
                .padding(.top, 2)
            }

            Group {
                if let snoozedUntil {
                    Text("I'll tap you again at \(snoozedUntil.formatted(date: .omitted, time: .shortened)).")
                } else if notFound {
                    Text("Couldn't find \(event.location) in Maps.")
                } else {
                    Text(([event.location] + (event.bring.isEmpty ? [] : ["bring " + event.bring.formatted(.list(type: .and))])).filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// "Starts in 25 min", "Happening now", "Tomorrow at 9:00 AM".
    private var headline: String {
        if event.isAllDay { return Calendar.current.isDateInToday(event.start) || event.start < now ? "Today" : event.timeLabel(now: now) }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "Happening now" }
        if minutes < 60 { return "Starts in \(minutes) min" }
        if minutes < 180 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "Starts in \(hours) hr" : "In \(hours) hr \(rest) min"
        }
        return Calendar.current.isDate(event.start, inSameDayAs: now) ? "At \(event.start.formatted(date: .omitted, time: .shortened))" : event.timeLabel(now: now)
    }

    private func directions() async {
        finding = true
        notFound = false
        defer { finding = false }
        let placemarks = try? await CLGeocoder().geocodeAddressString(event.location)
        guard let placemark = placemarks?.first else {
            notFound = true
            return
        }
        let item = MKMapItem(placemark: MKPlacemark(placemark: placemark))
        item.name = event.location
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func snooze() async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time to go"
        content.body = "\(event.title) at \(event.start.formatted(date: .omitted, time: .shortened))" + (event.location.isEmpty ? "" : " · \(event.location)")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "leave.\(event.id)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false))
        try? await center.add(request)
        snoozedUntil = .now.addingTimeInterval(300)
    }
}

private struct EventLine: View {
    var event: WatchSnapshot.Event

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(rgb: event.color))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(event.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
