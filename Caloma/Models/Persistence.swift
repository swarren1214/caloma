import Foundation
import OSLog
import SwiftData

enum Persistence {
    static let schema = Schema([
        Member.self,
        Chore.self,
        ChoreCompletion.self,
        Reward.self,
        Redemption.self,
        PointEntry.self,
        HomeTask.self,
        HomeTaskLog.self,
        Room.self,
        ChoreGroup.self,
        FamilyEvent.self,
        EventPacking.self,
        FamilySetting.self,
        Whiteboard.self,
        WallNote.self,
        DeviceStyle.self,
        FamilyList.self,
        FamilyListItem.self,
        FamilyListCheck.self,
    ])

    private static let log = Logger(subsystem: "com.stephenwarren.caloma", category: "persistence")

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        // The store itself never talks to iCloud: CloudSync does that, so the family can be
        // shared between Apple Accounts (SwiftData's own CloudKit mirroring can't share).
        let configuration = ModelConfiguration(
            "Caloma",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Never crash on launch over the store. Set the unreadable one aside (kept for
            // recovery) and start fresh; with sync on, iCloud fills it back in.
            SyncState().save()
            log.fault("Couldn't open the data store, starting a fresh one: \(error.localizedDescription, privacy: .public)")
            setAside(configuration.url)
            if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
                return container
            }
            log.fault("The fresh store failed too; running in memory this launch")
            let memory = ModelConfiguration("Caloma", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [memory])
            } catch {
                fatalError("Could not create even an in-memory Caloma store: \(error)")
            }
        }
    }

    /// Renames the store and its journal files with a timestamp, so a fresh store can be made.
    private static func setAside(_ url: URL) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: file.path) else { continue }
            let aside = URL(fileURLWithPath: url.path + ".unreadable-\(stamp)" + suffix)
            try? manager.moveItem(at: file, to: aside)
        }
    }

    static func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> [T] {
        do {
            return try context.fetch(FetchDescriptor<T>())
        } catch {
            log.error("Couldn't fetch \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            log.error("Couldn't save: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// One-time fixes to data saved by earlier versions, run at launch.
enum Upgrades {
    static func run(in context: ModelContext, defaults: UserDefaults = .standard) {
        giveParentsColors(in: context, defaults: defaults)
    }

    /// Parents used to be gray. Now everyone has a color, for the chore board and the calendar.
    private static func giveParentsColors(in context: ModelContext, defaults: UserDefaults) {
        let key = "upgrade.parentColors"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let members = Persistence.fetchAll(Member.self, in: context).sorted { $0.sortOrder < $1.sortOrder }
        var used = members.filter { $0.colorRaw != KidColor.gray.rawValue }.map(\.color)
        var changed = false
        for parent in members where !parent.isKid && parent.colorRaw == KidColor.gray.rawValue {
            let color = KidColor.next(for: .parent, after: used)
            parent.color = color
            used.append(color)
            changed = true
        }
        if changed { Persistence.save(context) }
    }
}

/// What a new family starts with: home care tasks on first launch, and the chores and rewards
/// picked during onboarding. All from the Tend designs.
enum StarterData {
    struct StarterChore: Identifiable, Hashable {
        var id: String { title }
        var title: String
        var symbol: String
        var points: Int
        var repeatRule: ChoreRepeat
        var weekdayMask: Int = 0
        var rotates: Bool = false
        var upForGrabs: Bool = false
        var requiresPhoto: Bool = false
    }

    static let chores: [StarterChore] = [
        StarterChore(title: "Make your bed", symbol: "bed.double", points: 5, repeatRule: .daily),
        StarterChore(title: "Brush teeth, morning and night", symbol: "mouth", points: 3, repeatRule: .daily),
        StarterChore(title: "Put toys away", symbol: "teddybear", points: 5, repeatRule: .daily),
        StarterChore(title: "Read for 20 minutes", symbol: "book", points: 10, repeatRule: .weekdays),
        StarterChore(title: "Set the table", symbol: "fork.knife", points: 5, repeatRule: .daily, rotates: true),
        StarterChore(title: "Unload the dishwasher", symbol: "dishwasher", points: 10, repeatRule: .daily, rotates: true, requiresPhoto: true),
        StarterChore(title: "Put away laundry", symbol: "tshirt", points: 10, repeatRule: .someDays, weekdayMask: ChoreMath.bit(forWeekday: 3)),
        StarterChore(title: "Take out trash and recycling", symbol: "trash", points: 15, repeatRule: .someDays, weekdayMask: ChoreMath.bit(forWeekday: 3), upForGrabs: true),
    ]

    struct StarterReward {
        var name: String
        var note: String
        var symbol: String
        var kind: RewardKind
        var cost: Int
        var limit: RewardLimit
    }

    static let rewards: [StarterReward] = [
        StarterReward(name: "30 Min Screen Time", note: "Up to twice a week", symbol: "tv", kind: .privilege, cost: 40, limit: .twicePerWeek),
        StarterReward(name: "Pick Friday Dinner", note: "Once a week", symbol: "fork.knife", kind: .privilege, cost: 60, limit: .oncePerWeek),
        StarterReward(name: "Stay Up 30 Min Late", note: "Weekends only", symbol: "moon.stars", kind: .privilege, cost: 80, limit: .oncePerWeek),
        StarterReward(name: "Skip One Chore", note: "Not on trash night", symbol: "checkmark.circle", kind: .privilege, cost: 70, limit: .oncePerWeek),
        StarterReward(name: "Bake Cookies Together", note: "Saturday afternoon", symbol: "birthday.cake", kind: .experience, cost: 120, limit: .oncePerWeek),
        StarterReward(name: "Movie Night Pick", note: "Popcorn included", symbol: "film", kind: .experience, cost: 250, limit: .oncePerMonth),
        StarterReward(name: "Date With Mom or Dad", note: "A one-on-one outing", symbol: "calendar", kind: .experience, cost: 400, limit: .oncePerMonth),
        StarterReward(name: "$5 Cash Out", note: "Paid on payday", symbol: "banknote", kind: .money, cost: 100, limit: .none),
        StarterReward(name: "New Book", note: "Up to $15", symbol: "book.closed", kind: .item, cost: 300, limit: .oncePerMonth),
    ]

    struct StarterHomeTask {
        var name: String
        var symbol: String
        var area: HomeArea
        var count: Int
        var unit: IntervalUnit
        var firstDueInDays: Int
    }

    static let homeTasks: [StarterHomeTask] = [
        StarterHomeTask(name: "Replace HVAC filter", symbol: "fan", area: .heatingAir, count: 90, unit: .days, firstDueInDays: 7),
        StarterHomeTask(name: "Test smoke detectors", symbol: "light.beacon.max", area: .safety, count: 1, unit: .months, firstDueInDays: 12),
        StarterHomeTask(name: "Clean dryer vent", symbol: "dryer", area: .appliances, count: 6, unit: .months, firstDueInDays: 30),
        StarterHomeTask(name: "Clean gutters", symbol: "house", area: .outside, count: 6, unit: .months, firstDueInDays: 45),
        StarterHomeTask(name: "Flush water heater", symbol: "drop", area: .plumbing, count: 1, unit: .years, firstDueInDays: 60),
        StarterHomeTask(name: "Replace fridge water filter", symbol: "refrigerator", area: .appliances, count: 6, unit: .months, firstDueInDays: 75),
        StarterHomeTask(name: "Check fire extinguisher", symbol: "flame", area: .safety, count: 1, unit: .years, firstDueInDays: 90),
        StarterHomeTask(name: "Service the furnace", symbol: "heater.vertical", area: .heatingAir, count: 1, unit: .years, firstDueInDays: 120),
    ]

    /// Rooms most homes have, offered in Profile › Rooms with Add Common Rooms.
    static let rooms: [(name: String, symbol: String)] = [
        ("Kitchen", "fork.knife"), ("Living Room", "sofa"), ("Dining Room", "chair"),
        ("Bathroom", "shower"), ("Laundry Room", "washer"), ("Garage", "door.garage.closed"),
        ("Yard", "leaf"), ("Playroom", "teddybear"),
    ]

    /// Adds the common rooms, skipping any the family already has by name.
    static func insertRooms(into context: ModelContext, existing: [Room]) {
        let names = Set(existing.filter { !$0.isArchived }.map { $0.name.lowercased() })
        var order = (existing.map(\.sortOrder).max() ?? -1) + 1
        for room in rooms where !names.contains(room.name.lowercased()) {
            context.insert(Room(name: room.name, symbol: room.symbol, sortOrder: order))
            order += 1
        }
    }

    /// Adds the starter home care tasks once, the first time the app opens with an empty store.
    static func seedIfNeeded(in context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) {
        guard !defaults.bool(forKey: SettingsKey.seeded) else { return }
        defaults.set(true, forKey: SettingsKey.seeded)
        let existing = (try? context.fetchCount(FetchDescriptor<HomeTask>())) ?? 0
        guard existing == 0 else { return }
        insertHomeTasks(into: context, now: now)
        Persistence.save(context)
    }

    static func insertHomeTasks(into context: ModelContext, now: Date = .now) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        for task in homeTasks {
            let due = calendar.date(byAdding: .day, value: task.firstDueInDays, to: today) ?? today
            context.insert(HomeTask(name: task.name, symbol: task.symbol, area: task.area, intervalCount: task.count, unit: task.unit, nextDue: due))
        }
    }

    /// The chores picked in onboarding, for every kid (taking turns where it says so).
    static func insertChores(_ picked: [StarterChore], kids: [Member], into context: ModelContext, now: Date = .now) {
        let ids = kids.map(\.id)
        let approvals = UserDefaults.standard.object(forKey: SettingsKey.approvalsByDefault) as? Bool ?? true
        for (index, starter) in picked.enumerated() {
            let chore = Chore(title: starter.title, symbol: starter.symbol, points: starter.points, assigneeIDs: ids, repeatRule: starter.repeatRule, weekdayMask: starter.weekdayMask, startDate: now, requiresApproval: approvals, sortOrder: index)
            chore.rotates = starter.rotates && ids.count > 1
            chore.upForGrabs = starter.upForGrabs
            chore.requiresPhoto = starter.requiresPhoto
            context.insert(chore)
        }
    }

    /// The family store from the designs, plus a family goal.
    static func insertRewards(into context: ModelContext, goal: String? = "Zoo Day", goalCost: Int = 1200) {
        for (index, starter) in rewards.enumerated() {
            context.insert(Reward(name: starter.name, note: starter.note, symbol: starter.symbol, kind: starter.kind, cost: starter.cost, limit: starter.limit, sortOrder: index))
        }
        if let goal {
            context.insert(Reward(name: goal, note: "Everyone chips in", symbol: "flag.checkered", kind: .experience, cost: goalCost, isFamilyGoal: true, sortOrder: rewards.count))
        }
    }
}
