import SwiftData
import SwiftUI

/// Screenshot mode, for marketing screenshots (the shared screenshots script).
///
/// Launched with `-Screenshots`, Caloma runs on an in-memory store filled with a demo family,
/// skips onboarding, and leaves iCloud sync, the Apple Watch, Apple Calendar and notifications
/// alone, so the simulator's own family and iCloud are never touched. Adding `-Screen <name>`
/// opens one screen (see `Screen`). Debug builds only: Release ignores the arguments, so none
/// of this can be reached in the App Store build.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The screens the script captures, by the name passed after `-Screen`.
    nonisolated enum Screen: String, CaseIterable {
        case home, chores, approvals, kid, calendar, event, rewards, homecare, hometask, kidview, kidday, kidstore
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()

    /// Ella, the demo kid on the kid screens and in Kid View.
    static let demoKidID = UUID(uuidString: "3E1A2C4B-0D5F-4A6E-9B7C-1E2F3A4B5C6D")!
    /// Soccer practice, opened on the event screen.
    static let demoEventID = UUID(uuidString: "7B2D9E10-4C3A-4F8B-A1D2-6E5F4A3B2C1D")!
    /// Replace HVAC filter, opened on the home care task screen.
    static let demoHomeTaskID = UUID(uuidString: "A4C3B2D1-9E8F-4A7B-8C6D-5E4F3A2B1C0D")!

    /// At launch, before anything reads them: the settings that would otherwise show onboarding.
    /// Registered, not saved, so this simulator's own settings stay as they were.
    @MainActor
    static func prepareLaunch() {
        guard isOn else { return }
        UserDefaults.standard.register(defaults: [
            SettingsKey.onboarded: true,
            SettingsKey.familyName: "The Parkers",
        ])
    }
}

/// Screens pushed only in screenshot mode (the app reaches them through inline links).
nonisolated enum ScreenshotRoute: Hashable {
    case kid(UUID)
    case homeTask(UUID)
    case kidStore
}

extension View {
    /// Destinations for `ScreenshotRoute`, added to the tabs' root views.
    func screenshotDestinations() -> some View {
        navigationDestination(for: ScreenshotRoute.self) { route in
            switch route {
            case .kid(let id): KidDetailView(kidID: id)
            case .homeTask(let id): ScreenshotHomeTask(id: id)
            case .kidStore: EmptyView()
            }
        }
    }

    /// Screenshot mode: fills the store with the demo family, then opens the requested screen.
    /// Does nothing otherwise.
    func screenshotStage(homePath: Binding<NavigationPath>, homeCarePath: Binding<NavigationPath>) -> some View {
        modifier(ScreenshotStage(homePath: homePath, homeCarePath: homeCarePath))
    }
}

/// A home care task by id, for `ScreenshotRoute.homeTask`.
private struct ScreenshotHomeTask: View {
    var id: UUID
    @Query private var tasks: [HomeTask]

    var body: some View {
        if let task = tasks.first(where: { $0.id == id }) {
            HomeTaskDetailView(task: task)
        }
    }
}

private struct ScreenshotStage: ViewModifier {
    @Binding var homePath: NavigationPath
    @Binding var homeCarePath: NavigationPath

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @State private var event: OccurrenceRef?

    func body(content view: Content) -> some View {
        if ScreenshotMode.isOn {
            view
                .task { await stage() }
                .sheet(item: $event) { ref in
                    NavigationStack {
                        EventDetailView(eventID: ref.eventID, day: ref.day)
                    }
                    .tint(accent)
                    .environment(\.accent, accent)
                }
        } else {
            view
        }
    }

    private func stage() async {
        ScreenshotSeed.seed(in: context)
        // Let the first screen settle before moving on from it.
        try? await Task.sleep(for: .milliseconds(400))
        guard let screen = ScreenshotMode.screen else { return }
        switch screen {
        case .home:
            router.tab = .home
        case .chores:
            router.tab = .chores
        case .approvals:
            router.tab = .home
            router.sheet = .approvals
        case .kid:
            router.tab = .home
            homePath.append(ScreenshotRoute.kid(ScreenshotMode.demoKidID))
        case .calendar:
            router.tab = .calendar
        case .event:
            router.tab = .calendar
            try? await Task.sleep(for: .milliseconds(300))
            event = OccurrenceRef(eventID: ScreenshotMode.demoEventID, day: Calendar.current.startOfDay(for: .now))
        case .rewards:
            router.tab = .rewards
        case .homecare:
            router.tab = .homeCare
        case .hometask:
            router.tab = .homeCare
            homeCarePath.append(ScreenshotRoute.homeTask(ScreenshotMode.demoHomeTaskID))
        case .kidview, .kidday, .kidstore:
            // Kid View shows the demo kid (see KidModeView); My Day and the store open from there.
            router.tab = .home
            router.openKidView()
        }
    }
}

// MARK: - Demo family

/// The Parkers: Laura and Dan, and Ella (9), Theo (7) and June (5). Five weeks of chores with a
/// few missed days (so streaks of 12, 5 and 21 days), streak bonuses, rewards bought and a
/// family goal two-thirds funded, today part done with some waiting for an OK, a busy week on
/// the calendar, and a home care list with history.
@MainActor
enum ScreenshotSeed {
    private static var seeded = false

    static func seed(in context: ModelContext, calendar: Calendar = .current) {
        guard ScreenshotMode.isOn, !seeded else { return }
        seeded = true
        let today = calendar.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        func at(_ date: Date, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }

        // MARK: Family and rooms

        let laura = Member(name: "Laura", role: .parent, color: .teal, sortOrder: 0)
        let dan = Member(name: "Dan", role: .parent, color: .indigo, sortOrder: 1)
        let ella = Member(name: "Ella", role: .kid, color: .purple, sortOrder: 2)
        ella.id = ScreenshotMode.demoKidID
        let theo = Member(name: "Theo", role: .kid, color: .blue, sortOrder: 3)
        let june = Member(name: "June", role: .kid, color: .orange, sortOrder: 4)
        let kids = [ella, theo, june]
        for member in [laura, dan, ella, theo, june] { context.insert(member) }

        let kitchen = Room(name: "Kitchen", symbol: "fork.knife", sortOrder: 0)
        let living = Room(name: "Living Room", symbol: "sofa", sortOrder: 1)
        let bathroom = Room(name: "Bathroom", symbol: "shower", sortOrder: 2)
        let laundryRoom = Room(name: "Laundry Room", symbol: "washer", sortOrder: 3)
        let yard = Room(name: "Yard", symbol: "leaf", sortOrder: 4)
        for room in [kitchen, living, bathroom, laundryRoom, yard] { context.insert(room) }

        // MARK: Chores

        let started = day(-42)
        let tuesday = ChoreMath.bit(forWeekday: 3)
        let friday = ChoreMath.bit(forWeekday: 6)
        var order = 0
        func chore(_ title: String, _ symbol: String, _ points: Int, _ who: [Member], _ rule: ChoreRepeat = .daily, mask: Int = 0, room: Room? = nil) -> Chore {
            let chore = Chore(title: title, symbol: symbol, points: points, assigneeIDs: who.map(\.id), repeatRule: rule, weekdayMask: mask, startDate: started, sortOrder: order)
            chore.roomID = room?.id
            order += 1
            context.insert(chore)
            return chore
        }
        _ = chore("Make your bed", "bed.double", 5, [ella, theo])
        let dishes = chore("Unload the dishwasher", "dishwasher", 10, [ella], room: kitchen)
        dishes.requiresPhoto = true
        dishes.priority = .high
        let biscuit = chore("Feed Biscuit", "pawprint", 5, [ella, theo])
        biscuit.rotates = true
        _ = chore("Vacuum the living room", "sparkles", 20, [ella], .someDays, mask: tuesday | friday, room: living)
        _ = chore("Read for 20 minutes", "book", 10, [ella], .weekdays)
        _ = chore("Practice piano 20 min", "music.note", 15, [theo], .weekdays)
        _ = chore("Put away laundry", "tshirt", 10, [theo], .someDays, mask: ChoreMath.bit(forWeekday: 2) | ChoreMath.bit(forWeekday: 5), room: laundryRoom)
        let sink = chore("Clean the bathroom sink", "sink", 15, [theo], .someDays, mask: ChoreMath.bit(forWeekday: 7), room: bathroom)
        sink.requiresPhoto = true
        _ = chore("Brush teeth, morning and night", "mouth", 3, [june])
        _ = chore("Put toys away", "teddybear", 5, [june])
        let table = chore("Set the table", "fork.knife", 5, [june], room: kitchen)
        table.priority = .medium
        let trash = chore("Take out trash and recycling", "trash", 15, kids, .someDays, mask: tuesday, room: yard)
        trash.upForGrabs = true
        Persistence.save(context)
        let records = Persistence.fetchAll(Chore.self, in: context).map(\.record)

        // MARK: Five weeks of chores done

        // A missed chore on these days ends a streak: Ella's is 12, Theo's 5, June's 21 today.
        let missed: [UUID: Set<Int>] = [ella.id: [-13, -27], theo.id: [-6, -17, -30], june.id: [-21]]
        var runs: [UUID: Int] = [:]
        for offset in -35 ... -1 {
            let date = day(offset)
            let items = ChoreMath.items(on: date, chores: records, completions: [])
            for kid in kids {
                let mine = items.filter { $0.memberID == kid.id && !$0.chore.upForGrabs }
                let misses = missed[kid.id]?.contains(offset) ?? false
                for (index, item) in mine.enumerated() {
                    // On a missed day, the last chore of the day didn't get done.
                    if misses && index == mine.count - 1 { continue }
                    let done = index == 0 ? at(date, 7, 25 + index * 5) : at(date, 16 + index % 3, (index * 17) % 60)
                    approved(item.chore, kid, day: date, done: done, in: context)
                }
                guard !mine.isEmpty else { continue }
                // +10 for every seventh day in a row, as the app gives it.
                let run = misses ? 0 : (runs[kid.id] ?? 0) + 1
                runs[kid.id] = run
                if run > 0, run % 7 == 0 {
                    context.insert(PointEntry(memberID: kid.id, points: 10, kind: .bonus, note: "\(run) days in a row", date: at(date, 19, 30)))
                }
            }
            // Trash night: whoever grabbed it first, a different kid most weeks.
            for item in items where item.chore.upForGrabs {
                let kid = kids[(offset + 35) / 7 % kids.count]
                approved(item.chore, kid, day: date, done: at(date, 18, 40), in: context)
            }
        }

        // MARK: Rewards, the family goal and allowance

        StarterData.insertRewards(into: context)
        Persistence.save(context)
        let rewards = Persistence.fetchAll(Reward.self, in: context)
        func bought(_ name: String, by kid: Member, daysAgo: Int) {
            guard let reward = rewards.first(where: { $0.name == name }) else { return }
            let redemption = Redemption(rewardID: reward.id, memberID: kid.id, cost: reward.cost, status: .approved)
            redemption.requestedAt = at(day(-daysAgo), 18, 5)
            redemption.reviewedAt = at(day(-daysAgo), 18, 40)
            context.insert(redemption)
            context.insert(PointEntry(memberID: kid.id, points: -reward.cost, kind: .reward, refID: redemption.id, note: reward.name, date: at(day(-daysAgo), 18, 40)))
        }
        bought("30 Min Screen Time", by: ella, daysAgo: 25)
        bought("Pick Friday Dinner", by: ella, daysAgo: 19)
        bought("30 Min Screen Time", by: ella, daysAgo: 11)
        bought("New Book", by: ella, daysAgo: 8)
        bought("30 Min Screen Time", by: ella, daysAgo: 3)
        bought("30 Min Screen Time", by: theo, daysAgo: 22)
        bought("Movie Night Pick", by: theo, daysAgo: 15)
        bought("30 Min Screen Time", by: theo, daysAgo: 4)
        bought("Bake Cookies Together", by: june, daysAgo: 10)

        if let goal = rewards.first(where: { $0.isFamilyGoal }) {
            let chipIns: [(Member, Int, Int)] = [
                (ella, 120, 28), (theo, 90, 26), (june, 50, 24), (ella, 100, 18), (theo, 100, 16),
                (june, 60, 13), (ella, 140, 6), (theo, 100, 5), (june, 60, 2),
            ]
            for (kid, points, daysAgo) in chipIns {
                context.insert(PointEntry(memberID: kid.id, points: -points, kind: .goal, refID: goal.id, note: goal.name, date: at(day(-daysAgo), 19, 10)))
            }
        }
        let paid = (Double(500) / 100).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
        context.insert(PointEntry(memberID: theo.id, points: -100, kind: .cashOut, note: "Paid \(paid)", date: at(day(-7), 9)))
        Persistence.save(context)

        // MARK: Today, part done

        // Through the app, as a parent's check-off or a kid's tap (which waits for an OK).
        let todayItems = ChoreMath.items(on: today, chores: records, completions: [])
        // Per kid: how many of today's chores are done, and which of those wait for an OK.
        let plan: [UUID: (done: Int, pending: Set<Int>)] = [ella.id: (done: 2, pending: [0]), theo.id: (done: 2, pending: [1]), june.id: (done: 99, pending: [2])]
        var minutesAgo = 140
        for kid in kids {
            guard let todo = plan[kid.id] else { continue }
            let mine = todayItems.filter { $0.memberID == kid.id && !$0.chore.upForGrabs }
            for (index, item) in mine.enumerated() where index < todo.done {
                let completion = Family.markDone(item, by: kid.id, byParent: !todo.pending.contains(index), in: context)
                completion.completedAt = Date.now.addingTimeInterval(-Double(minutesAgo) * 60)
                minutesAgo -= 12
            }
        }
        if let dinner = rewards.first(where: { $0.name == "Pick Friday Dinner" }) {
            Family.request(dinner, for: june.id, in: context)
        }

        // MARK: Calendar

        let weekday = calendar.component(.weekday, from: today)
        func weekdayBit(_ offset: Int) -> Int { ChoreMath.bit(forWeekday: (weekday - 1 + offset) % 7 + 1) }
        func event(_ title: String, _ symbol: String, start: Date, minutes: Int, who: [Member], driver: Member? = nil, rule: EventRepeat = .never, mask: Int = 0, location: String = "", bring: [String] = []) -> FamilyEvent {
            let event = FamilyEvent(title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60), attendeeIDs: who.map(\.id))
            event.symbol = symbol
            event.driverID = driver?.id
            event.repeatRule = rule
            event.weekdayMask = mask
            event.location = location
            event.bring = bring
            event.alertMinutes = 60
            context.insert(event)
            return event
        }
        let weeksAgo = day(-28)
        _ = event("School drop-off", "graduationcap", start: at(weeksAgo, 7, 45), minutes: 25, who: [ella, theo], driver: laura, rule: .weekly, mask: ChoreMath.weekdaysMask, location: "Lincoln Elementary")
        let soccer = event("Soccer practice", "soccerball", start: at(weeksAgo, 16, 30), minutes: 75, who: [ella], driver: dan, rule: .weekly, mask: weekdayBit(0) | weekdayBit(2), location: "Riverside Park · Field 3", bring: ["Cleats", "Shin guards", "Water bottle"])
        soccer.id = ScreenshotMode.demoEventID
        soccer.notes = "Coach Rivera asks everyone to be there 10 minutes early to warm up."
        _ = event("Piano lesson", "music.note", start: at(weeksAgo, 15, 15), minutes: 45, who: [theo], driver: laura, rule: .weekly, mask: weekdayBit(0), location: "Harmony Music Studio", bring: ["Piano books"])
        _ = event("Swim lessons", "figure.pool.swim", start: at(weeksAgo, 10), minutes: 30, who: [june], driver: laura, rule: .weekly, mask: weekdayBit(1), location: "Westside Rec Center", bring: ["Swimsuit", "Goggles", "Towel"])
        _ = event("Pizza night", "fork.knife", start: at(weeksAgo, 18), minutes: 90, who: [], rule: .weekly, mask: friday, location: "Home")
        _ = event("Dentist checkup", "stethoscope", start: at(day(1), 16), minutes: 45, who: [june], driver: dan, location: "Bright Smiles Dental")
        let movie = event("Movie night", "film", start: at(day(2), 19), minutes: 120, who: [], location: "Living room", bring: ["Blankets", "Pillows"])
        movie.countsDown = true
        _ = event("Grandma Rose's birthday dinner", "birthday.cake", start: at(day(4), 17, 30), minutes: 120, who: [], driver: dan, location: "Grandma Rose's house", bring: ["Card", "Flowers"])
        let camping = FamilyEvent(title: "Camping trip", start: day(9), end: day(11), isAllDay: true)
        camping.symbol = "tent"
        camping.location = "Pine Lake Campground"
        camping.bring = ["Sleeping bag", "Flashlight", "Rain jacket"]
        camping.countsDown = true
        context.insert(camping)
        // Ella has packed most of her soccer bag.
        let packing = EventPacking(eventID: soccer.id, memberID: ella.id, day: today)
        packing.packed = ["Cleats", "Shin guards"]
        context.insert(packing)

        // MARK: Home care

        func homeTask(_ name: String, _ symbol: String, _ area: HomeArea, every count: Int, _ unit: IntervalUnit, dueIn: Int, location: String = "", details: String = "", doneDaysAgo: [Int] = [], by member: Member? = nil, id: UUID? = nil) -> HomeTask {
            let task = HomeTask(name: name, symbol: symbol, area: area, intervalCount: count, unit: unit, nextDue: day(dueIn), location: location, details: details)
            if let id { task.id = id }
            context.insert(task)
            for (index, ago) in doneDaysAgo.enumerated() {
                let who = member ?? (index % 2 == 0 ? dan : laura)
                context.insert(HomeTaskLog(taskID: task.id, memberID: who.id, doneAt: at(day(-ago), 10, 15), daysLate: index == 1 ? 2 : 0))
            }
            return task
        }
        let filter = homeTask("Replace HVAC filter", "fan", .heatingAir, every: 90, .days, dueIn: -3, location: "Upstairs hallway", details: "16×25×1 MERV 11", doneDaysAgo: [93, 185, 277], by: dan, id: ScreenshotMode.demoHomeTaskID)
        filter.notes = "Return vent is in the upstairs hallway ceiling. The arrow on the filter points toward the furnace. Spares are on the garage shelf."
        _ = homeTask("Test smoke detectors", "light.beacon.max", .safety, every: 1, .months, dueIn: 5, location: "Every floor", doneDaysAgo: [25, 56, 86, 117, 147, 178, 208, 239], by: laura)
        _ = homeTask("Clean gutters", "house", .outside, every: 6, .months, dueIn: 9, doneDaysAgo: [174])
        _ = homeTask("Winterize sprinklers", "sprinkler.and.droplets", .outside, every: 1, .years, dueIn: 12, location: "Side yard valve box", doneDaysAgo: [353])
        _ = homeTask("Clean dryer vent", "dryer", .appliances, every: 6, .months, dueIn: 18, location: "Laundry room", doneDaysAgo: [165])
        _ = homeTask("Service the furnace", "heater.vertical", .heatingAir, every: 1, .years, dueIn: 26, details: "Comfort Air Heating", doneDaysAgo: [339])
        _ = homeTask("Replace fridge water filter", "refrigerator", .appliances, every: 6, .months, dueIn: 47, details: "Filter model WF3CB", doneDaysAgo: [136])
        _ = homeTask("Flush water heater", "drop", .plumbing, every: 1, .years, dueIn: 64, location: "Garage", doneDaysAgo: [301])
        _ = homeTask("Check fire extinguisher", "flame", .safety, every: 1, .years, dueIn: 120, location: "Under the kitchen sink")

        Persistence.save(context)
    }

    /// A chore done and approved on an earlier day, with its points, as `Family` records it.
    private static func approved(_ chore: ChoreRecord, _ kid: Member, day: Date, done: Date, in context: ModelContext) {
        let completion = ChoreCompletion(choreID: chore.id, memberID: kid.id, day: day, points: chore.points, status: .approved)
        completion.completedAt = done
        completion.reviewedAt = done.addingTimeInterval(45 * 60)
        context.insert(completion)
        context.insert(PointEntry(memberID: kid.id, points: chore.points, kind: .chore, refID: completion.id, note: chore.title, date: done.addingTimeInterval(45 * 60)))
    }
}
