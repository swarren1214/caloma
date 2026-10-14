import Foundation
import SwiftData

// Every model follows CloudKit's rules: every property has a default, nothing is unique, and
// there are no required relationships. Records link by UUID (choreID, memberID, rewardID,
// taskID), so deleting a chore or a reward never deletes anyone's points history.

/// A parent or a kid.
@Model
final class Member {
    var id: UUID = UUID()
    var name: String = ""
    var roleRaw: String = MemberRole.kid.rawValue
    var colorRaw: String = KidColor.blue.rawValue
    @Attribute(.externalStorage) var photoData: Data?
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    /// Without a color, kids start blue and parents gray.
    init(name: String, role: MemberRole, color: KidColor? = nil, sortOrder: Int = 0) {
        self.name = name
        self.roleRaw = role.rawValue
        self.colorRaw = (color ?? (role == .kid ? .blue : .gray)).rawValue
        self.sortOrder = sortOrder
    }

    var role: MemberRole {
        get { MemberRole(rawValue: roleRaw) ?? .kid }
        set { roleRaw = newValue.rawValue }
    }

    var color: KidColor {
        get { KidColor(rawValue: colorRaw) ?? .blue }
        set { colorRaw = newValue.rawValue }
    }

    var isKid: Bool { role == .kid }
    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}

nonisolated enum MemberRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case parent, kid

    var id: String { rawValue }
    var label: String { self == .parent ? "Parent" : "Kid" }
}

/// A chore: who does it, how often, and what it's worth.
@Model
final class Chore {
    var id: UUID = UUID()
    var title: String = ""
    var symbol: String = "checkmark.circle"
    var points: Int = 5
    /// The kids it's assigned to, as comma-separated UUIDs (CloudKit-friendly).
    var assigneeIDsRaw: String = ""
    /// With more than one kid: they take turns, swapping each week.
    var rotates: Bool = false
    /// Any kid can claim it; the first to finish gets the points.
    var upForGrabs: Bool = false
    var repeatRaw: String = ChoreRepeat.daily.rawValue
    /// For `.someDays`: bit 0 is Sunday … bit 6 is Saturday.
    var weekdayMask: Int = 0
    /// The first day it counts (start of day).
    var startDate: Date = Date.now
    /// Minutes after midnight it should be done by, or -1 for no time.
    var dueMinutes: Int = -1
    var requiresPhoto: Bool = false
    var requiresApproval: Bool = true
    /// Set when a home care task was handed to a kid; finishing it marks the task done.
    var homeTaskID: UUID?
    /// The room it's in, if any.
    var roomID: UUID?
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(title: String, symbol: String, points: Int, assigneeIDs: [UUID] = [], repeatRule: ChoreRepeat = .daily, weekdayMask: Int = 0, startDate: Date = .now, requiresApproval: Bool = true, sortOrder: Int = 0) {
        self.title = title
        self.symbol = symbol
        self.points = points
        self.assigneeIDsRaw = Self.encode(assigneeIDs)
        self.repeatRaw = repeatRule.rawValue
        self.weekdayMask = weekdayMask
        self.startDate = Calendar.current.startOfDay(for: startDate)
        self.requiresApproval = requiresApproval
        self.sortOrder = sortOrder
    }

    var assigneeIDs: [UUID] {
        get { Self.decode(assigneeIDsRaw) }
        set { assigneeIDsRaw = Self.encode(newValue) }
    }

    var repeatRule: ChoreRepeat {
        get { ChoreRepeat(rawValue: repeatRaw) ?? .daily }
        set { repeatRaw = newValue.rawValue }
    }

    var record: ChoreRecord {
        ChoreRecord(id: id, title: title, symbol: symbol, points: points, assigneeIDs: assigneeIDs, rotates: rotates, upForGrabs: upForGrabs, repeatRule: repeatRule, weekdayMask: weekdayMask, startDate: startDate, requiresPhoto: requiresPhoto, requiresApproval: requiresApproval, isArchived: isArchived, sortOrder: sortOrder, roomID: roomID)
    }

    nonisolated static func encode(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).joined(separator: ",")
    }

    nonisolated static func decode(_ raw: String) -> [UUID] {
        raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }
}

nonisolated enum ChoreRepeat: String, CaseIterable, Identifiable, Codable, Sendable {
    /// One time. Stays on the board until it's done.
    case once
    case daily
    /// Monday to Friday.
    case weekdays
    /// The days in `weekdayMask`.
    case someDays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .once: "Once"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .someDays: "Weekly"
        }
    }
}

/// A kid marking a chore done for one day. Points land when it's approved.
@Model
final class ChoreCompletion {
    var id: UUID = UUID()
    var choreID: UUID?
    var memberID: UUID?
    /// The day this counts for (start of day). For a one-time chore, its start day.
    var day: Date = Date.now
    var statusRaw: String = CompletionStatus.pending.rawValue
    /// The chore's points when it was done, so changing a chore later never rewrites history.
    var points: Int = 0
    var completedAt: Date = Date.now
    var reviewedAt: Date?
    @Attribute(.externalStorage) var photoData: Data?

    init(choreID: UUID, memberID: UUID, day: Date, points: Int, status: CompletionStatus, photoData: Data? = nil) {
        self.choreID = choreID
        self.memberID = memberID
        self.day = day
        self.points = points
        self.statusRaw = status.rawValue
        self.photoData = photoData
    }

    var status: CompletionStatus {
        get { CompletionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var record: CompletionRecord {
        CompletionRecord(id: id, choreID: choreID, memberID: memberID, day: day, status: status, points: points, completedAt: completedAt)
    }
}

nonisolated enum CompletionStatus: String, Codable, Sendable {
    /// Done, waiting for a parent's OK.
    case pending
    case approved
    /// A parent sent it back; it's open again.
    case sentBack
}

/// Something kids can spend points on.
@Model
final class Reward {
    var id: UUID = UUID()
    var name: String = ""
    var note: String = ""
    var symbol: String = "gift"
    var kindRaw: String = RewardKind.privilege.rawValue
    var cost: Int = 50
    var limitRaw: String = RewardLimit.none.rawValue
    /// The kids who can get it, as comma-separated UUIDs. Empty means every kid.
    var eligibleIDsRaw: String = ""
    var needsApproval: Bool = true
    /// Kids pool points toward it instead of each buying it.
    var isFamilyGoal: Bool = false
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(name: String, note: String = "", symbol: String, kind: RewardKind, cost: Int, limit: RewardLimit = .none, isFamilyGoal: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.note = note
        self.symbol = symbol
        self.kindRaw = kind.rawValue
        self.cost = cost
        self.limitRaw = limit.rawValue
        self.isFamilyGoal = isFamilyGoal
        self.sortOrder = sortOrder
    }

    var kind: RewardKind {
        get { RewardKind(rawValue: kindRaw) ?? .privilege }
        set { kindRaw = newValue.rawValue }
    }

    var limit: RewardLimit {
        get { RewardLimit(rawValue: limitRaw) ?? .none }
        set { limitRaw = newValue.rawValue }
    }

    var eligibleIDs: [UUID] {
        get { Chore.decode(eligibleIDsRaw) }
        set { eligibleIDsRaw = Chore.encode(newValue) }
    }

    func isAvailable(to memberID: UUID) -> Bool {
        let ids = eligibleIDs
        return ids.isEmpty || ids.contains(memberID)
    }
}

nonisolated enum RewardKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case privilege, experience, money, item

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// "Privileges", for the store's filter.
    var plural: String { self == .money ? "Money" : label + "s" }

    var hint: String {
        switch self {
        case .privilege: "Extra time or a special permission."
        case .experience: "Something you do together."
        case .money: "Paid out on payday at your family's rate."
        case .item: "Something you buy for them."
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .privilege: 0x5E5CE6
        case .experience: 0xE8650F
        case .money: 0x1E9E6A
        case .item: 0x0A84FF
        }
    }
}

nonisolated enum RewardLimit: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, oncePerDay, oncePerWeek, twicePerWeek, oncePerMonth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No limit"
        case .oncePerDay: "Once a day"
        case .oncePerWeek: "Once a week"
        case .twicePerWeek: "Twice a week"
        case .oncePerMonth: "Once a month"
        }
    }

    /// How many per period, and the period.
    var allowance: (count: Int, period: Calendar.Component)? {
        switch self {
        case .none: nil
        case .oncePerDay: (1, .day)
        case .oncePerWeek: (1, .weekOfYear)
        case .twicePerWeek: (2, .weekOfYear)
        case .oncePerMonth: (1, .month)
        }
    }
}

/// A kid asking for a reward.
@Model
final class Redemption {
    var id: UUID = UUID()
    var rewardID: UUID?
    var memberID: UUID?
    /// What it cost when asked for.
    var cost: Int = 0
    var statusRaw: String = RedemptionStatus.pending.rawValue
    var requestedAt: Date = Date.now
    var reviewedAt: Date?

    init(rewardID: UUID, memberID: UUID, cost: Int, status: RedemptionStatus) {
        self.rewardID = rewardID
        self.memberID = memberID
        self.cost = cost
        self.statusRaw = status.rawValue
    }

    var status: RedemptionStatus {
        get { RedemptionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var record: RedemptionRecord {
        RedemptionRecord(id: id, rewardID: rewardID, memberID: memberID, cost: cost, status: status, requestedAt: requestedAt)
    }
}

nonisolated enum RedemptionStatus: String, Codable, Sendable {
    case pending, approved, declined
}

/// One change to a kid's points. A kid's balance is the sum of theirs.
@Model
final class PointEntry {
    var id: UUID = UUID()
    var memberID: UUID?
    /// Positive for earned, negative for spent.
    var points: Int = 0
    var kindRaw: String = PointKind.chore.rawValue
    /// The completion, redemption or goal this came from.
    var refID: UUID?
    var date: Date = Date.now
    var note: String = ""

    init(memberID: UUID, points: Int, kind: PointKind, refID: UUID? = nil, note: String = "", date: Date = .now) {
        self.memberID = memberID
        self.points = points
        self.kindRaw = kind.rawValue
        self.refID = refID
        self.note = note
        self.date = date
    }

    var kind: PointKind {
        get { PointKind(rawValue: kindRaw) ?? .adjustment }
        set { kindRaw = newValue.rawValue }
    }

    var record: PointRecord {
        PointRecord(id: id, memberID: memberID, points: points, kind: kind, refID: refID, date: date)
    }
}

nonisolated enum PointKind: String, Codable, Sendable {
    /// An approved chore.
    case chore
    /// A streak bonus.
    case bonus
    /// A reward bought.
    case reward
    /// Points put toward a family goal.
    case goal
    /// Points turned into allowance.
    case cashOut
    /// A parent adding or taking away by hand.
    case adjustment
}

/// A home care job that comes around: replace the HVAC filter, test smoke detectors.
@Model
final class HomeTask {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "wrench.and.screwdriver"
    var areaRaw: String = HomeArea.other.rawValue
    var intervalCount: Int = 3
    var intervalUnitRaw: String = IntervalUnit.months.rawValue
    var nextDue: Date = Date.now
    /// Remind this many days before it's due.
    var remindDaysBefore: Int = 3
    /// "Upstairs hallway"
    var location: String = ""
    /// "16×25×1 MERV 11"
    var details: String = ""
    var notes: String = ""
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    init(name: String, symbol: String, area: HomeArea, intervalCount: Int, unit: IntervalUnit, nextDue: Date, location: String = "", details: String = "") {
        self.name = name
        self.symbol = symbol
        self.areaRaw = area.rawValue
        self.intervalCount = intervalCount
        self.intervalUnitRaw = unit.rawValue
        self.nextDue = nextDue
        self.location = location
        self.details = details
    }

    var area: HomeArea {
        get { HomeArea(rawValue: areaRaw) ?? .other }
        set { areaRaw = newValue.rawValue }
    }

    var intervalUnit: IntervalUnit {
        get { IntervalUnit(rawValue: intervalUnitRaw) ?? .months }
        set { intervalUnitRaw = newValue.rawValue }
    }

    /// "Every 90 days", "Monthly", "Yearly".
    var intervalLabel: String { HomeCareMath.intervalLabel(count: intervalCount, unit: intervalUnit) }
}

nonisolated enum IntervalUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case days, weeks, months, years

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var component: Calendar.Component {
        switch self {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        case .years: .year
        }
    }
}

nonisolated enum HomeArea: String, CaseIterable, Identifiable, Codable, Sendable {
    case heatingAir, safety, plumbing, appliances, outside, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heatingAir: "Heating & Air"
        case .safety: "Safety"
        case .plumbing: "Plumbing"
        case .appliances: "Appliances"
        case .outside: "Outside"
        case .other: "Other"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .heatingAir: 0xE8650F
        case .safety: 0xD93B30
        case .plumbing: 0x0A84FF
        case .appliances: 0x5E5CE6
        case .outside: 0x1E9E6A
        case .other: 0x8E8E93
        }
    }

    var symbol: String {
        switch self {
        case .heatingAir: "fan"
        case .safety: "light.beacon.max"
        case .plumbing: "drop"
        case .appliances: "washer"
        case .outside: "leaf"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// A home care task getting done.
@Model
final class HomeTaskLog {
    var id: UUID = UUID()
    var taskID: UUID?
    var memberID: UUID?
    var doneAt: Date = Date.now
    /// How late it was, in days (0 when on time).
    var daysLate: Int = 0
    /// The due date before this, so marking it done can be undone.
    var previousDue: Date?
    var note: String = ""

    init(taskID: UUID, memberID: UUID?, doneAt: Date = .now, daysLate: Int, previousDue: Date? = nil) {
        self.taskID = taskID
        self.memberID = memberID
        self.doneAt = doneAt
        self.daysLate = daysLate
        self.previousDue = previousDue
    }
}

/// A room in the house: Kitchen, Ella's Room, the garage. Chores can be assigned to one.
@Model
final class Room {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "door.left.hand.closed"
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    init(name: String, symbol: String, sortOrder: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.sortOrder = sortOrder
    }
}
