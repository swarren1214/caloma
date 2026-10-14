import SwiftData
import SwiftUI

extension View {
    /// Supplies the router and an in-memory store with the family from the designs to previews.
    func previewEnvironment() -> some View {
        modifier(PreviewEnvironment())
    }
}

private struct PreviewEnvironment: ViewModifier {
    @State private var router = AppRouter()
    @State private var container: ModelContainer = {
        let container = Persistence.makeContainer(inMemory: true)
        SampleData.insert(into: container.mainContext)
        return container
    }()

    func body(content: Content) -> some View {
        content
            .environment(router)
            .modelContainer(container)
            .tint(Brand.defaultAccent)
    }
}

/// The family from the Tend designs: two parents, Ella, Max and June, their chores with today
/// part done, a few weeks of points, the family store and the home care list. Previews only.
enum SampleData {
    static func insert(into context: ModelContext, calendar: Calendar = .current) {
        let parent = Member(name: "Steve", role: .parent, color: .teal, sortOrder: 0)
        let partner = Member(name: "Partner", role: .parent, color: .pink, sortOrder: 1)
        let ella = Member(name: "Ella", role: .kid, color: .purple, sortOrder: 2)
        let max = Member(name: "Max", role: .kid, color: .blue, sortOrder: 3)
        let june = Member(name: "June", role: .kid, color: .orange, sortOrder: 4)
        for member in [parent, partner, ella, max, june] { context.insert(member) }
        UserDefaults.standard.set(parent.id.uuidString, forKey: SettingsKey.currentMember)

        let today = calendar.startOfDay(for: .now)
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        let tuesday = ChoreMath.bit(forWeekday: 3)
        let friday = ChoreMath.bit(forWeekday: 6)

        func chore(_ title: String, _ symbol: String, _ points: Int, _ kids: [Member], _ rule: ChoreRepeat = .daily, mask: Int = 0, order: Int) -> Chore {
            let chore = Chore(title: title, symbol: symbol, points: points, assigneeIDs: kids.map(\.id), repeatRule: rule, weekdayMask: mask, startDate: monthAgo, sortOrder: order)
            context.insert(chore)
            return chore
        }

        let bed = chore("Make your bed", "bed.double", 5, [ella, max], order: 0)
        let dishes = chore("Unload the dishwasher", "dishwasher", 10, [ella], order: 1)
        dishes.requiresPhoto = true
        let dog = chore("Feed Biscuit", "pawprint", 5, [ella, max], order: 2)
        dog.rotates = true
        let vacuum = chore("Vacuum the living room", "sparkles", 20, [ella], .someDays, mask: tuesday | friday, order: 3)
        let piano = chore("Practice piano 20 min", "music.note", 15, [max], .weekdays, order: 4)
        let laundry = chore("Put away laundry", "tshirt", 10, [max], order: 5)
        let sink = chore("Clean the bathroom sink", "sink", 15, [max], order: 6)
        sink.requiresPhoto = true
        let teeth = chore("Brush teeth, morning and night", "mouth", 3, [june], order: 7)
        let toys = chore("Put toys away", "teddybear", 5, [june], order: 8)
        let table = chore("Set the table", "fork.knife", 5, [june], order: 9)
        let trash = chore("Take out trash and recycling", "trash", 15, [ella, max, june], .someDays, mask: tuesday, order: 10)
        trash.upForGrabs = true
        let kitchen = Room(name: "Kitchen", symbol: "fork.knife", sortOrder: 0)
        let living = Room(name: "Living Room", symbol: "sofa", sortOrder: 1)
        let bathroom = Room(name: "Bathroom", symbol: "shower", sortOrder: 2)
        for room in [kitchen, living, bathroom] { context.insert(room) }
        dishes.roomID = kitchen.id
        dishes.priority = .high
        table.roomID = kitchen.id
        vacuum.roomID = living.id
        sink.roomID = bathroom.id

        func done(_ chore: Chore, _ kid: Member, _ status: CompletionStatus) {
            let completion = ChoreCompletion(choreID: chore.id, memberID: kid.id, day: today, points: chore.points, status: status)
            context.insert(completion)
            if status == .approved {
                context.insert(PointEntry(memberID: kid.id, points: chore.points, kind: .chore, refID: completion.id, note: chore.title))
            }
        }
        done(bed, ella, .approved)
        done(dishes, ella, .pending)
        done(bed, max, .approved)
        done(piano, max, .pending)
        done(teeth, june, .approved)
        done(toys, june, .approved)
        done(table, june, .pending)
        _ = (dog, laundry, sink)
        let groceries = chore("Grocery run", "cart", 0, [parent], .someDays, mask: ChoreMath.bit(forWeekday: 7), order: 11)
        groceries.requiresApproval = false

        // The calendar from the designs: practice, piano, a dentist visit, movie night.
        func event(_ title: String, _ symbol: String, dayOffset: Int, hour: Int, minute: Int = 0, minutes: Int, who: [Member], driver: Member? = nil, rule: EventRepeat = .never, mask: Int = 0, location: String = "", bring: [String] = []) -> FamilyEvent {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
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
        let weekday = calendar.component(.weekday, from: today)
        _ = event("School drop-off", "graduationcap", dayOffset: 0, hour: 7, minute: 45, minutes: 25, who: [ella, max], driver: parent, rule: .weekly, mask: ChoreMath.weekdaysMask, location: "Lincoln Elementary")
        _ = event("Piano lesson", "music.note", dayOffset: 0, hour: 15, minute: 30, minutes: 45, who: [max], driver: partner, rule: .weekly, location: "Harmony Music Studio", bring: ["Piano books"])
        _ = event("Soccer practice", "soccerball", dayOffset: 0, hour: 16, minute: 30, minutes: 75, who: [ella], driver: parent, rule: .weekly, mask: ChoreMath.bit(forWeekday: weekday) | ChoreMath.bit(forWeekday: (weekday + 1) % 7 + 1), location: "Riverside Park · Field 3", bring: ["Cleats", "Water bottle", "Shin guards"])
        _ = event("Dentist checkup", "stethoscope", dayOffset: 1, hour: 16, minutes: 45, who: [june], driver: partner, location: "Bright Smiles Dental")
        let movie = event("Movie night", "film", dayOffset: 3, hour: 19, minutes: 120, who: [], location: "Living room", bring: ["Blankets"])
        movie.countsDown = true

        // Earlier weeks, so balances match the designs.
        context.insert(PointEntry(memberID: ella.id, points: 595, kind: .chore, note: "Earlier chores", date: monthAgo))
        context.insert(PointEntry(memberID: max.id, points: 470, kind: .chore, note: "Earlier chores", date: monthAgo))
        context.insert(PointEntry(memberID: june.id, points: 272, kind: .chore, note: "Earlier chores", date: monthAgo))

        StarterData.insertRewards(into: context)
        let goal = (try? context.fetch(FetchDescriptor<Reward>()))?.first { $0.isFamilyGoal }
        if let goal {
            context.insert(PointEntry(memberID: ella.id, points: -360, kind: .goal, refID: goal.id, note: goal.name, date: monthAgo))
            context.insert(PointEntry(memberID: max.id, points: -290, kind: .goal, refID: goal.id, note: goal.name, date: monthAgo))
            context.insert(PointEntry(memberID: june.id, points: -170, kind: .goal, refID: goal.id, note: goal.name, date: monthAgo))
        }
        let screen = (try? context.fetch(FetchDescriptor<Reward>()))?.first { $0.name == "30 Min Screen Time" }
        if let screen {
            context.insert(Redemption(rewardID: screen.id, memberID: ella.id, cost: screen.cost, status: .pending))
        }

        StarterData.insertHomeTasks(into: context)
        if let filter = (try? context.fetch(FetchDescriptor<HomeTask>()))?.first(where: { $0.name == "Replace HVAC filter" }) {
            filter.nextDue = calendar.date(byAdding: .day, value: -3, to: today) ?? today
            filter.location = "Upstairs hallway"
            filter.details = "16×25×1 MERV 11"
            filter.notes = "Return vent is in the upstairs hallway ceiling. The arrow on the filter points toward the furnace."
            context.insert(HomeTaskLog(taskID: filter.id, memberID: parent.id, doneAt: calendar.date(byAdding: .day, value: -93, to: today) ?? today, daysLate: 0))
        }
        try? context.save()
    }
}
