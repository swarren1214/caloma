import Foundation
import SwiftData

/// Everything that changes points, chores, rewards and home care goes through here, so the
/// points ledger always matches what happened.
enum Family {
    // MARK: Chores

    /// Marks a board item done. A parent checking it off (or a chore that doesn't need an OK)
    /// approves it straight away; a kid's tap waits for a parent.
    @discardableResult
    static func markDone(_ item: BoardItem, by memberID: UUID, byParent: Bool, photo: Data? = nil, in context: ModelContext) -> ChoreCompletion {
        let approved = byParent || !item.chore.requiresApproval
        let completion = ChoreCompletion(choreID: item.chore.id, memberID: memberID, day: item.occurrenceDay, points: item.chore.points, status: approved ? .approved : .pending, photoData: photo)
        context.insert(completion)
        if approved {
            completion.reviewedAt = .now
            award(completion, title: item.chore.title, in: context)
        }
        Persistence.save(context)
        return completion
    }

    static func approve(_ completion: ChoreCompletion, in context: ModelContext) {
        guard completion.status == .pending else { return }
        completion.status = .approved
        completion.reviewedAt = .now
        let chore = chore(completion.choreID, in: context)
        award(completion, title: chore?.title ?? "Chore", in: context)
        Persistence.save(context)
        ApprovalAlerts.clear([completion.id])
    }

    /// Opens it again for the kid.
    static func sendBack(_ completion: ChoreCompletion, in context: ModelContext) {
        completion.status = .sentBack
        completion.reviewedAt = .now
        Persistence.save(context)
        ApprovalAlerts.clear([completion.id])
    }

    /// Takes a completion back entirely, points and all.
    static func undo(_ completion: ChoreCompletion, in context: ModelContext) {
        let id: UUID? = completion.id
        let entries = (try? context.fetch(FetchDescriptor<PointEntry>(predicate: #Predicate { $0.refID == id }))) ?? []
        for entry in entries { context.delete(entry) }
        context.delete(completion)
        Persistence.save(context)
    }

    static func approveAll(_ completions: [ChoreCompletion], in context: ModelContext) {
        for completion in completions where completion.status == .pending {
            completion.status = .approved
            completion.reviewedAt = .now
            award(completion, title: chore(completion.choreID, in: context)?.title ?? "Chore", in: context)
        }
        Persistence.save(context)
        ApprovalAlerts.clear(completions.map(\.id))
    }

    private static func award(_ completion: ChoreCompletion, title: String, in context: ModelContext) {
        guard let memberID = completion.memberID else { return }
        // Parents can have chores too, but only kids earn points.
        let earns = member(memberID, in: context)?.isKid ?? true
        if earns {
            context.insert(PointEntry(memberID: memberID, points: completion.points, kind: .chore, refID: completion.id, note: title))
        }
        // A home care task handed to a kid is done when the kid's chore is.
        if let chore = chore(completion.choreID, in: context), let taskID = chore.homeTaskID,
           let task = homeTask(taskID, in: context) {
            markHomeTaskDone(task, by: memberID, save: false, in: context)
        }
        if earns { awardStreakBonusIfEarned(memberID, in: context) }
    }

    /// +10 on every seventh day in a row, once per day, when Family › Streak Bonus is on.
    private static func awardStreakBonusIfEarned(_ memberID: UUID, in context: ModelContext, defaults: UserDefaults = .standard) {
        let on = defaults.object(forKey: SettingsKey.streakBonus) as? Bool ?? true
        guard on else { return }
        let chores = Persistence.fetchAll(Chore.self, in: context).map(\.record)
        let completions = Persistence.fetchAll(ChoreCompletion.self, in: context).map(\.record)
        let streak = ChoreMath.streak(for: memberID, through: .now, chores: chores, completions: completions)
        guard streak > 0, streak % 7 == 0 else { return }
        // Only if today's chores are all done, so the bonus lands on the day the streak is made.
        let today = ChoreMath.items(for: memberID, on: .now, chores: chores, completions: completions).filter { !$0.chore.upForGrabs }
        guard !today.isEmpty, today.allSatisfy({ $0.status.isDone }) else { return }
        let start = Calendar.current.startOfDay(for: .now)
        let bonusKind = PointKind.bonus.rawValue
        let member: UUID? = memberID
        let already = (try? context.fetchCount(FetchDescriptor<PointEntry>(predicate: #Predicate {
            $0.memberID == member && $0.kindRaw == bonusKind && $0.date >= start
        }))) ?? 0
        guard already == 0 else { return }
        context.insert(PointEntry(memberID: memberID, points: 10, kind: .bonus, note: "\(streak) days in a row"))
    }

    // MARK: Rewards

    /// A kid asking for a reward. Rewards that don't need an OK are spent right away.
    @discardableResult
    static func request(_ reward: Reward, for memberID: UUID, in context: ModelContext) -> Redemption {
        let redemption = Redemption(rewardID: reward.id, memberID: memberID, cost: reward.cost, status: reward.needsApproval ? .pending : .approved)
        context.insert(redemption)
        if !reward.needsApproval {
            redemption.reviewedAt = .now
            context.insert(PointEntry(memberID: memberID, points: -reward.cost, kind: .reward, refID: redemption.id, note: reward.name))
        }
        Persistence.save(context)
        return redemption
    }

    static func approve(_ redemption: Redemption, in context: ModelContext) {
        guard redemption.status == .pending, let memberID = redemption.memberID else { return }
        redemption.status = .approved
        redemption.reviewedAt = .now
        let name = reward(redemption.rewardID, in: context)?.name ?? "Reward"
        context.insert(PointEntry(memberID: memberID, points: -redemption.cost, kind: .reward, refID: redemption.id, note: name))
        Persistence.save(context)
        ApprovalAlerts.clear([redemption.id])
    }

    static func decline(_ redemption: Redemption, in context: ModelContext) {
        redemption.status = .declined
        redemption.reviewedAt = .now
        Persistence.save(context)
        ApprovalAlerts.clear([redemption.id])
    }

    /// A kid putting points toward a family goal.
    static func contribute(_ points: Int, from memberID: UUID, to goal: Reward, in context: ModelContext) {
        guard points > 0 else { return }
        context.insert(PointEntry(memberID: memberID, points: -points, kind: .goal, refID: goal.id, note: goal.name))
        Persistence.save(context)
    }

    /// The family reached the goal: it leaves the store's goal spot (archived), history stays.
    static func finishGoal(_ goal: Reward, in context: ModelContext) {
        goal.isArchived = true
        Persistence.save(context)
    }

    /// Points turned into allowance.
    static func payOut(_ points: Int, to memberID: UUID, cents: Int, in context: ModelContext) {
        guard points > 0 else { return }
        let money = (Double(cents) / 100).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
        let entry = PointEntry(memberID: memberID, points: -points, kind: .cashOut, note: "Paid \(money)")
        entry.cents = cents
        context.insert(entry)
        Persistence.save(context)
    }

    static func adjust(_ points: Int, for memberID: UUID, note: String, in context: ModelContext) {
        guard points != 0 else { return }
        context.insert(PointEntry(memberID: memberID, points: points, kind: .adjustment, note: note))
        Persistence.save(context)
    }

    // MARK: Home care

    static func markHomeTaskDone(_ task: HomeTask, by memberID: UUID?, at date: Date = .now, save: Bool = true, in context: ModelContext) {
        let late = HomeCareMath.daysLate(due: task.nextDue, doneAt: date)
        context.insert(HomeTaskLog(taskID: task.id, memberID: memberID, doneAt: date, daysLate: late, previousDue: task.nextDue))
        task.nextDue = HomeCareMath.nextDue(after: date, count: task.intervalCount, unit: task.intervalUnit)
        if save { Persistence.save(context) }
        Reminders.reschedule(in: context)
    }

    /// Undoes the latest time it was marked done.
    static func undoLastHomeTask(_ task: HomeTask, in context: ModelContext) {
        let id: UUID? = task.id
        var descriptor = FetchDescriptor<HomeTaskLog>(predicate: #Predicate { $0.taskID == id }, sortBy: [SortDescriptor(\.doneAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let last = try? context.fetch(descriptor).first else { return }
        if let previous = last.previousDue { task.nextDue = previous }
        context.delete(last)
        Persistence.save(context)
        Reminders.reschedule(in: context)
    }

    /// Hands a home care task to a kid as a one-time chore. When it's approved, the task is
    /// marked done.
    @discardableResult
    static func give(_ task: HomeTask, to kid: Member, points: Int, in context: ModelContext) -> Chore {
        let chore = Chore(title: task.name, symbol: task.symbol, points: points, assigneeIDs: [kid.id], repeatRule: .once, startDate: .now, requiresApproval: true, sortOrder: -1)
        chore.homeTaskID = task.id
        context.insert(chore)
        Persistence.save(context)
        return chore
    }

    // MARK: Erase

    /// Deletes everything and starts over at onboarding. With sync on, the family's iCloud
    /// data goes too (or, for a parent who joined, they leave the family).
    static func eraseAll(in context: ModelContext, defaults: UserDefaults = .standard) {
        CloudSync.shared.pauseForErase()
        // Back to onboarding first, so no open screen draws a record that's being deleted.
        for key in [SettingsKey.onboarded, SettingsKey.seeded, SettingsKey.currentMember, SettingsKey.kidViewOpen, SettingsKey.kidViewMember, SettingsKey.kioskOpen, SettingsKey.kioskFaces, SettingsKey.kioskScreensaverPhotos, SettingsKey.kioskScreensaverAlbums] {
            defaults.removeObject(forKey: key)
        }
        ParentPIN.clear()
        ProfileLock.clearAll(defaults: defaults)
        FaceStore.shared.eraseAll()
        ScreensaverLibrary.eraseAll()
        try? context.delete(model: Member.self)
        try? context.delete(model: Chore.self)
        try? context.delete(model: ChoreCompletion.self)
        try? context.delete(model: Reward.self)
        try? context.delete(model: Redemption.self)
        try? context.delete(model: PointEntry.self)
        try? context.delete(model: HomeTask.self)
        try? context.delete(model: HomeTaskLog.self)
        try? context.delete(model: FamilyEvent.self)
        try? context.delete(model: EventPacking.self)
        try? context.delete(model: Room.self)
        try? context.delete(model: ChoreGroup.self)
        try? context.delete(model: FamilySetting.self)
        try? context.delete(model: Whiteboard.self)
        try? context.delete(model: WallNote.self)
        try? context.delete(model: FamilyList.self)
        try? context.delete(model: FamilyListItem.self)
        try? context.delete(model: FamilyListCheck.self)
        Persistence.save(context)
        Reminders.cancelAll()
        Task {
            await CloudSync.shared.eraseEverywhere()
            await CloudSync.shared.didEraseLocally()
        }
    }

    // MARK: Lookups

    static func chore(_ id: UUID?, in context: ModelContext) -> Chore? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Chore>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func member(_ id: UUID?, in context: ModelContext) -> Member? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Member>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func reward(_ id: UUID?, in context: ModelContext) -> Reward? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Reward>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func homeTask(_ id: UUID?, in context: ModelContext) -> HomeTask? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<HomeTask>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
