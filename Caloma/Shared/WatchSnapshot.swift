import Foundation
import SwiftUI

// Shared by the iPhone app, the Watch app and the watch widgets. It's in the iPhone app's
// folder; tick the two watch targets under Target Membership in the File inspector too.

/// What a parent's Apple Watch shows, sent from the iPhone whenever the family changes: who
/// needs an OK, what's coming up, how the kids are doing today and which home care is due.
/// The watch keeps the last one it got, so it works when the phone is out of reach.
nonisolated struct WatchSnapshot: Codable, Sendable, Equatable {
    var made: Date = .now
    /// The app's accent, 0xRRGGBB.
    var accent: UInt32 = 0xE0284F
    /// What the family calls points: "stars", "points", "coins"…
    var pointWord: String = "points"
    var approvals: [Approval] = []
    /// The next two days or so of family events, in start order.
    var events: [Event] = []
    var kids: [Kid] = []
    /// Late, or due in the next few days, soonest first.
    var homeCare: [HomeCareItem] = []

    nonisolated struct Approval: Codable, Sendable, Equatable, Identifiable {
        nonisolated enum Kind: String, Codable, Sendable { case chore, reward }
        var id: UUID
        var kind: Kind
        var kidID: UUID?
        var kidName: String
        var kidColor: UInt32
        /// The chore ("Clean the bathroom sink") or the reward ("Movie night pick").
        var title: String
        /// What the chore earns, or what the reward costs.
        var points: Int
        /// A small JPEG of the photo the kid took, if any.
        var photo: Data?
        var at: Date
    }

    nonisolated struct Event: Codable, Sendable, Equatable, Identifiable {
        /// The occurrence: "<event>@<start>".
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        /// "Max", "Ella and June", "Everyone".
        var who: String
        var color: UInt32
        var location: String
        /// The parent driving, if anyone.
        var driver: String?
        /// This phone's parent is driving.
        var youDrive: Bool
        var bring: [String]
    }

    nonisolated struct Kid: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var color: UInt32
        var done: Int
        var total: Int
        var balance: Int
    }

    nonisolated struct HomeCareItem: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var symbol: String
        var due: Date
        var location: String
    }

    var needsOKCount: Int { approvals.count }

    /// "+15 stars", "1 star".
    func points(_ count: Int, plus: Bool = false) -> String {
        let word = count == 1 && pointWord.hasSuffix("s") ? String(pointWord.dropLast()) : pointWord
        return (plus ? "+" : "") + "\(count) \(word)"
    }

    /// Events that haven't finished yet.
    func upcoming(now: Date = .now) -> [Event] {
        events.filter { $0.end > now || ($0.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: now)) }
    }

    // MARK: Moving it around

    static let contextKey = "snapshot"

    func encoded() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> WatchSnapshot? {
        try? PropertyListDecoder().decode(WatchSnapshot.self, from: data)
    }

    /// Shared by the Watch app and its widgets.
    static let appGroup = "group.com.stephenwarren.caloma"

    private static var fileURL: URL {
        let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("watch-snapshot.plist")
    }

    /// The last snapshot saved on this device.
    static func load() -> WatchSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return decode(data)
    }

    func save() {
        guard let data = encoded() else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

/// Something a parent did on the watch, carried out by the iPhone.
nonisolated enum WatchAction: Codable, Sendable, Equatable {
    case approve(UUID)
    case sendBack(UUID)
    case decline(UUID)
    case homeTaskDone(UUID)

    static let messageKey = "action"

    var message: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.messageKey: data]
    }

    init?(message: [String: Any]) {
        guard let data = message[Self.messageKey] as? Data,
              let action = try? JSONDecoder().decode(WatchAction.self, from: data) else { return nil }
        self = action
    }
}

extension Color {
    /// 0xRRGGBB, as the snapshot carries colors.
    nonisolated init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

extension WatchSnapshot.HomeCareItem {
    /// "Due today", "Due in 3 days", "2 days late".
    func dueLabel(now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        case 2...: return "Due in \(days) days"
        case -1: return "1 day late"
        default: return "\(-days) days late"
        }
    }

    func isLate(now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }
}

extension WatchSnapshot.Event {
    /// "3:30", "All day", "Tomorrow 9:00 AM".
    func timeLabel(now: Date = .now, calendar: Calendar = .current) -> String {
        let time = isAllDay ? "All day" : start.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(start, inSameDayAs: now) || (start < now && end > now) { return time }
        if calendar.isDateInTomorrow(start) { return "Tomorrow " + time }
        return start.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }

    /// "Max · 3:30 · You're driving".
    var detail: String {
        var parts = [who, timeLabel()]
        if youDrive { parts.append("You're driving") } else if let driver { parts.append("\(driver) drives") }
        return parts.joined(separator: " · ")
    }
}
