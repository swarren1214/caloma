import Foundation

// The family's arithmetic: who has which chore on which day, what's done, balances, streaks,
// rewards and home care due dates. Everything here works on plain Sendable records, so it's
// easy to test and never touches the store.

// MARK: - Records

nonisolated struct ChoreRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var title: String = ""
    var symbol: String = "checkmark.circle"
    var points: Int = 5
    var assigneeIDs: [UUID] = []
    var rotates: Bool = false
    var upForGrabs: Bool = false
    var repeatRule: ChoreRepeat = .daily
    var weekdayMask: Int = 0
    var startDate: Date
    var requiresPhoto: Bool = false
    var requiresApproval: Bool = true
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var roomID: UUID?
}

nonisolated struct CompletionRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var choreID: UUID?
    var memberID: UUID?
    var day: Date
    var status: CompletionStatus
    var points: Int
    /// When the kid marked it done.
    var completedAt: Date = .distantPast
}

nonisolated struct PointRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var memberID: UUID?
    var points: Int
    var kind: PointKind = .chore
    var refID: UUID?
    var date: Date = .now
}

nonisolated struct RedemptionRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var rewardID: UUID?
    var memberID: UUID?
    var cost: Int
    var status: RedemptionStatus
    var requestedAt: Date
}

// MARK: - The board

/// Where one chore stands for one kid on one day.
nonisolated enum ItemStatus: String, Sendable {
    case open, pending, approved

    var isDone: Bool { self != .open }
}

/// One line on the chore board: a chore, the kid it's for (nil while an up-for-grabs chore is
/// unclaimed), the day it counts for and where it stands.
nonisolated struct BoardItem: Identifiable, Hashable, Sendable {
    var chore: ChoreRecord
    var memberID: UUID?
    /// The day the completion is recorded against. A one-time chore's start day.
    var occurrenceDay: Date
    var status: ItemStatus
    var completionID: UUID?
    /// A parent sent the last try back.
    var wasSentBack: Bool = false

    var id: String { "\(chore.id.uuidString)-\(memberID?.uuidString ?? "any")-\(Int(occurrenceDay.timeIntervalSince1970))" }
    var points: Int { chore.points }
}

nonisolated enum ChoreMath {
    /// Bits for Sunday … Saturday in `weekdayMask`.
    static let weekdaysMask = 0b0111110

    static func bit(forWeekday weekday: Int) -> Int { 1 << (weekday - 1) }

    /// Whether a repeating chore comes up on a day. One-time chores are handled by `items`.
    static func occurs(_ chore: ChoreRecord, on day: Date, calendar: Calendar = .current) -> Bool {
        guard !chore.isArchived else { return false }
        let start = calendar.startOfDay(for: chore.startDate)
        let date = calendar.startOfDay(for: day)
        guard date >= start else { return false }
        let weekday = calendar.component(.weekday, from: date)
        switch chore.repeatRule {
        case .once: return date == start
        case .daily: return true
        case .weekdays: return weekdaysMask & bit(forWeekday: weekday) != 0
        case .someDays: return chore.weekdayMask & bit(forWeekday: weekday) != 0
        }
    }

    /// Who does a chore on a day. Taking turns swaps kids each week, starting from the week of
    /// the chore's start day. Up-for-grabs chores return everyone (any of them can claim it).
    static func assignees(of chore: ChoreRecord, on day: Date, calendar: Calendar = .current) -> [UUID] {
        guard chore.rotates, !chore.upForGrabs, chore.assigneeIDs.count > 1 else { return chore.assigneeIDs }
        let weeks = weeksBetween(chore.startDate, day, calendar: calendar)
        let index = ((weeks % chore.assigneeIDs.count) + chore.assigneeIDs.count) % chore.assigneeIDs.count
        return [chore.assigneeIDs[index]]
    }

    static func weeksBetween(_ from: Date, _ to: Date, calendar: Calendar = .current) -> Int {
        guard let a = calendar.dateInterval(of: .weekOfYear, for: from)?.start,
              let b = calendar.dateInterval(of: .weekOfYear, for: to)?.start else { return 0 }
        let days = calendar.dateComponents([.day], from: a, to: b).day ?? 0
        return Int((Double(days) / 7).rounded(.down))
    }

    /// Everything on the board for a day, in chore order. Kids each get their own line for a
    /// shared chore; an up-for-grabs chore is one line until someone claims it.
    static func items(on day: Date, chores: [ChoreRecord], completions: [CompletionRecord], calendar: Calendar = .current) -> [BoardItem] {
        let date = calendar.startOfDay(for: day)
        var result: [BoardItem] = []
        for chore in chores.sorted(by: { ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title) }) where !chore.isArchived {
            let start = calendar.startOfDay(for: chore.startDate)
            let occurrence: Date
            if chore.repeatRule == .once {
                guard date >= start else { continue }
                occurrence = start
            } else {
                guard occurs(chore, on: date, calendar: calendar) else { continue }
                occurrence = date
            }
            let forDay = completions.filter { $0.choreID == chore.id && calendar.isDate($0.day, inSameDayAs: occurrence) }

            if chore.upForGrabs {
                let claim = forDay.first { $0.status != .sentBack }
                let item = BoardItem(chore: chore, memberID: claim?.memberID, occurrenceDay: occurrence, status: status(of: claim), completionID: claim?.id)
                // A one-time chore that's been approved drops off the days after it's done.
                if chore.repeatRule == .once, date > start, item.status == .approved, let claim, !calendar.isDate(claim.completedAt, inSameDayAs: date) { continue }
                result.append(item)
                continue
            }

            for member in assignees(of: chore, on: date, calendar: calendar) {
                let mine = forDay.filter { $0.memberID == member }
                let live = mine.first { $0.status != .sentBack }
                let sentBack = live == nil && mine.contains { $0.status == .sentBack }
                if chore.repeatRule == .once, date > start, let live, live.status == .approved, !calendar.isDate(live.completedAt, inSameDayAs: date) { continue }
                result.append(BoardItem(chore: chore, memberID: member, occurrenceDay: occurrence, status: status(of: live), completionID: live?.id, wasSentBack: sentBack))
            }
        }
        return result
    }

    static func status(of completion: CompletionRecord?) -> ItemStatus {
        switch completion?.status {
        case .pending: .pending
        case .approved: .approved
        case .sentBack, nil: .open
        }
    }

    /// A kid's lines for a day, including up-for-grabs chores nobody has claimed (and the ones
    /// they claimed).
    static func items(for memberID: UUID, on day: Date, chores: [ChoreRecord], completions: [CompletionRecord], calendar: Calendar = .current) -> [BoardItem] {
        items(on: day, chores: chores, completions: completions, calendar: calendar).filter { item in
            if item.chore.upForGrabs {
                let eligible = item.chore.assigneeIDs.isEmpty || item.chore.assigneeIDs.contains(memberID)
                return eligible && (item.memberID == nil || item.memberID == memberID)
            }
            return item.memberID == memberID
        }
    }

    /// Days in a row, ending today, on which a kid finished everything assigned to them. Days
    /// with nothing assigned don't count or break it, and today doesn't break it while it's
    /// still underway.
    static func streak(for memberID: UUID, through today: Date, chores: [ChoreRecord], completions: [CompletionRecord], calendar: Calendar = .current, maxDays: Int = 366) -> Int {
        var count = 0
        let start = calendar.startOfDay(for: today)
        for offset in 0..<maxDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { break }
            let mine = items(on: day, chores: chores, completions: completions, calendar: calendar)
                .filter { $0.memberID == memberID && !$0.chore.upForGrabs }
            if mine.isEmpty { continue }
            if mine.allSatisfy({ $0.status.isDone }) {
                count += 1
            } else if offset == 0 {
                continue
            } else {
                break
            }
        }
        return count
    }

    // MARK: Points

    static func balance(of memberID: UUID, entries: [PointRecord]) -> Int {
        entries.reduce(0) { $1.memberID == memberID ? $0 + $1.points : $0 }
    }

    /// Points from chores done but not approved yet.
    static func pendingPoints(of memberID: UUID, completions: [CompletionRecord]) -> Int {
        completions.reduce(0) { $1.memberID == memberID && $1.status == .pending ? $0 + $1.points : $0 }
    }

    /// Points a kid has asked to spend on rewards that a parent hasn't answered yet.
    static func reservedPoints(of memberID: UUID, redemptions: [RedemptionRecord]) -> Int {
        redemptions.reduce(0) { $1.memberID == memberID && $1.status == .pending ? $0 + $1.cost : $0 }
    }

    /// What a kid can spend now: their balance less rewards waiting for a parent.
    static func spendable(of memberID: UUID, entries: [PointRecord], redemptions: [RedemptionRecord]) -> Int {
        balance(of: memberID, entries: entries) - reservedPoints(of: memberID, redemptions: redemptions)
    }

    /// Points earned (chores and bonuses) since a date.
    static func earned(by memberID: UUID, since date: Date, entries: [PointRecord]) -> Int {
        entries.reduce(0) { total, entry in
            guard entry.memberID == memberID, entry.date >= date, entry.kind == .chore || entry.kind == .bonus else { return total }
            return total + entry.points
        }
    }

    /// Everything put toward a family goal.
    static func goalProgress(_ goalID: UUID, entries: [PointRecord]) -> Int {
        entries.reduce(0) { $1.kind == .goal && $1.refID == goalID ? $0 - $1.points : $0 }
    }

    /// Each kid's share of a family goal, by member.
    static func goalShares(_ goalID: UUID, entries: [PointRecord]) -> [UUID: Int] {
        var shares: [UUID: Int] = [:]
        for entry in entries where entry.kind == .goal && entry.refID == goalID {
            guard let member = entry.memberID else { continue }
            shares[member, default: 0] -= entry.points
        }
        return shares
    }
}

// MARK: - Rewards

nonisolated enum RewardCheck: Equatable, Sendable {
    case ok
    case needMore(Int)
    case limitReached
    case notForThisKid
}

nonisolated enum RewardMath {
    /// Whether a kid can ask for a reward now.
    static func check(cost: Int, limit: RewardLimit, eligible: Bool, spendable: Int, memberID: UUID, rewardID: UUID, redemptions: [RedemptionRecord], now: Date = .now, calendar: Calendar = .current) -> RewardCheck {
        guard eligible else { return .notForThisKid }
        if let allowance = limit.allowance {
            let used = redemptions.filter {
                $0.memberID == memberID && $0.rewardID == rewardID && $0.status != .declined
                    && calendar.isDate($0.requestedAt, equalTo: now, toGranularity: allowance.period)
            }.count
            if used >= allowance.count { return .limitReached }
        }
        if spendable < cost { return .needMore(cost - spendable) }
        return .ok
    }

    /// Points to money at the family's rate, in cents.
    static func cents(for points: Int, centsPer100: Int) -> Int {
        Int((Double(points) * Double(centsPer100) / 100).rounded())
    }

    /// Splits cents into spend, save and give by percentage. Whatever rounding leaves over
    /// goes to spend, so the three always add up.
    static func split(cents: Int, spend: Int, save: Int, give: Int) -> (spend: Int, save: Int, give: Int) {
        let total = max(spend + save + give, 1)
        let saveCents = cents * save / total
        let giveCents = cents * give / total
        return (cents - saveCents - giveCents, saveCents, giveCents)
    }

    /// Roughly how many days of chores a reward takes at a kid's recent pace.
    static func daysOfChores(cost: Int, pointsPerDay: Double) -> Int? {
        guard pointsPerDay > 0 else { return nil }
        return max(1, Int((Double(cost) / pointsPerDay).rounded(.up)))
    }
}

// MARK: - Home care

nonisolated enum HomeDue: Equatable, Sendable {
    case overdue(days: Int)
    case today
    case soon(days: Int)
    case later(days: Int)

    var sortKey: Int {
        switch self {
        case .overdue(let days): -days
        case .today: 0
        case .soon(let days), .later(let days): days
        }
    }
}

nonisolated enum HomeCareMath {
    /// Within this many days counts as coming up.
    static let soonWindow = 30

    static func due(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> HomeDue {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days < 0 { return .overdue(days: -days) }
        if days == 0 { return .today }
        if days <= soonWindow { return .soon(days: days) }
        return .later(days: days)
    }

    /// The next due date after doing it on `doneAt`.
    static func nextDue(after doneAt: Date, count: Int, unit: IntervalUnit, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: doneAt)
        return calendar.date(byAdding: unit.component, value: max(count, 1), to: start) ?? start
    }

    static func daysLate(due: Date, doneAt: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: calendar.startOfDay(for: doneAt)).day ?? 0
        return max(days, 0)
    }

    static func intervalLabel(count: Int, unit: IntervalUnit) -> String {
        if count <= 1 {
            switch unit {
            case .days: return "Daily"
            case .weeks: return "Weekly"
            case .months: return "Monthly"
            case .years: return "Yearly"
            }
        }
        return "Every \(count) \(unit.rawValue)"
    }

    /// "3 days late", "Today", "In 5 days", "Nov 2".
    static func dueLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        switch due(date, now: now, calendar: calendar) {
        case .overdue(let days): return days == 1 ? "1 day late" : "\(days) days late"
        case .today: return "Today"
        case .soon(let days) where days == 1: return "Tomorrow"
        case .soon(let days) where days <= 7: return "In \(days) days"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
