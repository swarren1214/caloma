import Foundation
import SwiftData
import UserNotifications

/// Calendar alerts: a notification before each event that has one, for the next two weeks.
/// Rescheduled from scratch whenever an event changes and each time the app opens.
enum EventAlerts {
    nonisolated private static let prefix = "event."

    static func reschedule(in context: ModelContext) {
        // Screenshot mode: no permission prompt, and the device's own alerts stay as they are.
        guard !ScreenshotMode.isOn else { return }
        let events = Persistence.fetchAll(FamilyEvent.self, in: context).filter { !$0.isArchived && $0.alertMinutes >= 0 }
        let members = Persistence.fetchAll(Member.self, in: context)
        let now = Date.now
        let until = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        var plans: [Plan] = []
        for event in events {
            let record = event.record
            for occurrence in CalendarMath.occurrences(of: [record], from: now, through: until) {
                let fire = occurrence.start.addingTimeInterval(-Double(event.alertMinutes) * 60)
                guard fire > now else { continue }
                let driver = members.first { $0.id == event.driverID }?.name
                plans.append(Plan(id: occurrence.id, title: event.title, body: body(occurrence, alertMinutes: event.alertMinutes, location: event.location, driver: driver), fire: fire))
            }
        }
        // iOS keeps 64 pending notifications per app; leave room for home care reminders.
        let soonest = Array(plans.sorted { $0.fire < $1.fire }.prefix(40))
        Task { await schedule(soonest) }
    }

    private static func body(_ occurrence: EventOccurrence, alertMinutes: Int, location: String, driver: String?) -> String {
        var parts: [String] = []
        if occurrence.event.isAllDay {
            parts.append(Calendar.current.isDateInToday(occurrence.start) ? "Today" : occurrence.start.formatted(.dateTime.weekday(.wide)))
        } else if alertMinutes == 0 {
            parts.append("Starting now")
        } else {
            parts.append("At \(occurrence.start.formatted(date: .omitted, time: .shortened))")
        }
        if !location.isEmpty { parts.append(location) }
        if let driver { parts.append("\(driver) is driving") }
        if !occurrence.event.bring.isEmpty { parts.append("Bring " + occurrence.event.bring.joined(separator: ", ").lowercased()) }
        return parts.joined(separator: " · ")
    }

    private struct Plan: Sendable {
        var id: String
        var title: String
        var body: String
        var fire: Date
    }

    private static func schedule(_ plans: [Plan]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        guard !plans.isEmpty else { return }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let calendar = Calendar.current
        for plan in plans {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.userInfo = ["url": "caloma://calendar"]
            let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: plan.fire), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + plan.id, content: content, trigger: trigger))
        }
    }
}
