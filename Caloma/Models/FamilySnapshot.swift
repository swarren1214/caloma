import Foundation

/// The family's records at one moment, built from a screen's queries, with the questions every
/// screen asks: who the kids are, what's on the board, and what everyone has.
struct FamilySnapshot {
    var members: [Member]
    var chores: [ChoreRecord]
    var completions: [CompletionRecord]
    var points: [PointRecord]
    var redemptions: [RedemptionRecord]

    init(members: [Member], chores: [Chore], completions: [ChoreCompletion], points: [PointEntry], redemptions: [Redemption] = []) {
        self.members = members.filter { !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }
        self.chores = chores.map(\.record)
        self.completions = completions.map(\.record)
        self.points = points.map(\.record)
        self.redemptions = redemptions.map(\.record)
    }

    var kids: [Member] { members.filter(\.isKid) }
    var parents: [Member] { members.filter { !$0.isKid } }

    func member(_ id: UUID?) -> Member? {
        guard let id else { return nil }
        return members.first { $0.id == id }
    }

    func items(on day: Date = .now) -> [BoardItem] {
        ChoreMath.items(on: day, chores: chores, completions: completions)
    }

    func items(for kid: Member, on day: Date = .now) -> [BoardItem] {
        ChoreMath.items(for: kid.id, on: day, chores: chores, completions: completions)
    }

    /// Done (or waiting for an OK) of assigned today, not counting unclaimed up-for-grabs.
    func progress(for kid: Member, on day: Date = .now) -> (done: Int, total: Int) {
        let mine = items(for: kid, on: day).filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
        return (mine.filter { $0.status.isDone }.count, mine.count)
    }

    func balance(of kid: Member) -> Int { ChoreMath.balance(of: kid.id, entries: points) }
    func pending(of kid: Member) -> Int { ChoreMath.pendingPoints(of: kid.id, completions: completions) }
    func spendable(of kid: Member) -> Int { ChoreMath.spendable(of: kid.id, entries: points, redemptions: redemptions) }

    func streak(of kid: Member) -> Int {
        ChoreMath.streak(for: kid.id, through: .now, chores: chores, completions: completions)
    }

    func earnedThisWeek(by kid: Member, calendar: Calendar = .current) -> Int {
        let start = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return ChoreMath.earned(by: kid.id, since: start, entries: points)
    }

    /// Points a day over the last two weeks, for "about N days of chores".
    func pointsPerDay(of kid: Member, calendar: Calendar = .current) -> Double {
        let start = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: .now)) ?? .now
        return Double(ChoreMath.earned(by: kid.id, since: start, entries: points)) / 14
    }

    var pendingCompletionCount: Int { completions.filter { $0.status == .pending }.count }
    var pendingRedemptionCount: Int { redemptions.filter { $0.status == .pending }.count }
    var needsOKCount: Int { pendingCompletionCount + pendingRedemptionCount }
}
