import Foundation
import SwiftData
import UserNotifications

/// Home care reminders: a notification at 9 AM some days before each task is due, when
/// Family › Home Care Reminders is on. Rescheduled from scratch whenever a task changes.
enum Reminders {
    nonisolated private static let prefix = "homecare."

    static var isOn: Bool { UserDefaults.standard.bool(forKey: SettingsKey.homeReminders) }

    /// Asks for permission. Returns whether notifications are allowed.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(in context: ModelContext) {
        // Screenshot mode: the device's own reminders stay as they are.
        guard !ScreenshotMode.isOn else { return }
        let tasks = Persistence.fetchAll(HomeTask.self, in: context).filter { !$0.isArchived }
        let plans = tasks.map { Plan(id: $0.id, name: $0.name, due: $0.nextDue, daysBefore: $0.remindDaysBefore) }
        Task { await schedule(plans) }
    }

    static func cancelAll() {
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }

    private struct Plan: Sendable {
        var id: UUID
        var name: String
        var due: Date
        var daysBefore: Int
    }

    private static func schedule(_ plans: [Plan]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        guard isOn else { return }
        let calendar = Calendar.current
        for plan in plans {
            guard let day = calendar.date(byAdding: .day, value: -max(plan.daysBefore, 0), to: calendar.startOfDay(for: plan.due)),
                  let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                  fire > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = plan.name
            content.body = plan.daysBefore == 0 ? "Due today." : "Due \(plan.due.formatted(.dateTime.weekday(.wide).month().day()))."
            content.sound = .default
            content.userInfo = ["url": "caloma://homecare"]
            let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + plan.id.uuidString, content: content, trigger: trigger))
        }
    }
}
